#include "lc32_profile.h"
#include "dynarmic_internal.h"
#include "darwin_file_syscalls.h"
#include "guest_dispatch.h"
#include "guest_timers.h"

#ifdef __cplusplus
extern "C" {
#endif

static GuestVmEpochParticipant *
CurrentGuestVmEpochParticipant() {
    return nativeGuestRuntime != nullptr
        ? &nativeGuestRuntime->vmEpochParticipant
        : &mainGuestVmParticipant;
}

GuestVmEpochParticipant *CurrentGuestVmEpochParticipantForThread() {
    return CurrentGuestVmEpochParticipant();
}

static Dynarmic::HaltReason RunGuestJit(
        Dynarmic::A32::Jit *jit) {
    for (;;) {
        Dynarmic::HaltReason reason;
        {
            GuestVmEpochGuard guard(
                CurrentGuestVmEpochParticipant());
            const uint64_t profileStart = LC32ProfileNow();
            reason = jit->Run();
            if (LC32ProfileActive)
                LC32ProfileAddRun(mach_absolute_time() - profileStart);
        }
        if (!!reason ||
                NativeThreadStatePauseRequestedForCurrent()) {
            return reason;
        }
        /* Cycle-budget expiration is an internal scheduling boundary. */
    }
}

static Dynarmic::HaltReason StepGuestJit(
        Dynarmic::A32::Jit *jit) {
    GuestVmEpochGuard guard(
        CurrentGuestVmEpochParticipant());
    const uint64_t profileStart = LC32ProfileNow();
    const Dynarmic::HaltReason reason = jit->Step();
    if (LC32ProfileActive)
        LC32ProfileAddRun(mach_absolute_time() - profileStart);
    return reason;
}

static void ServiceGuestSVC() {
    GuestVmEpochGuard guard(
        CurrentGuestVmEpochParticipant());
    DynarmicCallbacks32UserCallbacks(
        threadHandle.cb)->CallSVC(0x80);
    HandleGuestContextTransition();
}

/*
 * Faster floating point, on by default (LC32_FAST_FP=0 turns it off).
 *  - Fresh guest threads start in RunFast mode (FPSCR DN|FZ), which is what
 *    iOS gives 32-bit apps. With LiveExec32's default of 0, every NEON float
 *    instruction made the arm64 JIT rewrite FPCR before and after it (~16 ns
 *    each on Apple cores versus ~1 ns for the math).
 *  - Unsafe_IgnoreStandardFPCRValue keeps that switch away even if the game
 *    changes FPSCR itself (as long as it keeps round-to-nearest).
 *  - Unsafe_IgnoreFPExceptionFlags drops the FPSR write/read per float block;
 *    guest reads of the exception and QC bits see zero.
 * Results differ from the default only for denormal numbers (flushed to zero)
 * and NaN payloads.
 */
bool LC32FastFPEnabled() {
    static const bool enabled = [] {
        const char *value = getenv("LC32_FAST_FP");
        // On unless LC32_FAST_FP=0: RunFast is what real 32-bit iOS gave
        // apps, and float-heavy code runs ~10x faster with it (less heat).
        const bool on = value == nullptr || value[0] != '0';
        fprintf(stderr, "LC32: fast floating point %s\n",
            on ? "enabled (LC32_FAST_FP=0 turns it off)" : "disabled (LC32_FAST_FP=0)");
        return on;
    }();
    return enabled;
}

void LC32ApplyFastFP(Dynarmic::A32::UserConfig &config) {
    if (!LC32FastFPEnabled())
        return;
    config.unsafe_optimizations = true;
    config.optimizations |= Dynarmic::OptimizationFlag::Unsafe_IgnoreStandardFPCRValue;
    config.optimizations |= Dynarmic::OptimizationFlag::Unsafe_IgnoreFPExceptionFlags;
}

/*
 * JIT fast paths from the 2026-11 "Track B" work, all on by default. To track
 * down a game problem, LC32_JIT_OPT=0 turns them all off and
 * LC32_JIT_OPT_OFF=<comma list> turns off single ones:
 *   fusion     one page-table check for a whole LDM/STM, PUSH/POP, VLDM/VSTM,
 *              VPUSH/VPOP or VLD1/VST1
 *   widevec    one 64-bit access per D register for VFP/NEON loads/stores
 *   exclusive  LDREX/STREX inline instead of through the exclusive monitor
 *   flags      conditional branches and conditional instructions use the host
 *              flags directly instead of reloading the guest flags
 */
static Dynarmic::OptimizationFlag LC32DisabledJitOptimizations() {
    static const Dynarmic::OptimizationFlag disabled = [] {
        using Flag = Dynarmic::OptimizationFlag;
        static constexpr struct {
            const char *name;
            Flag flag;
        } options[] = {
            {"fusion", Flag::MemoryRangeFusion},
            {"widevec", Flag::WideVectorMemory},
            {"exclusive", Flag::InlineExclusiveMemory},
            {"flags", Flag::HostFlagForwarding},
        };
        Flag result = Dynarmic::no_optimizations;
        const char *all = getenv("LC32_JIT_OPT");
        if (all != nullptr && all[0] == '0') {
            for (const auto &option : options)
                result |= option.flag;
        }
        if (const char *list = getenv("LC32_JIT_OPT_OFF")) {
            for (const auto &option : options) {
                const size_t length = strlen(option.name);
                for (const char *p = list; (p = strstr(p, option.name)) != nullptr; p += length) {
                    const bool start = p == list || p[-1] == ',' || p[-1] == ' ';
                    const char end = p[length];
                    if (start && (end == '\0' || end == ',' || end == ' ')) {
                        result |= option.flag;
                        break;
                    }
                }
            }
        }
        std::string off;
        for (const auto &option : options) {
            if ((result & option.flag) != Dynarmic::no_optimizations) {
                if (!off.empty())
                    off += ", ";
                off += option.name;
            }
        }
        fprintf(stderr, "LC32: JIT fast paths %s%s\n",
            off.empty() ? "all on (LC32_JIT_OPT=0 turns them off)" : "off: ",
            off.c_str());
        return result;
    }();
    return disabled;
}

void LC32ApplyJitOptimizations(Dynarmic::A32::UserConfig &config) {
    config.optimizations &= ~LC32DisabledJitOptimizations();
}

std::uint32_t LC32GuestInitialFpscr() {
    return LC32FastFPEnabled() ? 0x03000000u /* DN | FZ */ : 0u;
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    nativeInitialize
 * Signature: (Z)J
 */
bool Dynarmic_nativeInitialize() {
    std::unique_lock<std::mutex> lifecycleLock(
        nativeLifecycleMutex);
    if (nativeLifecycleState ==
            NativeLifecycleState::Running) {
        return true;
    }
    if (nativeLifecycleState ==
            NativeLifecycleState::ShuttingDown) {
        nativeLifecycleCondition.wait(
            lifecycleLock, [] {
                return nativeLifecycleState !=
                    NativeLifecycleState::ShuttingDown;
            });
    }
    if (nativeLifecycleState ==
            NativeLifecycleState::Destroyed) {
        return false;
    }
    nativeShutdownRequested.store(
        false, std::memory_order_release);
    guestProcessExitRequested.store(
        false, std::memory_order_release);
    guestProcessExitCode.store(
        0, std::memory_order_release);
#ifdef LC32_GUEST_MEMORY_WATCH_ADDRESS
    ConfigureGuestMemoryWatch();
#endif
    ResetGuestCallbackExecutor();
    ResetNativeThreadStateSlot(mainNativeThreadState);

    sharedHandle.memory = kh_init(memory);
    if(sharedHandle.memory == NULL) {
        fprintf(stderr, "kh_init memory failed\n");
        abort();
        return 0;
    }
    InvalidateGuestMemoryLookupCaches();
    int ret = kh_resize(memory, sharedHandle.memory, 0x1000);
    if(ret == -1) {
        fprintf(stderr, "kh_resize memory failed\n");
        abort();
        return 0;
    }
    sharedHandle.monitor =
        new Dynarmic::ExclusiveMonitor(
            MaxNativeGuestProcessors);
    {
        DynarmicCallbacks32 *callbacks =
            CreateDynarmicCallbacks32(sharedHandle.memory);

        Dynarmic::A32::UserConfig config;
        config.callbacks =
            DynarmicCallbacks32UserCallbacks(callbacks);
        config.coprocessors[15] = DynarmicCallbacks32CP15(callbacks);
        config.processor_id = 0;
        config.global_monitor = sharedHandle.monitor;
        config.always_little_endian = false;
        config.wall_clock_cntpct = true;
        config.check_halt_on_memory_access = false;
        //    config.page_table_pointer_mask_bits = DYN_PAGE_BITS;

        LC32ApplyFastFP(config);
        LC32ApplyJitOptimizations(config);

        sharedHandle.num_page_table_entries = Dynarmic::A32::UserConfig::NUM_PAGE_TABLE_ENTRIES;
        size_t size = sharedHandle.num_page_table_entries * sizeof(void*);
        sharedHandle.page_table = (void **)mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
        if(sharedHandle.page_table == MAP_FAILED) {
            fprintf(stderr, "nativeInitialize mmap failed[%s->%s:%d] size=0x%zx, errno=%d, msg=%s\n", __FILE__, __func__, __LINE__, size, errno, strerror(errno));
            sharedHandle.page_table = NULL;
            sharedHandle.write_page_table = NULL;
        } else {
            sharedHandle.write_page_table = (void **)mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
            if(sharedHandle.write_page_table == MAP_FAILED) {
                fprintf(stderr, "nativeInitialize write_page_table mmap failed[%s->%s:%d] size=0x%zx, errno=%d, msg=%s\n", __FILE__, __func__, __LINE__, size, errno, strerror(errno));
                munmap(sharedHandle.page_table, size);
                sharedHandle.page_table = NULL;
                sharedHandle.write_page_table = NULL;
            }
        }
        if (sharedHandle.page_table != NULL && sharedHandle.write_page_table != NULL) {
            DynarmicCallbacks32SetPageTable(
                callbacks,
                sharedHandle.num_page_table_entries,
                sharedHandle.page_table,
                sharedHandle.write_page_table);

            // Unpredictable instructions
            config.define_unpredictable_behaviour = true;

            // Memory
            config.page_table = reinterpret_cast<std::array<std::uint8_t*, Dynarmic::A32::UserConfig::NUM_PAGE_TABLE_ENTRIES>*>(sharedHandle.page_table);
            config.write_page_table = reinterpret_cast<std::array<std::uint8_t*, Dynarmic::A32::UserConfig::NUM_PAGE_TABLE_ENTRIES>*>(sharedHandle.write_page_table);
            config.absolute_offset_page_table = true;
            config.detect_misaligned_access_via_page_table = 16 | 32 | 64 | 128;
            config.only_detect_misalignment_via_page_table_on_page_boundary = true;
        }

        sharedHandle.cb = callbacks;
        threadHandle.jit = new Dynarmic::A32::Jit(config);
        threadHandle.jit->SetFpscr(LC32GuestInitialFpscr());
        threadHandle.cpsr = new DynarmicCpsr(threadHandle.jit);
        threadHandle.cb = callbacks;
        sharedHandle.fs = new LC32Filesystem();
        DynarmicCallbacks32BindJit(
            callbacks, threadHandle.jit,
            threadHandle.cpsr);
        RegisterGuestVmEpochParticipant(
            &mainGuestVmParticipant);
    }
    ReserveNativeGuestJitAddressSpace();
    nativeLifecycleState =
        NativeLifecycleState::Running;
    lifecycleLock.unlock();
    nativeLifecycleCondition.notify_all();
    return true;
}

static void ReleaseMemoryBackingReference(
        t_memory_backing backing) {
    if (backing == nullptr) {
        return;
    }
    assert(backing->references != 0);
    if (--backing->references != 0) {
        return;
    }
    RetireMemoryBacking(backing);
}

static void ReleaseMemoryPageBacking(
        t_memory_page page) {
    if (page == nullptr) {
        return;
    }
    t_memory_backing backing = page->backing;
    page->backing = nullptr;
    ReleaseMemoryBackingReference(backing);
}

void Dynarmic_nativeDestroy() {
    if (nativeGuestRuntime != nullptr &&
            nativeGuestThreadId > 1) {
        /*
         * A worker cannot join itself. Ask the main host thread to perform the
         * serialized teardown when control returns from guest execution.
         */
        nativeShutdownRequested.store(
            true, std::memory_order_release);
        LC32RemoveGuestMainQueueSource();
        RequestGuestWorkqueueTimersStop();
        StopGuestCallbackExecutor();
        HaltAllGuestJits(LC32HaltReasonExit);
        InterruptDebuggerMachCalls();
        NotifyNativeDebuggerWaiters();
        NotifyNativeDebuggerCoordinator();
        return;
    }

    {
        std::unique_lock<std::mutex> lock(
            nativeLifecycleMutex);
        if (nativeLifecycleState ==
                NativeLifecycleState::Uninitialized ||
                nativeLifecycleState ==
                    NativeLifecycleState::Destroyed) {
            return;
        }
        if (nativeLifecycleState ==
                NativeLifecycleState::ShuttingDown) {
            nativeLifecycleCondition.wait(lock, [] {
                return nativeLifecycleState ==
                    NativeLifecycleState::Destroyed;
            });
            return;
        }
        nativeLifecycleState =
            NativeLifecycleState::ShuttingDown;
        nativeShutdownRequested.store(
            true, std::memory_order_release);
    }
    // Disable native run-loop delivery after publishing shutdown, before
    // destroying the guest JIT and its callback address space.
    LC32RemoveGuestMainQueueSource();
    StopGuestWorkqueueTimers();
    StopGuestCallbackExecutor();

    {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        nativeDebugger.state =
            NativeDebuggerRunState::ShuttingDown;
        debuggerAllStopRequested.store(
            true, std::memory_order_release);
    }
    HaltAllGuestJits(LC32HaltReasonExit);
    DrainDebuggerMachCalls();
    NotifyNativeDebuggerWaiters();
    NotifyNativeDebuggerCoordinator();

    std::vector<NativeGuestJit *> runtimes;
    {
        std::lock_guard<std::mutex> lock(
            nativeGuestJitMutex);
        runtimes = nativeGuestJits;
    }
    for (NativeGuestJit *runtime : runtimes) {
        JoinNativeGuestJit(runtime);
    }
    for (NativeGuestJit *runtime : runtimes) {
        DestroyNativeGuestJit(runtime);
    }
    CloseAllGuestAesFileDescriptors();
    ClearGuestAioOperations();

    Dynarmic::A32::Jit *jit = threadHandle.jit;
    DynarmicCallbacks32 *cb = sharedHandle.cb;
    DynarmicCpsr *cpsr = threadHandle.cpsr;
    threadHandle = {};
    sharedHandle.cb = nullptr;
    UnregisterGuestVmEpochParticipant(
        &mainGuestVmParticipant);
    if (jit != nullptr) {
        jit->ClearCache();
        jit->Reset();
    }
    delete cpsr;
    delete jit;
    DestroyDynarmicCallbacks32(cb);
    delete sharedHandle.fs;
    sharedHandle.fs = nullptr;

    {
        std::lock_guard<std::recursive_mutex> lock(
            guestVmMutex);
        khash_t(memory) *memory = sharedHandle.memory;
        if (memory != nullptr) {
            InvalidateGuestMemoryLookupCaches();
            for (khiter_t k = kh_begin(memory);
                    k < kh_end(memory); ++k) {
                if (kh_exist(memory, k)) {
                    t_memory_page page =
                        kh_value(memory, k);
                    ReleaseMemoryPageBacking(page);
                    free(page);
                }
            }
            kh_destroy(memory, memory);
            sharedHandle.memory = nullptr;
        }
    }
    if (sharedHandle.page_table != nullptr ||
            sharedHandle.write_page_table != nullptr) {
        const size_t tableSize =
            sharedHandle.num_page_table_entries *
            sizeof(void *);
        if (sharedHandle.write_page_table != nullptr) {
            const int result = munmap(
                sharedHandle.write_page_table, tableSize);
            if (result != 0) {
                fprintf(stderr,
                    "munmap failed[%s->%s:%d]: "
                    "write_page_table=%p, ret=%d\n",
                    __FILE__, __func__, __LINE__,
                    sharedHandle.write_page_table, result);
            }
            sharedHandle.write_page_table = nullptr;
        }
        if (sharedHandle.page_table != nullptr) {
            const int result = munmap(
                sharedHandle.page_table, tableSize);
            if (result != 0) {
                fprintf(stderr,
                    "munmap failed[%s->%s:%d]: "
                    "page_table=%p, ret=%d\n",
                    __FILE__, __func__, __LINE__,
                    sharedHandle.page_table, result);
            }
            sharedHandle.page_table = nullptr;
        }
        sharedHandle.num_page_table_entries = 0;
    }
    ResetGuestExternalPageBitmap();
    delete sharedHandle.monitor;
    sharedHandle.monitor = nullptr;

    std::vector<mach_port_t> threadPorts;
    {
        std::lock_guard<std::recursive_mutex> lock(
            guestThreadMutex);
        for (const GuestThreadContext &thread :
                guestThreads) {
            /*
             * The main-thread entry names the borrowed port returned by
             * pthread_mach_thread_np().  All other registry ports are
             * synthetic receive rights allocated by AllocateGuestThreadPort.
             * Destroying the borrowed pthread port violates its Mach-port
             * guard on iOS (EXC_GUARD/GUARD_EXC_MOD_REFS).
             */
            if (thread.debuggerId != 1 &&
                    MACH_PORT_VALID(thread.threadPort)) {
                threadPorts.push_back(
                    thread.threadPort);
            }
        }
        guestThreads.clear();
        guestThreadRegistryInitialized = false;
        guestCurrentThreadId = 1;
        guestNextDebuggerThreadId = 3;
        guestProcessorIdsInUse = 1;
    }
    if (MACH_PORT_VALID(guestWorkqueueThreadPort)) {
        threadPorts.push_back(
            guestWorkqueueThreadPort);
        guestWorkqueueThreadPort =
            MACH_PORT_NULL;
    }
    std::sort(threadPorts.begin(), threadPorts.end());
    threadPorts.erase(std::unique(
        threadPorts.begin(), threadPorts.end()),
        threadPorts.end());
    for (mach_port_t port : threadPorts) {
        (void)mach_port_destroy(
            mach_task_self(), port);
    }
    {
        std::lock_guard<std::mutex> lock(
            nativeGuestWaitMutex);
        nativeGuestWaiters.clear();
        nativeGuestRwlockUnlocks.clear();
        nativeGuestRwlockOverlaps.clear();
    }
    {
        std::lock_guard<std::mutex> lock(
            guestPsynchPrepostMutex);
        guestMutexPreposts.clear();
        guestConditionPreposts.clear();
    }
    {
        std::lock_guard<std::recursive_mutex> lock(
            guestWorkqueueMutex);
        guestNativeWorkqueuePendingJobs.clear();
    }

    {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        nativeDebugger.state =
            NativeDebuggerRunState::Disabled;
        nativeDebugger.executingWorkers = 0;
        nativeDebugger.mainExecuting = false;
    }
    nativeGuestThreadId = 0;
    nativeGuestWorkqueueHostBlockDepth = 0;
    nativeShutdownRequested.store(
        false, std::memory_order_release);
    guestProcessExitRequested.store(
        false, std::memory_order_release);
    guestProcessExitCode.store(
        0, std::memory_order_release);

    {
        std::lock_guard<std::mutex> lock(
            nativeLifecycleMutex);
        nativeLifecycleState =
            NativeLifecycleState::Destroyed;
    }
    nativeLifecycleCondition.notify_all();
}

static int ValidateGuestMunmapRangeLocked(
        u64 address, u64 size) {
    if(address & DYN_PAGE_MASK) {
        errno = EINVAL;
        return -1;
    }
    if(size == 0 || (size & DYN_PAGE_MASK)) {
        errno = EINVAL;
        return -1;
    }
    if (!GuestAddressRangeIsValid32(
            address, size)) {
        errno = EINVAL;
        return -1;
    }
    khash_t(memory) *memory = sharedHandle.memory;
    if (memory == nullptr) {
        /* The guest VM is gone (native objects may outlive it). */
        errno = EINVAL;
        return -1;
    }
    const u64 end = address + size;

    /*
     * Validate the complete range first. munmap has no fallible operation
     * after this point, so a hole must not leave the preceding pages already
     * removed.
     */
    for (u64 vaddr = address; vaddr < end;
            vaddr += DYN_PAGE_SIZE) {
        if (kh_get(memory, memory, vaddr) ==
                kh_end(memory)) {
            fprintf(stderr,
                "mem_unmap failed[%s->%s:%d]: vaddr=%p\n",
                __FILE__, __func__, __LINE__,
                reinterpret_cast<void *>(vaddr));
            errno = ENOMEM;
            return -1;
        }
    }
    return 0;
}

int ValidateGuestMunmapRange(
        u64 address, u64 size) {
    std::lock_guard<std::recursive_mutex> lock(
        guestVmMutex);
    return ValidateGuestMunmapRangeLocked(address, size);
}


/*
 * Remove a Dynarmic_direct_mmap view of host memory, but only while its first
 * page still shows that host address: a native owner may outlive the guest
 * VM, or the guest may have replaced the range in the meantime.
 */
int Dynarmic_munmap_direct(u32 address, u64 size, const void *host) {
    std::lock_guard<std::recursive_mutex> lock(guestVmMutex);
    khash_t(memory) *memory = sharedHandle.memory;
    if (memory == nullptr) return -1;
    const khiter_t k = kh_get(memory, memory, address);
    if (k == kh_end(memory) || kh_value(memory, k)->addr != host ||
            kh_value(memory, k)->backing != nullptr) {
        return -1;
    }
    return Dynarmic_munmap(address, size);
}

int Dynarmic_munmap(u64 address, u64 size) {
    std::unique_lock<std::recursive_mutex> lock(
        guestVmMutex);
    if (ValidateGuestMunmapRangeLocked(address, size) != 0) {
        return -1;
    }
    khash_t(memory) *memory = sharedHandle.memory;
    const u64 end = address + size;

#ifdef LC32_GUEST_MEMORY_WATCH_ADDRESS
    if (GuestMemoryWatchOverlaps(
            address, static_cast<size_t>(size))) {
        const u32 pc = threadHandle.jit != nullptr
            ? threadHandle.jit->Regs()[Reg::PC] : 0;
        const u32 lr = threadHandle.jit != nullptr
            ? threadHandle.jit->Regs()[Reg::LR] : 0;
        fprintf(stderr,
            "LC32 guest memory watch mapping: op=munmap "
            "range=0x%08llx+0x%llx pc=%08x lr=%08x "
            "host_thread=%u\n",
            address, size, pc, lr,
            pthread_mach_thread_np(pthread_self()));
        if (threadHandle.jit != nullptr) {
            u32 framePointer = threadHandle.jit->Regs()[7];
            fprintf(stderr,
                "LC32 guest memory watch munmap frames:");
            for (unsigned frame = 0;
                    frame < 16 && framePointer != 0;
                    ++frame) {
                if ((framePointer & 3) != 0 ||
                        framePointer > UINT32_MAX - 8) {
                    fprintf(stderr, " invalid-fp=%08x", framePointer);
                    break;
                }
                u32 nextFramePointer = 0;
                u32 returnAddress = 0;
                if (!read_guest_memory_with_permissions(
                            framePointer, &nextFramePointer,
                            sizeof(nextFramePointer), PROT_READ) ||
                        !read_guest_memory_with_permissions(
                            framePointer + 4, &returnAddress,
                            sizeof(returnAddress), PROT_READ)) {
                    fprintf(stderr, " unreadable-fp=%08x", framePointer);
                    break;
                }
                fprintf(stderr, " %08x", returnAddress);
                if (nextFramePointer == framePointer) {
                    fprintf(stderr, " cyclic");
                    break;
                }
                framePointer = nextFramePointer;
            }
            fprintf(stderr, "\n");
        }
        LogGuestMemoryWatchConsistencyLocked("before munmap");
    }
#endif

    InvalidateGuestMemoryLookupCaches();
    for(u64 vaddr = address; vaddr < end;
            vaddr += DYN_PAGE_SIZE) {
        khiter_t k = kh_get(memory, memory, vaddr);
        ClearGuestPageTableEntries(vaddr);
        t_memory_page page = kh_value(memory, k);
        /*
         * Guest pages are 4 KiB while Apple Silicon host VM pages are
         * 16 KiB. Anonymous guest mappings therefore share one host mmap
         * backing object and release it only after every guest slice has
         * gone away. Per-slice munmap would also remove adjacent live guest
         * pages (notably the pthread structure beside a retired stack).
         */
        ReleaseMemoryPageBacking(page);
        free(page);
        kh_del(memory, memory, k);
    }
    lock.unlock();
    InvalidateAllGuestJits(
        static_cast<u32>(address),
        static_cast<size_t>(size));
    return 0;
}

struct GuestPageReservation {
    u64 address;
    t_memory_page page;
};

static void RollbackGuestPageReservations(
        khash_t(memory) *memory,
        std::vector<GuestPageReservation>
            *reservations) {
    if (reservations == nullptr) {
        return;
    }
    for (auto iterator = reservations->rbegin();
            iterator != reservations->rend();
            ++iterator) {
        const khiter_t entry = kh_get(
            memory, memory, iterator->address);
        if (entry != kh_end(memory) &&
                kh_value(memory, entry) ==
                    iterator->page) {
            kh_del(memory, memory, entry);
        }
        free(iterator->page);
    }
    reservations->clear();
}

static bool AlignGuestAddress(
        u64 address, u64 mask, u64 *alignedAddress) {
    constexpr u64 addressSpaceSize =
        UINT64_C(1) << 32;
    const u64 adjustment =
        (mask + 1 - (address & mask)) & mask;
    if (address >= addressSpaceSize ||
            adjustment >
                addressSpaceSize - address) {
        return false;
    }
    *alignedAddress = address + adjustment;
    return *alignedAddress < addressSpaceSize;
}

static u64 Dynarmic_mem_reserve(
        u64 address, u64 size, bool fixed, u64 mask,
        std::vector<GuestPageReservation>
            *reservations) {
    std::lock_guard<std::recursive_mutex> lock(
        guestVmMutex);

    if (reservations == nullptr ||
            size == 0 ||
            (size & DYN_PAGE_MASK) != 0 ||
            mask < DYN_PAGE_MASK ||
            mask > UINT32_MAX ||
            (mask & (mask + 1)) != 0) {
        errno = EINVAL;
        return UINT64_MAX;
    }
    reservations->clear();

    /*
     * Keep anonymous allocations away from low addresses so stray pointers
     * are still easy to diagnose.  Fixed mappings are different: legacy
     * non-PIE ARM executables are linked as low as 0x1000 and must retain
     * those addresses because they have no rebase records.  Preserve only
     * the actual null-page guard for MAP_FIXED mappings.
     */
    if (fixed) {
        if (address < DYN_PAGE_SIZE) {
            printf("Dynarmic_mem_reserve: refusing to reserve the null page\n");
            errno = ENOMEM;
            return UINT64_MAX;
        }
    } else if (address < 0x10000000) {
        address += 0x10000000;
    }

    if (!AlignGuestAddress(
            address, mask, &address) ||
            !GuestAddressRangeIsValid32(
                address, size)) {
        errno = fixed ? EINVAL : ENOMEM;
        return UINT64_MAX;
    }

    khash_t(memory) *memory = sharedHandle.memory;
    const u64 end = address + size;
    if (fixed) {
        for(u64 vaddr = address; vaddr < end;
                vaddr += DYN_PAGE_SIZE) {
            khiter_t k;
            if((k = kh_get(memory, memory, vaddr)) != kh_end(memory)) {
#if 0
                pthread_mutex_unlock(&mutex);
                printf("Dynarmic_mem_reserve: cannot reserve fixed address 0x%llx. It is bound to 0x%llx\n", address, kh_value(memory, k)->addr);
                return -1;
#else
                //printf("Dynarmic_mem_reserve: force-remapping at address 0x%llx\n", address);
                // FIXME: what should I really do here? Unmap will cause subsequent 3 pages (remember we're running 4k binaries on 16k) to be unmapped aswell
                //Dynarmic_munmap(vaddr, DYN_PAGE_SIZE);
#endif
            }
        }
    } else {
        /*
         * A Mach VM alignment mask constrains every candidate, not just the
         * initial hint. Restart the complete range scan after a collision:
         * advancing from a 4K page by mask + 1 alone can produce a result
         * that is not aligned to mask + 1 (for example ...9000 for a 16K
         * request), which breaks clients such as libobjc autorelease pages.
         */
        for (;;) {
            bool collision = false;
            const u64 candidateEnd =
                address + size;
            for(u64 vaddr = address;
                    vaddr < candidateEnd;
                    vaddr += DYN_PAGE_SIZE) {
                if(kh_get(memory, memory, vaddr) == kh_end(memory)) {
                    continue;
                }
                const u64 next =
                    vaddr + DYN_PAGE_SIZE;
                if (!AlignGuestAddress(
                        next, mask, &address) ||
                        !GuestAddressRangeIsValid32(
                            address, size)) {
                    errno = ENOMEM;
                    return UINT64_MAX;
                }
                collision = true;
                break;
            }
            if(!collision) {
                break;
            }
        }
    }

    try {
        reservations->reserve(
            static_cast<size_t>(
                size / DYN_PAGE_SIZE));
    } catch (const std::exception &) {
        errno = ENOMEM;
        return UINT64_MAX;
    }

    const u64 reservationEnd = address + size;
    for(u64 vaddr = address; vaddr < reservationEnd;
            vaddr += DYN_PAGE_SIZE) {
        khiter_t k = kh_get(
            memory, memory, vaddr);
        if (k != kh_end(memory)) {
            assert(fixed);
            continue;
        }
        t_memory_page page = static_cast<t_memory_page>(
            calloc(1, sizeof(struct memory_page)));
        if (page == nullptr) {
            RollbackGuestPageReservations(
                memory, reservations);
            errno = ENOMEM;
            return UINT64_MAX;
        }
        try {
            reservations->push_back({
                vaddr, page,
            });
        } catch (const std::exception &) {
            free(page);
            RollbackGuestPageReservations(
                memory, reservations);
            errno = ENOMEM;
            return UINT64_MAX;
        }
        int ret = 0;
        k = kh_put(memory, memory, vaddr, &ret);
        if (ret < 0 || k == kh_end(memory)) {
            RollbackGuestPageReservations(
                memory, reservations);
            errno = ENOMEM;
            return UINT64_MAX;
        }
        if (ret == 0) {
            RollbackGuestPageReservations(
                memory, reservations);
            errno = EEXIST;
            return UINT64_MAX;
        }
        kh_value(memory, k) = page;
    }

    LC32_DEBUG_PRINTF("Dynarmic_mem_reserve: 0x%llx-0x%llx\n", address, address + size);
    return address;
}

u32 Dynarmic_direct_mmap(
        u32 address, u64 size, int protection,
        int flags, void *src, u64 off,
        bool volatileExternal) {
    std::unique_lock<std::recursive_mutex> lock(
        guestVmMutex);
    if(address & DYN_PAGE_MASK) {
        errno = EINVAL;
        return -1;
    }
    if(size == 0 || (size & DYN_PAGE_MASK)) {
        errno = EINVAL;
        return -1;
    }
    if (!GuestProtectionIsValid(protection) ||
            !GuestAddressRangeIsValid32(
                address, size)) {
        errno = EINVAL;
        return UINT32_MAX;
    }

    khash_t(memory) *memory = sharedHandle.memory;
    std::vector<GuestPageReservation>
        reservations;
    const u64 reservedAddress =
        Dynarmic_mem_reserve(
            address, size, flags & MAP_FIXED,
            DYN_PAGE_MASK, &reservations);
    if(reservedAddress == UINT64_MAX) {
        fprintf(stderr, "reserve failed[%s->%s:%d]: addr=0x%x\n", __FILE__, __func__, __LINE__, address);
        return UINT32_MAX;
    }
    address = static_cast<u32>(reservedAddress);
    InvalidateGuestMemoryLookupCaches();

    const u64 end = reservedAddress + size;
    for(u64 vaddr = reservedAddress; vaddr < end;
            vaddr += DYN_PAGE_SIZE) {
        ClearGuestPageTableEntries(vaddr);
        if (volatileExternal) {
            MarkGuestPageEverExternal(vaddr);
        }
    }
    std::atomic_thread_fence(std::memory_order_seq_cst);
    for(u64 vaddr = reservedAddress; vaddr < end;
            vaddr += DYN_PAGE_SIZE) {
        void *addr = reinterpret_cast<void *>(
            reinterpret_cast<u64>(src) + off +
                vaddr - reservedAddress);
        t_memory_page page = kh_value(memory, kh_get(memory, memory, vaddr));
        t_memory_backing oldBacking =
            page->backing;
        page->addr = addr;
        page->perms = protection;
        page->enforceDataPermissions =
            (protection & PROT_READ) == 0;
        page->backing = nullptr;
        UpdateGuestPageTableEntries(vaddr, page);
        ReleaseMemoryBackingReference(
            oldBacking);
    }
    reservations.clear();
    lock.unlock();
    InvalidateAllGuestJits(
        address, static_cast<size_t>(size));
    return address;
}

u32 Dynarmic_mmap(
        u32 address, u64 size, int protection,
        int flags, int fildes, u64 off, u64 mask,
        bool purgable) {
    std::unique_lock<std::recursive_mutex> lock(
        guestVmMutex);
    if(address & DYN_PAGE_MASK) {
        errno = EINVAL;
        return -1;
    }
    if(size == 0 || (size & DYN_PAGE_MASK)) {
        errno = EINVAL;
        return -1;
    }
    if (!GuestProtectionIsValid(protection) ||
            !GuestAddressRangeIsValid32(
                address, size)) {
        errno = EINVAL;
        return UINT32_MAX;
    }
    khash_t(memory) *memory = sharedHandle.memory;
    std::vector<GuestPageReservation>
        reservations;
    const u64 reservedAddress =
        Dynarmic_mem_reserve(
            address, size, flags & MAP_FIXED,
            mask, &reservations);
    if(reservedAddress == UINT64_MAX) {
        fprintf(stderr, "reserve failed[%s->%s:%d]: addr=0x%x\n", __FILE__, __func__, __LINE__, address);
        return UINT32_MAX;
    }
    address = static_cast<u32>(reservedAddress);
    const int guestProtection = protection;
    const bool debuggerWritableExecutableFile =
        (guestProtection & PROT_EXEC) != 0 &&
        fildes != -1 && size > 0x1000 && off == 0;
    if (debuggerWritableExecutableFile) {
        flags |= MAP_PRIVATE;
        flags &= ~MAP_SHARED;
    }

    off_t aligned_off = off & ~(PAGE_SIZE-1);
    const size_t mappingSize = size + (off - aligned_off);
    int hostProtection =
        HostProtectionForGuestPermissions(
            guestProtection);
    /*
     * Keep owned anonymous storage readable/writable so debugger and syscall
     * copyin/copyout helpers never take a host protection fault. Initial
     * read-bearing mappings intentionally retain the historical page-table
     * fast path for dyld/shared-cache performance, so their data permissions
     * are compatibility-mode rather than strict. PROT_NONE/write-only
     * mappings and every explicit mprotect transition use callbacks for
     * strict guest data permissions. Executable file mappings are made
     * private and writable solely so software breakpoints can patch them.
     */
    if ((flags & MAP_ANONYMOUS) != 0) {
        hostProtection |= PROT_READ | PROT_WRITE;
    }
    if (debuggerWritableExecutableFile) {
        hostProtection |= PROT_READ | PROT_WRITE;
    }
    void *mappingAddress = MAP_FAILED;
    if (purgable) {
        /*
         * mmap() creates a non-purgeable VM object. Guest mach_vm_allocate
         * requests carrying VM_FLAGS_PURGABLE therefore need a real Mach VM
         * allocation, otherwise their subsequent vm_purgable_control trap
         * would always fail with KERN_INVALID_ARGUMENT.
         */
        if ((flags & MAP_ANONYMOUS) == 0 || fildes != -1 ||
                aligned_off != 0) {
            errno = EINVAL;
        } else {
            vm_address_t purgableAddress = 0;
            const kern_return_t result = vm_allocate(
                mach_task_self(), &purgableAddress, mappingSize,
                VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
            if (result == KERN_SUCCESS) {
                mappingAddress = reinterpret_cast<void *>(
                    purgableAddress);
            } else {
                errno = result == KERN_NO_SPACE ||
                        result == KERN_RESOURCE_SHORTAGE
                    ? ENOMEM : EINVAL;
            }
        }
    } else {
        mappingAddress = mmap(
            NULL, mappingSize, hostProtection,
            flags & ~MAP_FIXED, fildes, aligned_off);
    }
    if(mappingAddress == MAP_FAILED) {
        fprintf(stderr, "mmap failed[%s->%s:%d]: addr=%p\n", __FILE__, __func__, __LINE__, mappingAddress);
        RollbackGuestPageReservations(
            memory, &reservations);
        return UINT32_MAX;
    }
    t_memory_backing backing =
        static_cast<t_memory_backing>(
            calloc(1, sizeof(struct memory_backing)));
    if (backing == nullptr) {
        (void)munmap(mappingAddress, mappingSize);
        RollbackGuestPageReservations(
            memory, &reservations);
        errno = ENOMEM;
        return UINT32_MAX;
    }
    backing->addr = mappingAddress;
    backing->size = mappingSize;
    backing->references = size / DYN_PAGE_SIZE;
    backing->hostProtection = hostProtection;
    u64 addr = reinterpret_cast<u64>(mappingAddress) +
        (off - aligned_off);

    LC32_DEBUG_PRINTF("DBG: mmaping host 0x%llx to 0x%x\n", addr, address);

#ifdef LC32_GUEST_MEMORY_WATCH_ADDRESS
    if (GuestMemoryWatchOverlaps(
            reservedAddress, static_cast<size_t>(size))) {
        const u32 pc = threadHandle.jit != nullptr
            ? threadHandle.jit->Regs()[Reg::PC] : 0;
        const u32 lr = threadHandle.jit != nullptr
            ? threadHandle.jit->Regs()[Reg::LR] : 0;
        fprintf(stderr,
            "LC32 guest memory watch mapping: op=mmap "
            "range=0x%08llx+0x%llx prot=0x%x flags=0x%x "
            "pc=%08x lr=%08x host_thread=%u\n",
            reservedAddress, size, guestProtection, flags,
            pc, lr, pthread_mach_thread_np(pthread_self()));
    }
#endif

    const u64 end = reservedAddress + size;
    InvalidateGuestMemoryLookupCaches();
    for(u64 vaddr = reservedAddress; vaddr < end;
            vaddr += DYN_PAGE_SIZE) {
        ClearGuestPageTableEntries(vaddr);
    }
    std::atomic_thread_fence(std::memory_order_seq_cst);
    for(u64 vaddr = reservedAddress; vaddr < end;
            vaddr += DYN_PAGE_SIZE) {
        t_memory_page page = kh_value(memory, kh_get(memory, memory, vaddr));
        t_memory_backing oldBacking =
            page->backing;
        page->addr = (void *)addr;
        page->perms = guestProtection;
        /*
         * Read-only shared-cache ranges are performance-critical and were
         * historically direct-mapped. Keep that initial compatibility path;
         * PROT_NONE/write-only pages and every explicit mprotect transition
         * use callbacks for strict per-4K data permissions.
         */
        page->enforceDataPermissions =
            (guestProtection & PROT_READ) == 0;
        page->backing = backing;
        UpdateGuestPageTableEntries(vaddr, page);
        ReleaseMemoryBackingReference(
            oldBacking);

        addr += DYN_PAGE_SIZE;
    }
    reservations.clear();
#ifdef LC32_GUEST_MEMORY_WATCH_ADDRESS
    if (GuestMemoryWatchOverlaps(
            reservedAddress, static_cast<size_t>(size))) {
        LogGuestMemoryWatchConsistencyLocked("after mmap");
    }
#endif
    lock.unlock();
    InvalidateAllGuestJits(
        address, static_cast<size_t>(size));
    return address;
}

kern_return_t Dynarmic_vm_remap(u32 *address, u32 size, u32 mask,
        int flags, u32 source, boolean_t copy, vm_prot_t *protection) {
    // A memcpy cannot implement shared aliases (notably mirrored ring buffers).
    // Unaligned extraction and shared executable aliases need separate support.
    // copy=TRUE is implemented below as a private snapshot.
    // Like XNU without VM_FLAGS_RETURN_DATA_ADDR, an unaligned source is
    // truncated to its page and the returned address stays page-aligned
    // (objc passes its Thumb trampoline pointer, which has bit 0 set).
    if(u64(size) > UINT32_MAX - (source & DYN_PAGE_MASK))
        return KERN_INVALID_ARGUMENT;
    size += source & DYN_PAGE_MASK;
    source &= ~u32(DYN_PAGE_MASK);
    const u64 alignment = u64(mask) | DYN_PAGE_MASK;
    const bool anywhere = (flags & VM_FLAGS_ANYWHERE) != 0;
    const bool overwrite = (flags & VM_FLAGS_OVERWRITE) != 0;
    if((flags & ~(VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE)) ||
            (anywhere && overwrite) || (alignment & (alignment + 1)))
        return KERN_INVALID_ARGUMENT;
    const u64 length = (u64(size) + DYN_PAGE_MASK) & ~u64(DYN_PAGE_MASK);
    const u64 destination = anywhere ? 0 : (*address & ~u64(DYN_PAGE_MASK));
    if(!length) return KERN_INVALID_ARGUMENT;
    if(!GuestAddressRangeIsValid32(source, length)) return KERN_INVALID_ADDRESS;
    if(!GuestAddressRangeIsValid32(destination, length) ||
            (!anywhere && (destination < DYN_PAGE_SIZE || (destination & alignment))))
        return KERN_NO_SPACE;

    std::unique_lock<std::recursive_mutex> lock(guestVmMutex);
    khash_t(memory) *memory = sharedHandle.memory;
    if(!memory) return KERN_INVALID_ADDRESS;
    if(copy) {
        /*
         * Private copy (objc's imp_implementationWithBlock remaps its
         * executable trampoline page this way). A snapshot is equivalent to
         * XNU's copy-on-write result for both mutable and immutable sources.
         */
        vm_prot_t copyProtection = VM_PROT_ALL;
        for(u64 offset = 0; offset < length; offset += DYN_PAGE_SIZE) {
            const khiter_t key = kh_get(memory, memory, u64(source) + offset);
            if(key == kh_end(memory) || !kh_value(memory, key) ||
                    !kh_value(memory, key)->addr) return KERN_INVALID_ADDRESS;
            copyProtection &= kh_value(memory, key)->perms;
        }
        if(!anywhere && !overwrite) {
            for(u64 page = destination; page < destination + length; page += DYN_PAGE_SIZE)
                if(kh_get(memory, memory, page) != kh_end(memory)) return KERN_NO_SPACE;
        }
        std::vector<uint8_t> snapshot;
        try { snapshot.resize(length); }
        catch(const std::exception &) { return KERN_RESOURCE_SHORTAGE; }
        if(!read_guest_memory_with_permissions(source, snapshot.data(),
                snapshot.size(), PROT_NONE)) return KERN_PROTECTION_FAILURE;
        const u32 mapped = Dynarmic_mmap(static_cast<u32>(destination), length,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | (anywhere ? 0 : MAP_FIXED),
            -1, 0, alignment);
        if(mapped == UINT32_MAX) return KERN_NO_SPACE;
        const int finalProtection = copyProtection &
            (PROT_READ | PROT_WRITE | PROT_EXEC);
        if(!write_guest_memory_with_permissions(mapped, snapshot.data(),
                snapshot.size(), PROT_NONE) ||
                (finalProtection != (PROT_READ | PROT_WRITE) &&
                 Dynarmic_mprotect(mapped, length, finalProtection) != 0)) {
            Dynarmic_munmap(mapped, length);
            return KERN_FAILURE;
        }
        *address = mapped;
        *protection = copyProtection;
        lock.unlock();
        InvalidateAllGuestJits(mapped, static_cast<size_t>(length));
        return KERN_SUCCESS;
    }

    std::vector<struct memory_page> pages;
    try { pages.resize(length / DYN_PAGE_SIZE); }
    catch(const std::exception &) { return KERN_RESOURCE_SHORTAGE; }
    vm_prot_t commonProtection = VM_PROT_ALL;
    for(size_t index = 0; index < pages.size(); ++index) {
        const khiter_t key = kh_get(memory, memory, u64(source) + index * DYN_PAGE_SIZE);
        if(key == kh_end(memory) || !kh_value(memory, key) ||
                !kh_value(memory, key)->addr) return KERN_INVALID_ADDRESS;
        pages[index] = *kh_value(memory, key);
        if(!pages[index].backing || (pages[index].perms & PROT_EXEC))
            return KERN_NOT_SUPPORTED;
        commonProtection &= pages[index].perms;
    }
    if(!anywhere && !overwrite) {
        for(u64 page = destination; page < destination + length; page += DYN_PAGE_SIZE)
            if(kh_get(memory, memory, page) != kh_end(memory)) return KERN_NO_SPACE;
    }

    std::vector<GuestPageReservation> reservations;
    const u64 mapped = Dynarmic_mem_reserve(destination, length, !anywhere,
        alignment, &reservations);
    if(mapped == UINT64_MAX) return KERN_NO_SPACE;
    // Retain every source first: an overlapping overwrite may release the
    // original mappings while later pages still refer to those same backings.
    for(const auto &page : pages) ++page.backing->references;
    InvalidateGuestMemoryLookupCaches();
    for(size_t index = 0; index < pages.size(); ++index) {
        ClearGuestPageTableEntries(mapped + index * DYN_PAGE_SIZE);
    }
    std::atomic_thread_fence(std::memory_order_seq_cst);
    for(size_t index = 0; index < pages.size(); ++index) {
        const u64 guestAddress = mapped + index * DYN_PAGE_SIZE;
        t_memory_page page = kh_value(memory, kh_get(memory, memory, guestAddress));
        t_memory_backing previous = page->backing;
        *page = pages[index];
        page->enforceDataPermissions = true;
        UpdateGuestPageTableEntries(guestAddress, page);
        ReleaseMemoryBackingReference(previous);
    }
    reservations.clear();
    *address = static_cast<u32>(mapped);
    *protection = commonProtection;
    lock.unlock();
    InvalidateAllGuestJits(*address, static_cast<size_t>(length));
    return KERN_SUCCESS;
}

int Dynarmic_mprotect(u64 address, u64 size, int perms) {
    std::unique_lock<std::recursive_mutex> lock(
        guestVmMutex);
    if(address & DYN_PAGE_MASK) {
        errno = EINVAL;
        return -1;
    }
    if(size == 0 || (size & DYN_PAGE_MASK)) {
        errno = EINVAL;
        return -1;
    }
    if (!GuestProtectionIsValid(perms)) {
        errno = EINVAL;
        return -1;
    }
    if (size > UINT64_MAX - address) {
        errno = EINVAL;
        return -1;
    }
    if (!GuestAddressRangeIsValid32(
            address, size)) {
        errno = EINVAL;
        return -1;
    }

    struct ProtectedPage {
        u64 address;
        t_memory_page page;
    };
    struct BackingProtectionUpdate {
        t_memory_backing backing;
        int requiredHostProtection;
    };

    khash_t(memory) *memory = sharedHandle.memory;
    std::vector<ProtectedPage> pages;
    std::vector<BackingProtectionUpdate>
        backingUpdates;
    std::unordered_map<t_memory_backing, size_t>
        backingUpdateIndices;

    try {
        pages.reserve(
            static_cast<size_t>(
                size / DYN_PAGE_SIZE));
        for(u64 vaddr = address;
                vaddr < address + size;
                vaddr += DYN_PAGE_SIZE) {
            khiter_t k = kh_get(
                memory, memory, vaddr);
            if(k == kh_end(memory)) {
                fprintf(stderr,
                    "mem_protect failed[%s->%s:%d]: "
                    "vaddr=%p\n",
                    __FILE__, __func__, __LINE__,
                    reinterpret_cast<void *>(vaddr));
                errno = ENOMEM;
                return -1;
            }
            t_memory_page page =
                kh_value(memory, k);
            pages.push_back({vaddr, page});
            if (page->backing == nullptr) {
                continue;
            }
            const auto insertion =
                backingUpdateIndices.emplace(
                    page->backing,
                    backingUpdates.size());
            if (insertion.second) {
                backingUpdates.push_back({
                    page->backing,
                    page->backing->hostProtection |
                        HostProtectionForGuestPermissions(
                            perms),
                });
            }
        }
    } catch (const std::exception &) {
        errno = ENOMEM;
        return -1;
    }

    /*
     * Remove fast-path pointers before changing permissions. Any new access
     * then enters a callback and waits on guestVmMutex until the operation is
     * committed or rolled back.
     */
    InvalidateGuestMemoryLookupCaches();
    for (const ProtectedPage &protectedPage :
            pages) {
        ClearGuestPageTableEntries(protectedPage.address);
    }

    /*
     * Host protections are widened when a guest page gains permissions, but
     * are never narrowed. Per-page guest permissions are enforced by the
     * page table/callback layer. This is intentional: one 16 KiB host page
     * can contain four independently protected 4 KiB guest pages, and
     * revoking the host page could crash another guest thread that already
     * loaded its fast-path pointer.
     */
    for (const BackingProtectionUpdate &update :
            backingUpdates) {
        if (update.requiredHostProtection ==
                update.backing->hostProtection) {
            continue;
        }
        if (mprotect(
                update.backing->addr,
                update.backing->size,
                update.requiredHostProtection) != 0) {
            const int savedErrno = errno;
            for (const ProtectedPage &protectedPage :
                    pages) {
                UpdateGuestPageTableEntries(
                    protectedPage.address,
                    protectedPage.page);
            }
            errno = savedErrno;
            return -1;
        }
        update.backing->hostProtection =
            update.requiredHostProtection;
    }

    for (const ProtectedPage &protectedPage :
            pages) {
        protectedPage.page->perms = perms;
        protectedPage.page->enforceDataPermissions =
            true;
        UpdateGuestPageTableEntries(
            protectedPage.address,
            protectedPage.page);
    }
    lock.unlock();
    InvalidateAllGuestJits(
        static_cast<u32>(address),
        static_cast<size_t>(size));
    return 0;
}

/*
 * Guest file mappings are host mmaps (MAP_SHARED stays shared), so msync
 * goes to the host pages behind the range. Gangstar Rio msyncs its mapped
 * save/cache file. The host ranges are collected under guestVmMutex and
 * flushed after it is released, since MS_SYNC may wait for I/O. A range
 * unmapped meanwhile only makes the host call fail. Like XNU: zero length
 * is EINVAL, unknown flag bits are ignored, and holes are skipped (the
 * mapped parts are still synced) and reported as ENOMEM.
 */
int Dynarmic_msync(u64 address, u64 size, int flags) {
    flags &= MS_ASYNC | MS_SYNC | MS_INVALIDATE | MS_KILLPAGES |
        MS_DEACTIVATE;
    if (((flags & MS_ASYNC) && (flags & MS_SYNC)) ||
            (address & DYN_PAGE_MASK) || size == 0) {
        errno = EINVAL;
        return -1;
    }
    if (size > UINT32_MAX || address > UINT32_MAX) {
        errno = ENOMEM;
        return -1;
    }
    size = (size + DYN_PAGE_MASK) & ~static_cast<u64>(DYN_PAGE_MASK);
    if (!GuestAddressRangeIsValid32(address, size)) {
        errno = ENOMEM;
        return -1;
    }

    struct HostRange {
        uintptr_t start;
        uintptr_t end;
    };
    std::vector<HostRange> ranges;
    bool hole = false;
    {
        std::lock_guard<std::recursive_mutex> lock(guestVmMutex);
        khash_t(memory) *memory = sharedHandle.memory;
        try {
            for (u64 vaddr = address; vaddr < address + size;
                    vaddr += DYN_PAGE_SIZE) {
                const khiter_t k = kh_get(memory, memory, vaddr);
                const t_memory_page page = k != kh_end(memory)
                    ? kh_value(memory, k) : nullptr;
                if (page == nullptr || page->addr == nullptr) {
                    hole = true;
                    continue;
                }
                const uintptr_t host =
                    reinterpret_cast<uintptr_t>(page->addr);
                if (!ranges.empty() && ranges.back().end == host) {
                    ranges.back().end = host + DYN_PAGE_SIZE;
                } else {
                    ranges.push_back({host, host + DYN_PAGE_SIZE});
                }
            }
        } catch (const std::exception &) {
            errno = ENOMEM;
            return -1;
        }
    }

    /*
     * Killing or deactivating pages would act on whole 16 KiB host pages,
     * which can hold neighbouring 4 KiB guest pages. Both are only hints,
     * so the host call is skipped for them.
     */
    if ((flags & (MS_KILLPAGES | MS_DEACTIVATE)) == 0) {
        const uintptr_t hostPageMask =
            static_cast<uintptr_t>(vm_page_size) - 1;
        for (const HostRange &range : ranges) {
            const uintptr_t start = range.start & ~hostPageMask;
            const uintptr_t end =
                (range.end + hostPageMask) & ~hostPageMask;
            if (msync(reinterpret_cast<void *>(start), end - start,
                    flags) != 0)
                return -1;
        }
    }
    if (hole) {
        errno = ENOMEM;
        return -1;
    }
    return 0;
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    mem_write
 * Signature: (JJ[B)I
 */
int Dynarmic_mem_1write(u64 address, u64 size, char* src) {
    if (size == 0) {
        return 0;
    }
    if (src == nullptr ||
            !GuestAddressRangeIsValid32(
                address, size)) {
        return 1;
    }
#ifndef LC32_GUEST_MEMORY_WATCH_ADDRESS
    if (CurrentThreadInGuestVmEpoch() &&
            sharedHandle.write_page_table != nullptr) {
        const u64 firstIdx = address >> DYN_PAGE_BITS;
        const u64 lastIdx = (address + size - 1) >> DYN_PAGE_BITS;
        if (firstIdx == lastIdx &&
                firstIdx < sharedHandle.num_page_table_entries) {
            const uintptr_t entry = reinterpret_cast<uintptr_t>(
                __atomic_load_n(
                    &sharedHandle.write_page_table[firstIdx],
                    __ATOMIC_ACQUIRE));
            if (entry != 0 && !GuestPageEverExternal(firstIdx)) {
                memcpy(
                    reinterpret_cast<char *>(entry + static_cast<uintptr_t>(address)),
                    src, static_cast<size_t>(size));
                return 0;
            }
        }
    }
#endif
    std::lock_guard<std::recursive_mutex> lock(guestVmMutex);
#ifdef LC32_GUEST_MEMORY_WATCH_ADDRESS
    const u64 originalAddress = address;
    const size_t originalSize = static_cast<size_t>(size);
    u32 oldWatchedValue = 0;
    const bool hadOldWatchedValue =
        GuestMemoryWatchOverlaps(address, originalSize) &&
        SnapshotGuestMemoryWatchLocked(&oldWatchedValue);
#endif
    u64 vaddr_end = address + size;
    for(u64 vaddr = address & ~DYN_PAGE_MASK; vaddr < vaddr_end; vaddr += DYN_PAGE_SIZE) {
        u64 start = vaddr < address ? address - vaddr : 0;
        u64 end = vaddr + DYN_PAGE_SIZE <= vaddr_end ? DYN_PAGE_SIZE : (vaddr_end - vaddr);
        u64 len = end - start;
        char *addr = get_memory_page(vaddr);
        if(addr == NULL) {
            fprintf(stderr, "mem_write failed[%s->%s:%d]: vaddr=%p\n", __FILE__, __func__, __LINE__, (void*)vaddr);
            return 1;
        }
        char *dest = &addr[start];
        //    printf("mem_write address=%p, vaddr=%p, start=%ld, len=%ld, addr=%p, dest=%p\n", (void*)address, (void*)vaddr, start, len, addr, dest);
        memcpy(dest, src, len);
        src += len;
    }
#ifdef LC32_GUEST_MEMORY_WATCH_ADDRESS
    LogGuestMemoryWatchWriteLocked(
        "raw", originalAddress, originalSize,
        hadOldWatchedValue, oldWatchedValue);
#endif
    return 0;
}

int ReplaceGuestMemoryRangeWithPrivateCopy(
        u32 address, size_t size, const void *source) {
    if(size == 0) return 0;
    if(source == nullptr || (address & DYN_PAGE_MASK) != 0 ||
            !GuestAddressRangeIsValid32(address, size) ||
            size > SIZE_MAX - DYN_PAGE_MASK) {
        errno = EINVAL;
        return -1;
    }

    const size_t mappedSize =
        (size + DYN_PAGE_MASK) & ~size_t(DYN_PAGE_MASK);
    struct ReplacedPage {
        u32 address;
        t_memory_page page;
    };
    std::vector<ReplacedPage> pages;
    try {
        pages.reserve(mappedSize / DYN_PAGE_SIZE);
    } catch(const std::exception &) {
        errno = ENOMEM;
        return -1;
    }

    std::unique_lock<std::recursive_mutex> lock(guestVmMutex);
    khash_t(memory) *memory = sharedHandle.memory;
    if(memory == nullptr) {
        errno = EFAULT;
        return -1;
    }
    for(size_t offset = 0; offset < mappedSize;
            offset += DYN_PAGE_SIZE) {
        const u64 pageAddress =
            static_cast<u64>(address) + offset;
        const khiter_t iterator = kh_get(
            memory, memory, pageAddress);
        if(iterator == kh_end(memory)) {
            errno = EFAULT;
            return -1;
        }
        t_memory_page page = kh_value(memory, iterator);
        if(page == nullptr || page->addr == nullptr) {
            errno = EFAULT;
            return -1;
        }
        const size_t pageOffset = offset;
        const size_t replacementBytes =
            size - pageOffset < DYN_PAGE_SIZE ?
                size - pageOffset : DYN_PAGE_SIZE;
        if(replacementBytes < DYN_PAGE_SIZE &&
                page->backing != nullptr &&
                (page->backing->hostProtection & PROT_READ) == 0) {
            errno = EACCES;
            return -1;
        }
        try {
            pages.push_back({
                static_cast<u32>(pageAddress), page,
            });
        } catch(const std::exception &) {
            errno = ENOMEM;
            return -1;
        }
    }

    void *privateMapping = mmap(
        nullptr, mappedSize,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if(privateMapping == MAP_FAILED) return -1;

    t_memory_backing privateBacking =
        static_cast<t_memory_backing>(
            calloc(1, sizeof(struct memory_backing)));
    if(privateBacking == nullptr) {
        const int savedErrno = errno;
        (void)munmap(privateMapping, mappedSize);
        errno = savedErrno == 0 ? ENOMEM : savedErrno;
        return -1;
    }

    auto *privateBytes = static_cast<uint8_t *>(privateMapping);
    for(size_t index = 0; index < pages.size(); ++index) {
        const size_t pageOffset = index * DYN_PAGE_SIZE;
        const size_t replacementBytes =
            size - pageOffset < DYN_PAGE_SIZE ?
                size - pageOffset : DYN_PAGE_SIZE;
        const size_t preservedBytes =
            DYN_PAGE_SIZE - replacementBytes;
        if(preservedBytes != 0) {
            memcpy(privateBytes + pageOffset + replacementBytes,
                static_cast<const uint8_t *>(
                    pages[index].page->addr) + replacementBytes,
                preservedBytes);
        }
    }
    memcpy(privateBytes, source, size);

    privateBacking->addr = privateMapping;
    privateBacking->size = mappedSize;
    privateBacking->references = pages.size();
    privateBacking->hostProtection = PROT_READ | PROT_WRITE;

    /* Every replacement page is complete before it becomes visible. Old
     * owned backings use the guest-VM epoch retirement path, so a JIT that
     * already loaded an old direct pointer cannot observe freed memory. */
    InvalidateGuestMemoryLookupCaches();
    for(const ReplacedPage &entry : pages) {
        ClearGuestPageTableEntries(entry.address);
    }
    for(size_t index = 0; index < pages.size(); ++index) {
        const ReplacedPage &entry = pages[index];
        t_memory_backing oldBacking = entry.page->backing;
        entry.page->addr = privateBytes + index * DYN_PAGE_SIZE;
        entry.page->backing = privateBacking;
        ReleaseMemoryBackingReference(oldBacking);
    }
    for(const ReplacedPage &entry : pages) {
        UpdateGuestPageTableEntries(entry.address, entry.page);
    }
    return 0;
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    mem_read
 * Signature: (JJI)[B
 */
int Dynarmic_mem_1read(u64 address, u64 size, char* dest) {
    if (size == 0) {
        return 0;
    }
    if (dest == nullptr ||
            !GuestAddressRangeIsValid32(
                address, size)) {
        return 1;
    }
    if (CurrentThreadInGuestVmEpoch() &&
            sharedHandle.page_table != nullptr) {
        const u64 firstIdx = address >> DYN_PAGE_BITS;
        const u64 lastIdx = (address + size - 1) >> DYN_PAGE_BITS;
        if (firstIdx == lastIdx &&
                firstIdx < sharedHandle.num_page_table_entries) {
            const uintptr_t entry = reinterpret_cast<uintptr_t>(
                __atomic_load_n(
                    &sharedHandle.page_table[firstIdx],
                    __ATOMIC_ACQUIRE));
            if (entry != 0 && !GuestPageEverExternal(firstIdx)) {
                memcpy(
                    dest,
                    reinterpret_cast<const char *>(entry + static_cast<uintptr_t>(address)),
                    static_cast<size_t>(size));
                return 0;
            }
        }
    }
    std::lock_guard<std::recursive_mutex> lock(guestVmMutex);
    u64 vaddr_end = address + size;
    for(u64 vaddr = address & ~DYN_PAGE_MASK; vaddr < vaddr_end; vaddr += DYN_PAGE_SIZE) {
        u64 start = vaddr < address ? address - vaddr : 0;
        u64 end = vaddr + DYN_PAGE_SIZE <= vaddr_end ? DYN_PAGE_SIZE : (vaddr_end - vaddr);
        u64 len = end - start;
        char *addr = get_memory_page(vaddr);
        if(addr == NULL) {
            fprintf(stderr, "mem_read failed[%s->%s:%d]: vaddr=%p\n", __FILE__, __func__, __LINE__, (void*)vaddr);
            return 1;
        }
        char *src = (char *)&addr[start];
        memcpy(dest, src, len);
        dest += len;
    }
    return 0;
}

static bool DebuggerMemoryRangeIsValid(u64 address, u64 size) {
    constexpr u64 addressSpaceSize = UINT64_C(1) << 32;
    return address < addressSpaceSize &&
           size <= addressSpaceSize - address;
}

static bool DebuggerRangesOverlap(u64 firstAddress,
                                  u64 firstSize,
                                  u64 secondAddress,
                                  u64 secondSize) {
    return firstSize != 0 && secondSize != 0 &&
           firstAddress < secondAddress + secondSize &&
           secondAddress < firstAddress + firstSize;
}

static bool DebuggerMemoryRangeIsMapped(u64 address, u64 size) {
    const u64 end = address + size;
    for (u64 page = address & ~DYN_PAGE_MASK; page < end;
         page += DYN_PAGE_SIZE) {
        if (get_memory_page(page) == nullptr) {
            return false;
        }
    }
    return true;
}

/*
 * LLDB's expression evaluator writes a small JIT image into inferior memory.
 * Some guest pages are backed by read-only host mappings, so a plain memcpy
 * would crash LiveExec32 itself. Temporarily add write permission to the
 * actual host VM pages, then restore their original protection.
 */
static int DebuggerWriteHostMemory(void *destination,
                                   const void *source,
                                   size_t size) {
    auto *dest = static_cast<uint8_t *>(destination);
    auto *src = static_cast<const uint8_t *>(source);

    while (size != 0) {
        vm_address_t regionAddress =
            reinterpret_cast<vm_address_t>(dest);
        vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t regionInfo = {};
        mach_msg_type_number_t regionInfoCount =
            VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t objectName = MACH_PORT_NULL;
        const kern_return_t regionResult = vm_region_64(
            mach_task_self(), &regionAddress, &regionSize,
            VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&regionInfo),
            &regionInfoCount, &objectName);
        if (objectName != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), objectName);
        }

        const vm_address_t destinationAddress =
            reinterpret_cast<vm_address_t>(dest);
        if (regionResult != KERN_SUCCESS ||
            destinationAddress < regionAddress ||
            destinationAddress - regionAddress >= regionSize) {
            return 1;
        }
        const vm_size_t available =
            regionSize - (destinationAddress - regionAddress);
        const size_t chunk =
            size < available ? size : static_cast<size_t>(available);

        bool protectionChanged = false;
        vm_address_t protectStart = 0;
        vm_size_t protectSize = 0;
        if ((regionInfo.protection & VM_PROT_WRITE) == 0) {
            if ((regionInfo.max_protection & VM_PROT_WRITE) == 0 ||
                vm_page_size == 0 ||
                destinationAddress >
                    UINTPTR_MAX - chunk - (vm_page_size - 1)) {
                return 1;
            }
            protectStart =
                destinationAddress -
                destinationAddress % vm_page_size;
            const vm_address_t protectEnd =
                (destinationAddress + chunk + vm_page_size - 1) /
                vm_page_size * vm_page_size;
            protectSize = protectEnd - protectStart;
            if (vm_protect(mach_task_self(), protectStart, protectSize,
                           FALSE,
                           regionInfo.protection | VM_PROT_WRITE) !=
                KERN_SUCCESS) {
                return 1;
            }
            protectionChanged = true;
        }

        memcpy(dest, src, chunk);

        if (protectionChanged &&
            vm_protect(mach_task_self(), protectStart, protectSize,
                       FALSE, regionInfo.protection) != KERN_SUCCESS) {
            return 1;
        }
        dest += chunk;
        src += chunk;
        size -= chunk;
    }
    return 0;
}

static int DebuggerWritePhysicalMemory(u64 address,
                                       u64 size,
                                       const char *source) {
    const u64 end = address + size;
    for (u64 page = address & ~DYN_PAGE_MASK; page < end;
         page += DYN_PAGE_SIZE) {
        const u64 start = page < address ? address - page : 0;
        const u64 pageEnd =
            page + DYN_PAGE_SIZE < end ? page + DYN_PAGE_SIZE : end;
        const size_t length =
            static_cast<size_t>(pageEnd - page - start);
        char *hostPage = get_memory_page(page);
        if (hostPage == nullptr ||
            DebuggerWriteHostMemory(hostPage + start, source,
                                    length) != 0) {
            return 1;
        }
        source += length;
    }
    return 0;
}

static bool ReadGuestCodeWord(u32 address, u32 *value) {
    const char *page = get_memory_page(address & ~DYN_PAGE_MASK);
    if (page == nullptr) {
        return false;
    }
    memcpy(value, page + (address & DYN_PAGE_MASK), sizeof(*value));
    return true;
}

/*
 * Gameloft's XPlayer networking library (2009-2011 games such as Starfront
 * Collision) resolves each host on its own pthread. threadGetHostByNameProcess
 * appends the result to a 4-entry global table, but after allocating the slot
 * it re-reads the shared count for every later access instead of keeping its
 * index. Two lookups finishing together (the game starts two for
 * gllive.gameloft.com at launch) then memset/store through an empty slot and
 * crash. Single-core iPhones rarely interleaved there; native guest threads
 * do, roughly one launch in six.
 *
 * Keep the index the function already loaded into r8 (callee-saved), and
 * publish count = index + 1 at the end. The count is stored through r11, which
 * holds the table base, so the fixup only applies when the literal pool proves
 * the count directly follows the 4-entry table.
 */
static const struct {
    u32 offset;
    u32 value;
    u32 mask;
} XPlayerHostTableSignature[] = {
    {0x00, 0xe59f00bc, ~0u},  // ldr r0, =count - (pc)
    {0x04, 0xe79f8000, ~0u},  // ldr r8, [pc, r0]      ; r8 = index
    {0x08, 0xe3580003, ~0u},  // cmp r8, #3
    {0x0c, 0xca000027, ~0u},  // bgt done
    {0x10, 0xe59f00b0, ~0u},  // ldr r0, =table - (pc)
    {0x14, 0xe59fa0b0, ~0u},  // ldr r10, =count - (pc)
    {0x18, 0xe08fb000, ~0u},  // add r11, pc, r0       ; r11 = table
    {0x1c, 0xe3a00014, ~0u},  // mov r0, #20
    {0x20, 0xeb000000, 0xff000000u},  // bl operator new
    {0x24, 0xe78b0108, ~0u},  // str r0, [r11, r8, lsl #2]
    {0x28, 0xe08f800a, ~0u},  // add r8, pc, r10       ; r8 = &count
    {0x2c, 0xe3a01000, ~0u},
    {0x30, 0xe3a02014, ~0u},
    {0x34, 0xe5980000, ~0u},  // ldr r0, [r8]
    {0x38, 0xe79b0100, ~0u},
    {0x3c, 0xeb000000, 0xff000000u},  // bl memset
    {0x40, 0xe5980000, ~0u},
    {0x44, 0xe596100c, ~0u},
    {0x48, 0xe79b0100, ~0u},
    {0x4c, 0xe580100c, ~0u},
    {0x50, 0xe5980000, ~0u},
    {0x54, 0xe79ba100, ~0u},
    {0x58, 0xe1a00005, ~0u},
    {0x5c, 0xeb000000, 0xff000000u},  // bl strnew
    {0x60, 0xe58a0000, ~0u},
    {0x64, 0xe5980000, ~0u},
    {0x68, 0xe79ba100, ~0u},
    {0x6c, 0xe3a00004, ~0u},
    {0x70, 0xeb000000, 0xff000000u},  // bl operator new[]
    {0x74, 0xe58a0010, ~0u},
    {0x78, 0xe5980000, ~0u},
    {0x7c, 0xe5961010, ~0u},
    {0x80, 0xe79b0100, ~0u},
    {0x84, 0xe5906010, ~0u},
    {0x88, 0xe5910000, ~0u},
    {0x8c, 0xeb000000, 0xff000000u},  // bl strnew
    {0x90, 0xe5860000, ~0u},
    {0x94, 0xe5980000, ~0u},
    {0x98, 0xe59f1030, ~0u},
    {0x9c, 0xe2800001, ~0u},  // add r0, r0, #1
    {0xa0, 0xe5880000, ~0u},  // str r0, [r8]
};

static const struct {
    u32 offset;
    u32 value;
} XPlayerHostTablePatch[] = {
    {0x28, 0xe1a00000},  // nop: r8 keeps the index
    {0x34, 0xe1a00008},  // mov r0, r8
    {0x40, 0xe1a00008},
    {0x50, 0xe1a00008},
    {0x64, 0xe1a00008},
    {0x78, 0xe1a00008},
    {0x94, 0xe1a00008},
    {0xa0, 0xe58b0010},  // str r0, [r11, #16]    ; count = index + 1
};

static bool XPlayerHostTableMatches(u32 site) {
    for (const auto &word : XPlayerHostTableSignature) {
        u32 value = 0;
        if (!ReadGuestCodeWord(site + word.offset, &value) ||
                (value & word.mask) != word.value) {
            return false;
        }
    }
    // Literal pool: +0x00 loads +0xc4 (count, used at +0x04 with pc +0x0c),
    // +0x10 loads +0xc8 (table, used at +0x18 with pc +0x20), and +0x14 loads
    // +0xcc (count again, used at +0x28 with pc +0x30).
    u32 countLiteral = 0, tableLiteral = 0, countLiteral2 = 0;
    if (!ReadGuestCodeWord(site + 0xc4, &countLiteral) ||
            !ReadGuestCodeWord(site + 0xc8, &tableLiteral) ||
            !ReadGuestCodeWord(site + 0xcc, &countLiteral2)) {
        return false;
    }
    const u32 count = site + 0x0c + countLiteral;
    const u32 table = site + 0x20 + tableLiteral;
    if (site + 0x30 + countLiteral2 != count) {
        return false;
    }
    return count == table + 0x10;
}

void Dynarmic_apply_guest_code_fixups() {
    u32 start = 0, end = 0;
    {
        std::lock_guard<std::mutex> lock(guestMappingMutex);
        if (guestMappingLen < 1) {
            return;
        }
        start = guestMappings[0].start;
        end = guestMappings[0].end;
    }
    for (u32 site = (start + 3) & ~3u; site + 0xd0 <= end; site += 4) {
        u32 first = 0;
        if (!ReadGuestCodeWord(site, &first) ||
                first != XPlayerHostTableSignature[0].value ||
                !XPlayerHostTableMatches(site)) {
            continue;
        }
        bool patched = true;
        for (const auto &word : XPlayerHostTablePatch) {
            if (DebuggerWritePhysicalMemory(site + word.offset,
                    sizeof(word.value),
                    reinterpret_cast<const char *>(&word.value)) != 0) {
                patched = false;
            }
        }
        InvalidateAllGuestJits(site, 0xa4);
        fprintf(stderr,
            "LC32: %s XPlayer host-table race fixup at 0x%08x\n",
            patched ? "applied" : "FAILED to apply", site);
    }
}

bool Dynarmic_guest_tracepoint_set(u64 address) {
    if (address > UINT32_MAX) {
        return false;
    }
    const bool thumb = (address & 1u) != 0;
    const u32 guestAddress = static_cast<u32>(address) & ~1u;
    const size_t kind = thumb
        ? sizeof(uint16_t) : sizeof(uint32_t);

    std::lock_guard<std::mutex> lock(
        guestSoftwareTracepointsMutex);
    for (const GuestSoftwareTracepoint &tracepoint :
         guestSoftwareTracepoints) {
        if (tracepoint.address == guestAddress) {
            return tracepoint.kind == kind;
        }
    }
    for (const DebuggerSoftwareBreakpoint &breakpoint :
         debuggerSoftwareBreakpoints) {
        if (DebuggerRangesOverlap(
                guestAddress, kind,
                breakpoint.address, breakpoint.kind)) {
            return false;
        }
    }

    GuestSoftwareTracepoint tracepoint = {
        .address = guestAddress,
        .kind = kind,
        .original = {},
        .fired = false,
    };
    if (Dynarmic_mem_1read(
            guestAddress, kind,
            reinterpret_cast<char *>(
                tracepoint.original.data())) != 0) {
        return false;
    }

    const uint32_t trap = thumb ? 0xBE00u : 0xE1200070u;
    guestSoftwareTracepoints.push_back(tracepoint);
    if (DebuggerWritePhysicalMemory(
            guestAddress, kind,
            reinterpret_cast<const char *>(&trap)) != 0) {
        guestSoftwareTracepoints.pop_back();
        return false;
    }
    InvalidateAllGuestJits(guestAddress, kind);
    return true;
}

bool ConsumeGuestSoftwareTracepoint(
        u32 pc, Dynarmic::A32::Jit *cpu) {
    const u32 guestAddress = pc & ~1u;
    GuestSoftwareTracepoint tracepoint = {};
    {
        std::lock_guard<std::mutex> lock(
            guestSoftwareTracepointsMutex);
        auto it = std::find_if(
            guestSoftwareTracepoints.begin(),
            guestSoftwareTracepoints.end(),
            [guestAddress](const GuestSoftwareTracepoint &candidate) {
                return candidate.address == guestAddress;
            });
        if (it == guestSoftwareTracepoints.end()) {
            return false;
        }
        if (!it->fired) {
            if (DebuggerWritePhysicalMemory(
                    guestAddress, it->kind,
                    reinterpret_cast<const char *>(
                        it->original.data())) != 0) {
                fprintf(stderr,
                    "LC32 guest tracepoint 0x%08x: failed to restore "
                    "the original instruction\n",
                    guestAddress);
                return false;
            }
            it->fired = true;
        }
        tracepoint = *it;
    }

    // Only the first JIT to arrive owns the trace event.  Keep the fired
    // record as a tombstone: another native guest JIT may already have
    // translated the old BKPT and arrive after the physical bytes were
    // restored but before it processes its queued invalidation.
    static std::mutex loggedTracepointsMutex;
    static std::unordered_set<u32> loggedTracepoints;
    bool shouldLog = false;
    {
        std::lock_guard<std::mutex> lock(loggedTracepointsMutex);
        shouldLog = loggedTracepoints.insert(guestAddress).second;
    }
    if (shouldLog) {
        const auto &registers = cpu->Regs();
        fprintf(stderr,
            "LC32 guest tracepoint 0x%08x "
            "r0=%08x r1=%08x r2=%08x r3=%08x "
            "sp=%08x lr=%08x cpsr=%08x host_thread=%u\n",
            guestAddress,
            registers[Reg::R0], registers[Reg::R1],
            registers[Reg::R2], registers[Reg::R3],
            registers[Reg::SP], registers[Reg::LR], cpu->Cpsr(),
            pthread_mach_thread_np(pthread_self()));
        std::array<u32, 10> r0Words = {};
        if (registers[Reg::R0] != 0 &&
                Dynarmic_mem_1read(
                    registers[Reg::R0], sizeof(r0Words),
                    reinterpret_cast<char *>(r0Words.data())) == 0) {
            fprintf(stderr,
                "LC32 guest tracepoint 0x%08x r0_words="
                "%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x\n",
                guestAddress,
                r0Words[0], r0Words[1], r0Words[2], r0Words[3],
                r0Words[4], r0Words[5], r0Words[6], r0Words[7],
                r0Words[8], r0Words[9]);

#ifdef LC32_TRACE_GUEST_TRACEPOINT_ISA
            std::array<u32, 8> r0IsaWords = {};
            if (r0Words[0] != 0 &&
                    Dynarmic_mem_1read(
                        r0Words[0], sizeof(r0IsaWords),
                        reinterpret_cast<char *>(
                            r0IsaWords.data())) == 0) {
                fprintf(stderr,
                    "LC32 guest tracepoint 0x%08x r0_isa=%08x "
                    "isa_words=%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x\n",
                    guestAddress, r0Words[0],
                    r0IsaWords[0], r0IsaWords[1],
                    r0IsaWords[2], r0IsaWords[3],
                    r0IsaWords[4], r0IsaWords[5],
                    r0IsaWords[6], r0IsaWords[7]);
            }
#endif
        }
        std::array<u32, 10> r1Words = {};
        if (registers[Reg::R1] != 0 &&
                Dynarmic_mem_1read(
                    registers[Reg::R1], sizeof(r1Words),
                    reinterpret_cast<char *>(r1Words.data())) == 0) {
            fprintf(stderr,
                "LC32 guest tracepoint 0x%08x r1_words="
                "%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x\n",
                guestAddress,
                r1Words[0], r1Words[1], r1Words[2], r1Words[3],
                r1Words[4], r1Words[5], r1Words[6], r1Words[7],
                r1Words[8], r1Words[9]);
        }
        std::array<u32, 10> r2Words = {};
        if (registers[Reg::R2] != 0 &&
                Dynarmic_mem_1read(
                    registers[Reg::R2], sizeof(r2Words),
                    reinterpret_cast<char *>(r2Words.data())) == 0) {
            fprintf(stderr,
                "LC32 guest tracepoint 0x%08x r2_words="
                "%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x\n",
                guestAddress,
                r2Words[0], r2Words[1], r2Words[2], r2Words[3],
                r2Words[4], r2Words[5], r2Words[6], r2Words[7],
                r2Words[8], r2Words[9]);
        }
        std::array<u32, 6> r3Words = {};
        if (registers[Reg::R3] != 0 &&
                Dynarmic_mem_1read(
                    registers[Reg::R3], sizeof(r3Words),
                    reinterpret_cast<char *>(r3Words.data())) == 0) {
            fprintf(stderr,
                "LC32 guest tracepoint 0x%08x r3_words="
                "%08x,%08x,%08x,%08x,%08x,%08x\n",
                guestAddress,
                r3Words[0], r3Words[1], r3Words[2],
                r3Words[3], r3Words[4], r3Words[5]);
        }
        std::array<u32, 12> stackWords = {};
        if (registers[Reg::SP] != 0 &&
                Dynarmic_mem_1read(
                    registers[Reg::SP], sizeof(stackWords),
                    reinterpret_cast<char *>(stackWords.data())) == 0) {
            fprintf(stderr,
                "LC32 guest tracepoint 0x%08x stack_words="
                "%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,"
                "%08x,%08x,%08x,%08x\n",
                guestAddress,
                stackWords[0], stackWords[1], stackWords[2],
                stackWords[3], stackWords[4], stackWords[5],
                stackWords[6], stackWords[7], stackWords[8],
                stackWords[9], stackWords[10], stackWords[11]);
        }
    }

    // Dynarmic reports the PC after executing BKPT.  Replay the instruction
    // that the tracepoint temporarily replaced, and force every guest JIT to
    // discard translations that contain the trap.
    cpu->Regs()[Reg::PC] = guestAddress;
    InvalidateAllGuestJits(
        guestAddress, tracepoint.kind);
    return true;
}

/*
 * RSP memory reads describe the logical inferior memory.  Software
 * breakpoints are a debugger implementation detail, so overlay the saved
 * instruction bytes over the physically planted trap before replying.
 */
int Dynarmic_debugger_mem_read(u64 address, u64 size, char* dest) {
    if (!DebuggerMemoryRangeIsValid(address, size) ||
        (size != 0 && dest == nullptr) ||
        Dynarmic_mem_1read(address, size, dest) != 0) {
        return 1;
    }

    for (const DebuggerSoftwareBreakpoint &breakpoint :
         debuggerSoftwareBreakpoints) {
        if (!DebuggerRangesOverlap(address, size, breakpoint.address,
                                   breakpoint.kind)) {
            continue;
        }

        const u64 overlapStart =
            address > breakpoint.address ? address : breakpoint.address;
        const u64 requestEnd = address + size;
        const u64 breakpointEnd = breakpoint.address + breakpoint.kind;
        const u64 overlapEnd =
            requestEnd < breakpointEnd ? requestEnd : breakpointEnd;
        memcpy(dest + overlapStart - address,
               breakpoint.original.data() +
                   (overlapStart - breakpoint.address),
               overlapEnd - overlapStart);
    }
    return 0;
}

/*
 * A debugger memory write changes the logical instruction beneath any
 * active software breakpoint.  Keep the physical trap planted, update the
 * bytes that will be restored by z0, and invalidate translated code for the
 * whole modified range.
 */
int Dynarmic_debugger_mem_write(u64 address, u64 size, char* src) {
    if (!DebuggerMemoryRangeIsValid(address, size) ||
        (size != 0 && src == nullptr) ||
        !DebuggerMemoryRangeIsMapped(address, size)) {
        return 1;
    }
    if (size == 0) {
        return 0;
    }

    std::vector<uint8_t> physical(
        reinterpret_cast<uint8_t *>(src),
        reinterpret_cast<uint8_t *>(src) + size);
    for (const DebuggerSoftwareBreakpoint &breakpoint :
         debuggerSoftwareBreakpoints) {
        if (!DebuggerRangesOverlap(address, size, breakpoint.address,
                                   breakpoint.kind)) {
            continue;
        }

        const u64 overlapStart =
            address > breakpoint.address ? address : breakpoint.address;
        const u64 requestEnd = address + size;
        const u64 breakpointEnd = breakpoint.address + breakpoint.kind;
        const u64 overlapEnd =
            requestEnd < breakpointEnd ? requestEnd : breakpointEnd;
        memcpy(physical.data() + overlapStart - address,
               breakpoint.trap.data() +
                   (overlapStart - breakpoint.address),
               overlapEnd - overlapStart);
    }

    if (DebuggerWritePhysicalMemory(
            address, size,
            reinterpret_cast<const char *>(physical.data())) != 0) {
        return 1;
    }

    for (DebuggerSoftwareBreakpoint &breakpoint :
         debuggerSoftwareBreakpoints) {
        if (!DebuggerRangesOverlap(address, size, breakpoint.address,
                                   breakpoint.kind)) {
            continue;
        }

        const u64 overlapStart =
            address > breakpoint.address ? address : breakpoint.address;
        const u64 requestEnd = address + size;
        const u64 breakpointEnd = breakpoint.address + breakpoint.kind;
        const u64 overlapEnd =
            requestEnd < breakpointEnd ? requestEnd : breakpointEnd;
        memcpy(breakpoint.original.data() +
                   (overlapStart - breakpoint.address),
               reinterpret_cast<uint8_t *>(src) +
                   (overlapStart - address),
               overlapEnd - overlapStart);
    }

    InvalidateAllGuestJits(
        static_cast<u32>(address),
        static_cast<size_t>(size));
    return 0;
}

static u32 NormalizeDebuggerBreakpointAddress(u64 address, size_t kind) {
    if (address > UINT32_MAX) {
        return UINT32_MAX;
    }
    const u32 guestAddress = static_cast<u32>(address);
    return kind == sizeof(uint16_t) ? guestAddress & ~1u : guestAddress;
}

bool Dynarmic_debugger_has_breakpoint(u32 address) {
    address &= ~1u;
    for (const DebuggerSoftwareBreakpoint &breakpoint :
         debuggerSoftwareBreakpoints) {
        if (breakpoint.address == address) {
            return true;
        }
    }
    return false;
}

bool Dynarmic_debugger_set_breakpoint(u64 address, size_t kind) {
    if (kind != sizeof(uint16_t) && kind != sizeof(uint32_t)) {
        return false;
    }

    const u32 guestAddress =
        NormalizeDebuggerBreakpointAddress(address, kind);
    if (guestAddress == UINT32_MAX ||
        (kind == sizeof(uint32_t) &&
         (guestAddress & (sizeof(uint32_t) - 1)) != 0)) {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(
            guestSoftwareTracepointsMutex);
        for (const GuestSoftwareTracepoint &tracepoint :
             guestSoftwareTracepoints) {
            if (DebuggerRangesOverlap(
                    guestAddress, kind,
                    tracepoint.address,
                    tracepoint.kind)) {
                return false;
            }
        }
    }

    for (const DebuggerSoftwareBreakpoint &breakpoint :
         debuggerSoftwareBreakpoints) {
        if (breakpoint.address == guestAddress &&
            breakpoint.kind == kind) {
            return true;
        }
        if (DebuggerRangesOverlap(guestAddress, kind, breakpoint.address,
                                  breakpoint.kind)) {
            return false;
        }
    }

    DebuggerSoftwareBreakpoint breakpoint = {
        .address = guestAddress,
        .kind = kind,
        .original = {},
        .trap = {},
    };
    if (Dynarmic_mem_1read(guestAddress, kind,
                           reinterpret_cast<char *>(
                               breakpoint.original.data())) != 0) {
        return false;
    }

    const uint32_t instruction =
        kind == sizeof(uint16_t) ? 0x0000BE00u : 0xE1200070u;
    memcpy(breakpoint.trap.data(), &instruction, kind);
    // Allocate registry storage before modifying guest code so the running
    // process can never contain an untracked trap instruction.
    debuggerSoftwareBreakpoints.push_back(breakpoint);
    if (DebuggerWritePhysicalMemory(
            guestAddress, kind,
            reinterpret_cast<const char *>(
                debuggerSoftwareBreakpoints.back().trap.data())) != 0) {
        debuggerSoftwareBreakpoints.pop_back();
        return false;
    }
    InvalidateAllGuestJits(guestAddress, kind);
    return true;
}

bool Dynarmic_debugger_delete_breakpoint(u64 address, size_t kind) {
    (void)kind;
    if (address > UINT32_MAX) {
        return false;
    }

    /*
     * LLDB derives ARM breakpoint kind again when disabling a site.  Its
     * answer can differ from the kind used by the earlier Z0 packet (for
     * example, Z0(...,2) followed by z0(...,4) for Thumb code).  The active
     * record is authoritative: locate it by canonical address and restore
     * the exact byte count saved when it was installed.
     */
    const u32 guestAddress = static_cast<u32>(address) & ~1u;
    for (auto it = debuggerSoftwareBreakpoints.begin();
         it != debuggerSoftwareBreakpoints.end(); ++it) {
        if (it->address != guestAddress) {
            continue;
        }
        if (DebuggerWritePhysicalMemory(
                guestAddress, it->kind,
                reinterpret_cast<const char *>(
                    it->original.data())) != 0) {
            return false;
        }
        InvalidateAllGuestJits(
            guestAddress, it->kind);
        debuggerSoftwareBreakpoints.erase(it);
        return true;
    }

    // GDB remote breakpoint removal is idempotent.
    return true;
}

/*
 * A software breakpoint is physical guest code patched with BKPT.  Leaving
 * the debugger must therefore be transactional with respect to execution:
 * restore every reachable site while the target is still all-stop, retain
 * failed records so the caller can refuse to run with a planted trap, and
 * invalidate every JIT which may have translated either byte sequence.
 */
bool Dynarmic_debugger_remove_all_breakpoints() {
    bool restoredAll = true;
    for (auto it = debuggerSoftwareBreakpoints.begin();
         it != debuggerSoftwareBreakpoints.end();) {
        if (DebuggerWritePhysicalMemory(
                it->address, it->kind,
                reinterpret_cast<const char *>(
                    it->original.data())) != 0) {
            restoredAll = false;
            ++it;
            continue;
        }
        InvalidateAllGuestJits(it->address, it->kind);
        it = debuggerSoftwareBreakpoints.erase(it);
    }
    return restoredAll && debuggerSoftwareBreakpoints.empty();
}

size_t Dynarmic_debugger_thread_ids(
        gdb_thread_id_t *ids, size_t capacity) {
    if (threadHandle.jit == nullptr) {
        return 0;
    }
    EnsureGuestThreadRegistry();

    size_t count = 0;
    const auto append = [&](gdb_thread_id_t id) {
        if (ids != nullptr && count < capacity) {
            ids[count] = id;
        }
        ++count;
    };
    {
        std::lock_guard<std::recursive_mutex> lock(
            guestThreadMutex);
        for (const GuestThreadContext &thread : guestThreads) {
            if (!thread.alive) {
                continue;
            }
            if (thread.debuggerId == 1 ||
                    thread.debuggerId >= 3) {
                append(thread.debuggerId);
            }
        }
    }
    {
        std::lock_guard<std::recursive_mutex> lock(
            guestWorkqueueMutex);
        if (guestWorkqueueUpcallActive &&
                guestWorkqueueWaitingContextValid) {
            append(2);
        }
    }
    return count;
}

gdb_thread_id_t Dynarmic_debugger_current_thread() {
    EnsureGuestThreadRegistry();
    if (NativeDebuggerActive()) {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        return nativeDebugger.stopOwner;
    }
    return guestWorkqueueUpcallActive
        ? 2
        : guestCurrentThreadId;
}

bool Dynarmic_debugger_thread_alive(gdb_thread_id_t thread_id) {
    if (sharedHandle.cb == nullptr ||
            DynarmicCallbacks32Jit(sharedHandle.cb) == nullptr) {
        return false;
    }
    EnsureGuestThreadRegistry();
    if (thread_id == 2) {
        std::lock_guard<std::recursive_mutex> lock(
            guestWorkqueueMutex);
        return guestWorkqueueUpcallActive &&
            guestWorkqueueWaitingContextValid;
    }
    std::lock_guard<std::recursive_mutex> lock(
        guestThreadMutex);
    for (const GuestThreadContext &thread : guestThreads) {
        if (thread.debuggerId == thread_id) {
            return thread.alive;
        }
    }
    return false;
}

bool Dynarmic_debugger_thread_resumable(
        gdb_thread_id_t thread_id) {
    if (!Dynarmic_debugger_thread_alive(thread_id)) {
        return false;
    }
    bool overlayAllowsThread;
    {
        std::lock_guard<std::recursive_mutex> lock(
            guestWorkqueueMutex);
        /*
         * The workqueue pseudo-thread overlays the main JIT. Its interrupted
         * context remains readable as thread 1, but cannot execute
         * independently until thread 2 returns and restores it.
         */
        overlayAllowsThread =
            !guestWorkqueueUpcallActive ||
            !guestWorkqueueWaitingContextValid ||
            thread_id != guestWorkqueueWaitingThreadId;
    }
    if (!overlayAllowsThread ||
            NativeGuestThreadsEnabled() ||
            thread_id == 2) {
        return overlayAllowsThread;
    }

    /*
     * A cooperative thread can be selected by LLDB only when its saved
     * context is runnable. The target thread loads that context immediately
     * before executing the resume request.
     */
    std::lock_guard<std::recursive_mutex> threadLock(
        guestThreadMutex);
    for (const GuestThreadContext &thread : guestThreads) {
        if (thread.debuggerId == thread_id) {
            return thread.alive && thread.runnable &&
                (thread_id == guestCurrentThreadId ||
                 thread.savedValid);
        }
    }
    return false;
}

static bool SelectCooperativeDebuggerThread(
        gdb_thread_id_t thread_id) {
    if (NativeGuestThreadsEnabled()) {
        return true;
    }
    EnsureGuestThreadRegistry();
    {
        std::lock_guard<std::recursive_mutex> workqueueLock(
            guestWorkqueueMutex);
        if (guestWorkqueueUpcallActive &&
                guestWorkqueueWaitingContextValid) {
            return thread_id == 2;
        }
        if (thread_id == 2) {
            return false;
        }
    }

    std::lock_guard<std::recursive_mutex> threadLock(
        guestThreadMutex);
    if (thread_id == guestCurrentThreadId) {
        return true;
    }
    GuestThreadContext *current =
        FindGuestThread(guestCurrentThreadId, true);
    GuestThreadContext *selected =
        FindGuestThread(thread_id, true);
    if (current == nullptr || selected == nullptr ||
            !selected->runnable ||
            !selected->savedValid ||
            threadHandle.jit == nullptr ||
            threadHandle.cb == nullptr) {
        return false;
    }

    SaveGuestContext(current->saved);
    current->savedValid = true;
    LoadGuestContext(selected->saved);
    guestCurrentThreadId = thread_id;
    guestThreadRotationRequested = false;
    guestThreadCurrentRetiring = false;
    return true;
}

bool Dynarmic_debugger_thread_read_reg(
        gdb_thread_id_t thread_id, int regno, u32 *value) {
    if (value == nullptr || regno < 0 || regno > 16) {
        return false;
    }

    std::unique_lock<std::mutex> debuggerLock;
    if (NativeDebuggerActive()) {
        debuggerLock = std::unique_lock<std::mutex>(
            nativeDebugger.mutex);
        if (nativeDebugger.state !=
                NativeDebuggerRunState::Stopped ||
                nativeDebugger.mainExecuting ||
                nativeDebugger.executingWorkers != 0) {
            return false;
        }
    }

    {
        std::lock_guard<std::recursive_mutex> lock(
            guestWorkqueueMutex);
        if (guestWorkqueueUpcallActive &&
                guestWorkqueueWaitingContextValid &&
                thread_id == 2) {
            Dynarmic::A32::Jit *jit =
                sharedHandle.cb != nullptr
                ? DynarmicCallbacks32Jit(sharedHandle.cb)
                : nullptr;
            if (jit == nullptr) {
                return false;
            }
            *value = regno == 16
                ? static_cast<u32>(jit->Cpsr())
                : jit->Regs()[regno];
            return true;
        }
        if (guestWorkqueueUpcallActive &&
                guestWorkqueueWaitingContextValid &&
                thread_id ==
                    guestWorkqueueWaitingThreadId) {
            *value = regno == 16
                ? guestWorkqueueWaitingContext.cpsr
                : guestWorkqueueWaitingContext.regs[regno];
            return true;
        }
        if (thread_id == 2) {
            return false;
        }
    }

    std::lock_guard<std::recursive_mutex> lock(
        guestThreadMutex);
    for (GuestThreadContext &thread : guestThreads) {
        if (thread.debuggerId != thread_id ||
                !thread.alive) {
            continue;
        }
        Dynarmic::A32::Jit *jit = nullptr;
        if (NativeDebuggerActive()) {
            jit = thread_id == 1
                ? (sharedHandle.cb != nullptr
                    ? DynarmicCallbacks32Jit(sharedHandle.cb)
                    : nullptr)
                : (thread.nativeJit != nullptr
                    ? thread.nativeJit->jit
                    : nullptr);
        } else if (thread_id ==
                Dynarmic_debugger_current_thread()) {
            jit = threadHandle.jit;
        }
        if (jit != nullptr) {
            *value = regno == 16
                ? static_cast<u32>(jit->Cpsr())
                : jit->Regs()[regno];
            return true;
        }
        if (thread.savedValid) {
            *value = regno == 16
                ? thread.saved.cpsr
                : thread.saved.regs[regno];
            return true;
        }
        return false;
    }
    return false;
}

bool Dynarmic_debugger_thread_write_reg(
        gdb_thread_id_t thread_id, int regno, u32 value) {
    if (regno < 0 || regno > 16) {
        return false;
    }

    std::unique_lock<std::mutex> debuggerLock;
    if (NativeDebuggerActive()) {
        debuggerLock = std::unique_lock<std::mutex>(
            nativeDebugger.mutex);
        if (nativeDebugger.state !=
                NativeDebuggerRunState::Stopped ||
                nativeDebugger.mainExecuting ||
                nativeDebugger.executingWorkers != 0) {
            return false;
        }
    }

    {
        std::lock_guard<std::recursive_mutex> lock(
            guestWorkqueueMutex);
        if (guestWorkqueueUpcallActive &&
                guestWorkqueueWaitingContextValid &&
                thread_id == 2) {
            Dynarmic::A32::Jit *jit =
                sharedHandle.cb != nullptr
                ? DynarmicCallbacks32Jit(sharedHandle.cb)
                : nullptr;
            if (jit == nullptr) {
                return false;
            }
            if (regno == 16) {
                jit->SetCpsr(value);
            } else {
                jit->Regs()[regno] = value;
            }
            return true;
        }
        if (guestWorkqueueUpcallActive &&
                guestWorkqueueWaitingContextValid &&
                thread_id ==
                    guestWorkqueueWaitingThreadId) {
            if (regno == 16) {
                guestWorkqueueWaitingContext.cpsr = value;
            } else {
                guestWorkqueueWaitingContext.regs[regno] =
                    value;
            }
            return true;
        }
        if (thread_id == 2) {
            return false;
        }
    }

    std::lock_guard<std::recursive_mutex> lock(
        guestThreadMutex);
    for (GuestThreadContext &thread : guestThreads) {
        if (thread.debuggerId != thread_id ||
                !thread.alive) {
            continue;
        }
        Dynarmic::A32::Jit *jit = nullptr;
        if (NativeDebuggerActive()) {
            if (thread.nativeJit != nullptr &&
                    (thread.nativeJit->debuggerHostWaitPaused ||
                     thread.nativeJit->debuggerHostCallQuiescent)) {
                /*
                 * The stopped host callback has not copied its syscall or
                 * selector result back to the JIT register file yet. Reject
                 * writes instead of reporting success and silently
                 * overwriting them on resume.
                 */
                return false;
            }
            jit = thread_id == 1
                ? (sharedHandle.cb != nullptr
                    ? DynarmicCallbacks32Jit(sharedHandle.cb)
                    : nullptr)
                : (thread.nativeJit != nullptr
                    ? thread.nativeJit->jit
                    : nullptr);
        } else if (thread_id ==
                Dynarmic_debugger_current_thread()) {
            jit = threadHandle.jit;
        }
        if (jit != nullptr) {
            if (regno == 16) {
                jit->SetCpsr(value);
            } else {
                jit->Regs()[regno] = value;
            }
            return true;
        }
        if (thread.savedValid) {
            if (regno == 16) {
                thread.saved.cpsr = value;
            } else {
                thread.saved.regs[regno] = value;
            }
            return true;
        }
        return false;
    }
    return false;
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    reg_write
 * Signature: (JIJ)I
 */
int Dynarmic_reg_1write(int index, u32 value) {
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    if(jit) {
        jit->Regs()[index] = value;
    } else {
        return 1;
    }
    return 0;
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    reg_read
 * Signature: (JI)J
 */
u32 Dynarmic_reg_1read(int index) {
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    if(jit) {
      return jit->Regs()[index];
    } else {
      abort();
      return -1;
    }
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    reg_read_cpsr
 * Signature: (J)I
 */
int Dynarmic_reg_1read_1cpsr() {
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    if(jit) {
      return jit->Cpsr();
    } else {
      abort();
      return -1;
    }
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    reg_write_cpsr
 * Signature: (JI)I
 */
int Dynarmic_reg_1write_1cpsr(int value) {
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    if(jit) {
      jit->SetCpsr(value);
      return 0;
    } else {
      abort();
      return -1;
    }
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    reg_write_c13_c0_3
 * Signature: (JI)I
 */
int Dynarmic_reg_1write_1c13_1c0_13(int value) {
    DynarmicCallbacks32 *cb = threadHandle.cb;
    if(cb) {
      DynarmicCallbacks32CP15(cb).get()->uro = value;
      return 0;
    } else {
      abort();
      return -1;
    }
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    emu_start
 * Signature: (JJ)I
 */
Dynarmic::HaltReason Dynarmic_emu_1start(u32 pc) {
    Dynarmic::HaltReason reason;
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    if(jit) {
      if (ConsumePendingGuestStop()) {
        return LC32HaltReasonTrap;
      }
      Dynarmic::A32::Jit *cpu = jit;
      if(pc & 1) {
        cpu->SetCpsr(0x00000030); // Thumb user mode
      } else {
        cpu->SetCpsr(0x000001d0); // Arm user mode
      }
      cpu->Regs()[15] = (u32) (pc & ~1);
      for (;;) {
        reason = RunGuestJit(cpu);
        if (ConsumeNativeThreadStateHalt(reason) && !reason) {
          continue;
        }
        if (Dynarmic::Has(
                reason, Dynarmic::HaltReason::CacheInvalidation)) {
          reason = reason &
              ~Dynarmic::HaltReason::CacheInvalidation;
          if (!reason) {
            continue;
          }
        }
        if (Dynarmic::Has(reason, LC32HaltReasonWorkqueue)) {
          const bool transitionPending =
              GuestContextTransitionPending();
          if (transitionPending &&
                  !HandleGuestContextTransition()) {
            reason = LC32HaltReasonTrap;
            break;
          }
          /*
           * HaltExecution is level-triggered. A native guest worker can
           * prepare a workqueue upcall and halt the main JIT while the main
           * thread is inside an SVC callback. ServiceGuestSVC installs that
           * upcall before Run() observes the halt, leaving a stale
           * Workqueue bit behind. It is only an error when a transition is
           * still pending but cannot be applied.
           */
          const Dynarmic::HaltReason remaining =
              reason & ~LC32HaltReasonWorkqueue;
          if (!!remaining) {
            reason = remaining;
            break;
          }
          continue;
        }
        if (!Dynarmic::Has(reason, LC32HaltReasonSVC)) {
          break;
        }
        ServiceGuestSVC();
        if (nativeGuestThreadRetiring) {
          reason = LC32HaltReasonExit;
          break;
        }
      }
    } else {
      return LC32HaltReasonTrap;
    }
  if (!nativeGuestThreadRetiring) {
    UpdateGuestStopSignalForHalt(reason);
  }
  return reason;
}

static void ServiceDeferredGuestSVC() {
    guestDeferredSVC = false;
    ServiceGuestSVC();
}

Dynarmic::HaltReason Dynarmic_emu_1resume() {
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    if (!jit) {
        return LC32HaltReasonTrap;
    }
    if (ConsumePendingGuestStop()) {
        return LC32HaltReasonTrap;
    }

    Dynarmic::HaltReason reason;
    if (guestDeferredSVC) {
        ServiceDeferredGuestSVC();
        if (nativeGuestThreadRetiring) {
            return LC32HaltReasonExit;
        }
        if (!NativeDebuggerMainContextMayRun()) {
            reason = Dynarmic::HaltReason::Step;
            UpdateGuestStopSignalForHalt(reason);
            return reason;
        }
    }
    for (;;) {
        reason = RunGuestJit(jit);
        if (ConsumeNativeThreadStateHalt(reason) && !reason) {
            continue;
        }
        if (Dynarmic::Has(
                reason, Dynarmic::HaltReason::CacheInvalidation)) {
            reason = reason &
                ~Dynarmic::HaltReason::CacheInvalidation;
            if (!reason) {
                continue;
            }
        }
        if (Dynarmic::Has(reason, LC32HaltReasonWorkqueue)) {
            const bool transitionPending =
                GuestContextTransitionPending();
            if (transitionPending &&
                    !HandleGuestContextTransition()) {
                reason = LC32HaltReasonTrap;
                break;
            }
            const Dynarmic::HaltReason remaining =
                reason & ~LC32HaltReasonWorkqueue;
            if (!!remaining) {
                reason = remaining;
                break;
            }
            if (!NativeDebuggerMainContextMayRun()) {
                reason = Dynarmic::HaltReason::Step;
                break;
            }
            continue;
        }
        if (!Dynarmic::Has(reason, LC32HaltReasonSVC)) {
            break;
        }
        const Dynarmic::HaltReason remaining =
            reason & ~LC32HaltReasonSVC;
        if (!!remaining) {
            guestDeferredSVC = true;
            reason = remaining;
            break;
        }
        ServiceDeferredGuestSVC();
        if (nativeGuestThreadRetiring) {
            reason = LC32HaltReasonExit;
            break;
        }
        if (!NativeDebuggerMainContextMayRun()) {
            reason = Dynarmic::HaltReason::Step;
            break;
        }
    }
    if (!nativeGuestThreadRetiring) {
        UpdateGuestStopSignalForHalt(reason);
    }
    return reason;
}

Dynarmic::HaltReason Dynarmic_emu_1step() {
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    if (!jit) {
        return LC32HaltReasonTrap;
    }
    if (ConsumePendingGuestStop()) {
        return LC32HaltReasonTrap;
    }

    Dynarmic::HaltReason reason;
    bool drainInternalWorker = false;
    guestSingleStepping = true;
    if (guestDeferredSVC) {
        ServiceDeferredGuestSVC();
        reason = nativeGuestThreadRetiring
            ? LC32HaltReasonExit
            : Dynarmic::HaltReason::Step;
        guestSingleStepping = false;
        if (!nativeGuestThreadRetiring) {
            UpdateGuestStopSignalForHalt(reason);
        }
        return reason;
    }
    for (;;) {
        reason = drainInternalWorker
            ? RunGuestJit(jit)
            : StepGuestJit(jit);
        if (ConsumeNativeThreadStateHalt(reason) && !reason) {
            continue;
        }
        if (Dynarmic::Has(
                reason, Dynarmic::HaltReason::CacheInvalidation)) {
            reason = reason &
                ~Dynarmic::HaltReason::CacheInvalidation;
            if (!reason) {
                continue;
            }
        }
        if (Dynarmic::Has(reason, LC32HaltReasonWorkqueue)) {
            const bool wasWorkerActive = guestWorkqueueUpcallActive;
            const bool hadGuestThreadTransition =
                GuestThreadTransitionPending();
            const bool transitionPending =
                GuestContextTransitionPending();
            if (transitionPending &&
                    !HandleGuestContextTransition()) {
                reason = LC32HaltReasonTrap;
                break;
            }
            const Dynarmic::HaltReason remaining =
                reason & ~(LC32HaltReasonWorkqueue |
                           Dynarmic::HaltReason::Step);
            if (!!remaining) {
                reason = remaining;
                break;
            }
            if (!transitionPending) {
                continue;
            }
            if (hadGuestThreadTransition &&
                    !wasWorkerActive &&
                    !guestWorkqueueUpcallActive) {
                reason = Dynarmic::HaltReason::Step;
                break;
            }
            if (!wasWorkerActive && guestWorkqueueUpcallActive) {
                /*
                 * Finish an internal worker spawned by the instruction being
                 * stepped. If the debugger was already stopped in a worker,
                 * drainInternalWorker remains false and Step() retains normal
                 * single-instruction semantics for that worker.
                 */
                drainInternalWorker = true;
                continue;
            }
            if (wasWorkerActive && !guestWorkqueueUpcallActive) {
                reason = Dynarmic::HaltReason::Step;
                break;
            }
            continue;
        }
        if (!Dynarmic::Has(reason, LC32HaltReasonSVC)) {
            break;
        }
        const Dynarmic::HaltReason remaining =
            reason & ~LC32HaltReasonSVC;
        if (!!remaining) {
            guestDeferredSVC = true;
            reason = remaining;
            break;
        }
        ServiceDeferredGuestSVC();
        if (nativeGuestThreadRetiring) {
            reason = LC32HaltReasonExit;
            break;
        }
        if (!NativeDebuggerMainContextMayRun()) {
            reason = Dynarmic::HaltReason::Step;
            break;
        }
    }
    guestSingleStepping = false;
    if (!nativeGuestThreadRetiring) {
        UpdateGuestStopSignalForHalt(reason);
    }
    return reason;
}

static bool NativeDebuggerBeginExecution(
        NativeDebuggerResumeMode mode,
        gdb_thread_id_t stepThread,
        bool mainExecuting) {
    const auto requestedStopOwnerLocked =
        [mode, stepThread] {
            const gdb_thread_id_t candidate =
                mode ==
                    NativeDebuggerResumeMode::ContinueAll
                ? 1
                : stepThread;
            return NativeDebuggerNormalizeStopOwnerLocked(
                candidate != 0 ? candidate : 1);
        };
    {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        assert(nativeDebugger.executingWorkers == 0);
        assert(nativeDebugger.state ==
            NativeDebuggerRunState::Stopped);
        /*
         * Publish the incoming selection before clearing old JIT halts. The
         * socket reader can queue ^C during this handoff and must attribute
         * the resulting stop to this request, not the previous vCont mode.
         */
        nativeDebugger.resumeMode = mode;
        nativeDebugger.stepThread = stepThread;
        if (nativeDebugger.pendingInterrupt) {
            nativeDebugger.stopOwner =
                requestedStopOwnerLocked();
            nativeDebugger.stopReason =
                LC32HaltReasonInterrupt;
            nativeDebugger.stopSignal = SIGINT;
            nativeDebugger.pendingInterrupt = false;
            nativeDebugger.resumeStarting = false;
            nativeDebugger.mainExecuting = false;
            CommitGuestStopSignal(SIGINT, false);
            return false;
        }
        nativeDebugger.resumeStarting = true;
    }

    /*
     * HaltExecution is level-triggered. A JIT which was already parked when a
     * peer published the previous stop never entered Run() to consume the
     * debugger-pause bit. Keep the coordinator in Stopped/resumeStarting while
     * clearing every acknowledged JIT. A concurrent ^C is queued under the
     * same mutex and cannot be erased by the Stopped-to-Running handoff.
     */
    ClearAllGuestJitHalts(
        LC32HaltReasonDebuggerPause);
    {
        std::lock_guard<std::mutex> lock(nativeDebugger.mutex);
        if (nativeDebugger.pendingInterrupt) {
            nativeDebugger.stopOwner =
                requestedStopOwnerLocked();
            nativeDebugger.stopReason =
                LC32HaltReasonInterrupt;
            nativeDebugger.stopSignal = SIGINT;
            nativeDebugger.pendingInterrupt = false;
            nativeDebugger.resumeStarting = false;
            nativeDebugger.mainExecuting = false;
            CommitGuestStopSignal(SIGINT, false);
            return false;
        }
        nativeDebugger.state =
            NativeDebuggerRunState::Running;
        nativeDebugger.mainExecuting = mainExecuting;
        nativeDebugger.resumeStarting = false;
        ++nativeDebugger.generation;
        debuggerInterruptRequested.store(
            false, std::memory_order_release);
        debuggerAllStopRequested.store(
            false, std::memory_order_release);
    }
    nativeDebugger.condition.notify_all();
    return true;
}

static Dynarmic::HaltReason NativeDebuggerCompleteStop() {
    std::unique_lock<std::mutex> lock(nativeDebugger.mutex);
    nativeDebugger.mainExecuting = false;
    const auto allThreadsStopped = [] {
        return !NativeDebuggerActive() ||
            (nativeDebugger.state !=
                 NativeDebuggerRunState::Running &&
             nativeDebugger.executingWorkers == 0);
    };
    auto nextHostInterrupt =
        std::chrono::steady_clock::now() +
        std::chrono::milliseconds(20);
    while (!allThreadsStopped()) {
        if (nativeDebugger.condition.wait_until(
                lock, nextHostInterrupt) !=
                std::cv_status::timeout) {
            continue;
        }
        /*
         * A waiter can be descheduled between publishing InCall and entering
         * the kernel, longer than the bounded first interrupt burst. Keep
         * retrying until every executing worker acknowledges this all-stop.
         */
        const bool retryHostInterrupt =
            (nativeDebugger.state ==
                 NativeDebuggerRunState::Stopping ||
             nativeDebugger.state ==
                 NativeDebuggerRunState::ShuttingDown) &&
            nativeDebugger.executingWorkers != 0;
        lock.unlock();
        if (retryHostInterrupt) {
            InterruptDebuggerMachCalls();
        }
        lock.lock();
        nextHostInterrupt =
            std::chrono::steady_clock::now() +
            std::chrono::milliseconds(20);
    }
    if (!NativeDebuggerActive()) {
        return LC32HaltReasonTrap;
    }
    if (nativeDebugger.state ==
            NativeDebuggerRunState::Stopping) {
        nativeDebugger.state =
            NativeDebuggerRunState::Stopped;
    }
    guestStopSignal.store(
        nativeDebugger.stopSignal,
        std::memory_order_relaxed);
    const Dynarmic::HaltReason reason =
        nativeDebugger.stopReason;
    lock.unlock();
    nativeDebugger.condition.notify_all();
    return reason;
}

bool Dynarmic_debugger_begin_main_callback_stop(
        Dynarmic::HaltReason reason) {
    /*
     * The normal protocol owner is synchronously below Dynarmic_emu_resume()
     * on this same host thread.  Completing the stop here is safe only for
     * the shared main JIT.  A native worker doing this would wait for its own
     * executingWorkers acknowledgement and deadlock, as well as compete for
     * the single RSP packet queue.
     */
    if (!NativeDebuggerActive() ||
            threadHandle.jit == nullptr ||
            sharedHandle.cb == nullptr ||
            threadHandle.jit != DynarmicCallbacks32Jit(sharedHandle.cb)) {
        return false;
    }

    NativeDebuggerRunState state;
    {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        state = nativeDebugger.state;
    }
    if (state != NativeDebuggerRunState::Running &&
            state != NativeDebuggerRunState::Stopping) {
        return false;
    }
    if (state == NativeDebuggerRunState::Running) {
        (void)NativeDebuggerRequestStop(
            ActiveMainDebuggerThread(), reason);
    }
    (void)NativeDebuggerCompleteStop();

    {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        if (!NativeDebuggerActive() ||
                nativeDebugger.state !=
                    NativeDebuggerRunState::Stopped) {
            return false;
        }
    }
    ++nativeDebuggerMainCallbackStopDepth;
    return true;
}

void Dynarmic_debugger_end_main_callback_stop() {
    if (nativeDebuggerMainCallbackStopDepth != 0) {
        --nativeDebuggerMainCallbackStopDepth;
    }
}

void Dynarmic_debugger_request_main_callback_step_out() {
    if (!NativeDebuggerActive() ||
            threadHandle.jit == nullptr ||
            sharedHandle.cb == nullptr ||
            threadHandle.jit != DynarmicCallbacks32Jit(sharedHandle.cb)) {
        return;
    }
    (void)NativeDebuggerRequestStop(
        ActiveMainDebuggerThread(),
        Dynarmic::HaltReason::Step,
        SIGTRAP, false);
}

void Dynarmic_debugger_request_main_session_unwind() {
    if (threadHandle.jit == nullptr ||
            sharedHandle.cb == nullptr ||
            threadHandle.jit != DynarmicCallbacks32Jit(sharedHandle.cb)) {
        return;
    }
    debuggerSessionUnwindRequested.store(
        true, std::memory_order_release);
    /* Planted only after the stopped reverse callback has run through its
     * normal return and the outer register context has been restored. */
    threadHandle.jit->HaltExecution(
        LC32HaltReasonDebuggerPause);
    if (void (*notifier)(void) =
            debuggerStopRunLoopNotifier.load(
                std::memory_order_acquire)) {
        notifier();
    }
}

static Dynarmic::HaltReason NativeDebuggerReemitPendingStop() {
    std::lock_guard<std::mutex> lock(nativeDebugger.mutex);
    nativeDebugger.state =
        NativeDebuggerRunState::Stopped;
    nativeDebugger.stopSignal =
        guestStopSignal.load(std::memory_order_relaxed);
    return nativeDebugger.stopReason;
}

Dynarmic::HaltReason Dynarmic_debugger_continue(
        gdb_thread_id_t thread_id) {
    if (!NativeDebuggerActive()) {
        if (ConsumePendingGuestStop()) {
            return LC32HaltReasonTrap;
        }
        if (thread_id == GDB_THREAD_ID_ANY) {
            thread_id =
                Dynarmic_debugger_current_thread();
        }
        if (thread_id != GDB_THREAD_ID_ALL &&
                !Dynarmic_debugger_thread_resumable(
                    thread_id)) {
            CommitGuestStopSignal(SIGTRAP, false);
            return LC32HaltReasonTrap;
        }
        if (thread_id != GDB_THREAD_ID_ALL &&
                !SelectCooperativeDebuggerThread(
                    thread_id)) {
            CommitGuestStopSignal(SIGTRAP, false);
            return LC32HaltReasonTrap;
        }
        const gdb_thread_id_t previousThread =
            cooperativeDebuggerResumeThread;
        cooperativeDebuggerResumeThread = thread_id;
        const Dynarmic::HaltReason reason =
            Dynarmic_emu_1resume();
        cooperativeDebuggerResumeThread =
            previousThread;
        return reason;
    }
    if (ConsumePendingGuestStop()) {
        return NativeDebuggerReemitPendingStop();
    }

    if (thread_id == GDB_THREAD_ID_ANY) {
        thread_id =
            Dynarmic_debugger_current_thread();
    }
    const bool continueAll =
        thread_id == GDB_THREAD_ID_ALL;
    if (!continueAll &&
            !Dynarmic_debugger_thread_resumable(
                thread_id)) {
        CommitGuestStopSignal(SIGTRAP, false);
        return LC32HaltReasonTrap;
    }
    const bool runMain = continueAll ||
        thread_id == 1 || thread_id == 2;
    if (!NativeDebuggerBeginExecution(
        continueAll
            ? NativeDebuggerResumeMode::ContinueAll
            : NativeDebuggerResumeMode::ContinueOne,
        continueAll ? 0 : thread_id,
        runMain)) {
        return NativeDebuggerCompleteStop();
    }
    if (runMain) {
        const gdb_thread_id_t mainOwner =
            ActiveMainDebuggerThread();
        if (NativeDebuggerRepublishPendingStop(
                mainOwner)) {
            return NativeDebuggerCompleteStop();
        }
        const Dynarmic::HaltReason reason =
            Dynarmic_emu_1resume();
        if (nativeDebuggerMainCallbackStopDepth != 0 &&
                Dynarmic::Has(
                    reason,
                    LC32HaltReasonRetFromGuest)) {
            /* The preserved host caller, not the all-stop coordinator, owns
             * this private callback boundary.  Keep the coordinator Running
             * and let the nested protocol frame return without a fake stop. */
            return reason;
        }
        const Dynarmic::HaltReason visibleReason =
            NativeDebuggerVisibleReason(reason);
        if (!!visibleReason) {
            const gdb_thread_id_t owner =
                ActiveMainDebuggerThread();
            (void)NativeDebuggerRequestStop(
                owner, visibleReason);
        } else {
            bool stillRunning;
            {
                std::lock_guard<std::mutex> lock(
                    nativeDebugger.mutex);
                stillRunning =
                    nativeDebugger.state ==
                        NativeDebuggerRunState::Running;
            }
            if (stillRunning) {
                (void)NativeDebuggerRequestStop(
                    ActiveMainDebuggerThread(),
                    LC32HaltReasonTrap,
                    SIGTRAP, false);
            }
        }
    }
    return NativeDebuggerCompleteStop();
}

Dynarmic::HaltReason Dynarmic_debugger_step(
        gdb_thread_id_t thread_id,
        bool continue_other_threads) {
    if (!NativeDebuggerActive()) {
        if (ConsumePendingGuestStop()) {
            return LC32HaltReasonTrap;
        }
        if (thread_id == GDB_THREAD_ID_ANY ||
                thread_id == GDB_THREAD_ID_ALL) {
            thread_id =
                Dynarmic_debugger_current_thread();
        }
        if (!Dynarmic_debugger_thread_resumable(
                thread_id)) {
            CommitGuestStopSignal(SIGTRAP, false);
            return LC32HaltReasonTrap;
        }
        if (!SelectCooperativeDebuggerThread(
                thread_id)) {
            CommitGuestStopSignal(SIGTRAP, false);
            return LC32HaltReasonTrap;
        }
        const gdb_thread_id_t previousThread =
            cooperativeDebuggerResumeThread;
        cooperativeDebuggerResumeThread = thread_id;
        const Dynarmic::HaltReason reason =
            Dynarmic_emu_1step();
        cooperativeDebuggerResumeThread =
            previousThread;
        return reason;
    }
    if (ConsumePendingGuestStop()) {
        return NativeDebuggerReemitPendingStop();
    }
    if (thread_id == GDB_THREAD_ID_ANY ||
            thread_id == GDB_THREAD_ID_ALL) {
        thread_id =
            Dynarmic_debugger_current_thread();
    }
    if (!Dynarmic_debugger_thread_resumable(
            thread_id)) {
        CommitGuestStopSignal(SIGTRAP, false);
        return LC32HaltReasonTrap;
    }

    const bool stepMain =
        thread_id == 1 || thread_id == 2;
    const bool runMain =
        stepMain || continue_other_threads;
    if (!NativeDebuggerBeginExecution(
        continue_other_threads
            ? NativeDebuggerResumeMode::
                StepOneContinueOthers
            : NativeDebuggerResumeMode::StepOne,
        thread_id, runMain)) {
        return NativeDebuggerCompleteStop();
    }
    uint64_t commandGeneration;
    {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        commandGeneration = nativeDebugger.generation;
    }
    if (runMain) {
        const gdb_thread_id_t mainOwner =
            ActiveMainDebuggerThread();
        if (NativeDebuggerRepublishPendingStop(
                mainOwner)) {
            return NativeDebuggerCompleteStop();
        }
        Dynarmic::HaltReason reason =
            stepMain
            ? Dynarmic_emu_1step()
            : Dynarmic_emu_1resume();
        if (nativeDebuggerMainCallbackStopDepth != 0 &&
                Dynarmic::Has(
                    reason,
                    LC32HaltReasonRetFromGuest)) {
            return reason;
        }

        bool enforceOriginalStep = stepMain;
        if (stepMain) {
            const gdb_thread_id_t mainOwner =
                ActiveMainDebuggerThread();
            bool commandSuperseded;
            bool latestCommandRunsMain;
            {
                std::lock_guard<std::mutex> lock(
                    nativeDebugger.mutex);
                commandSuperseded =
                    nativeDebugger.generation !=
                        commandGeneration;
                latestCommandRunsMain =
                    nativeDebugger.state ==
                        NativeDebuggerRunState::Running &&
                    NativeDebuggerRunsThreadLocked(
                        mainOwner);
            }
            if (commandSuperseded) {
                /* A nested callback stop serviced a newer c/s command while
                 * this old step frame was inside its host call.  Never
                 * publish the old step's fallback stop after a nested c. */
                enforceOriginalStep = false;
                const Dynarmic::HaltReason visible =
                    NativeDebuggerVisibleReason(reason);
                if (latestCommandRunsMain &&
                        (!visible || visible ==
                            Dynarmic::HaltReason::Step)) {
                    reason = Dynarmic_emu_1resume();
                    if (nativeDebuggerMainCallbackStopDepth != 0 &&
                            Dynarmic::Has(
                                reason,
                                LC32HaltReasonRetFromGuest)) {
                        return reason;
                    }
                }
            }
        }
        const Dynarmic::HaltReason visibleReason =
            NativeDebuggerVisibleReason(reason);
        if (!!visibleReason || enforceOriginalStep) {
            const gdb_thread_id_t owner =
                ActiveMainDebuggerThread();
            (void)NativeDebuggerRequestStop(
                owner,
                !!visibleReason
                    ? visibleReason
                    : Dynarmic::HaltReason::Step);
        } else {
            bool stillRunning;
            {
                std::lock_guard<std::mutex> lock(
                    nativeDebugger.mutex);
                stillRunning =
                    nativeDebugger.state ==
                        NativeDebuggerRunState::Running;
            }
            if (stillRunning) {
                (void)NativeDebuggerRequestStop(
                    ActiveMainDebuggerThread(),
                    LC32HaltReasonTrap,
                    SIGTRAP, false);
            }
        }
    }
    return NativeDebuggerCompleteStop();
}

void Dynarmic_emu_1set_1debugger_1enabled(bool enabled) {
    /* A fresh enable or the outer owner's final disable consumes any
     * callback-terminal request left for the UIKit run-loop shim. */
    debuggerSessionUnwindRequested.store(
        false, std::memory_order_release);
    if (enabled && NativeGuestThreadsEnabled()) {
        {
            std::lock_guard<std::mutex> lock(
                nativeDebugger.mutex);
            nativeDebugger.state =
                NativeDebuggerRunState::Stopped;
            nativeDebugger.resumeMode =
                NativeDebuggerResumeMode::ContinueAll;
            nativeDebugger.stopOwner = 1;
            nativeDebugger.stepThread = 1;
            nativeDebugger.stopReason =
                LC32HaltReasonTrap;
            nativeDebugger.stopSignal =
                guestStopSignal.load(std::memory_order_relaxed);
            nativeDebugger.executingWorkers = 0;
            nativeDebugger.mainExecuting = false;
            nativeDebugger.resumeStarting = false;
            nativeDebugger.pendingInterrupt = false;
            debuggerAllStopRequested.store(
                true, std::memory_order_release);
        }
        guestDebuggerEnabled.store(
            true, std::memory_order_release);
        nativeDebugger.condition.notify_all();
        NotifyGuestCallbackExecutorWaiter();
        return;
    }
    if (enabled) {
        guestDebuggerEnabled.store(
            true, std::memory_order_release);
        return;
    }

    if (NativeGuestThreadsEnabled()) {
        /*
         * Debugger all-stop is level-triggered on every JIT.  A worker which
         * parked without re-entering Run() still owns the pause bit, so clear
         * it while guestDebuggerEnabled keeps all workers behind the stopped
         * coordinator.  Only then publish Disabled and release them; raw
         * post-detach resume must not immediately rediscover the old stop.
         */
        ClearAllGuestJitHalts(
            LC32HaltReasonDebuggerPause);
    }
    {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        if (nativeDebugger.state !=
                NativeDebuggerRunState::ShuttingDown) {
            nativeDebugger.state =
                NativeDebuggerRunState::Disabled;
        }
        nativeDebugger.mainExecuting = false;
        debuggerInterruptRequested.store(
            false, std::memory_order_release);
        debuggerAllStopRequested.store(
            false, std::memory_order_release);
        /* Final release: worker predicates may run after this store. */
        guestDebuggerEnabled.store(
            false, std::memory_order_release);
    }
    nativeDebugger.condition.notify_all();
    NotifyNativeDebuggerWaiters();
}

int Dynarmic_emu_1get_1stop_1signal() {
    if (NativeDebuggerActive()) {
        std::lock_guard<std::mutex> lock(
            nativeDebugger.mutex);
        return nativeDebugger.stopSignal;
    }
    return guestStopSignal.load(std::memory_order_relaxed);
}

int Dynarmic_emu_1get_1exit_1code() {
    return guestProcessExitCode.load(
        std::memory_order_acquire);
}

void Dynarmic_emu_1set_1resume_1signal(int signal) {
    const int pending =
        pendingGuestFatalSignal.load(std::memory_order_relaxed);
    if (pending > 0 &&
            (signal == 0 || signal == pending)) {
        /*
         * A synchronous guest fault cannot be suppressed by lowercase c/s:
         * Dynarmic memory callbacks do not carry an exact instruction PC, so
         * executing here could step from a stale linked-block boundary. Keep
         * reporting the unresolved fault until the debugger changes register
         * or memory state.
         */
        reemitPendingGuestStop.store(true, std::memory_order_relaxed);
        return;
    }

    // A different signal cannot be faithfully delivered by this userland JIT.
    pendingGuestFatalSignal.store(0, std::memory_order_relaxed);
    reemitPendingGuestStop.store(false, std::memory_order_relaxed);
}

void Dynarmic_debugger_resolve_pending_stop() {
    pendingGuestFatalSignal.store(
        0, std::memory_order_relaxed);
    reemitPendingGuestStop.store(
        false, std::memory_order_relaxed);
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    emu_stop
 * Signature: (J)I
 */
int Dynarmic_emu_1stop() {
    if (NativeDebuggerActive()) {
        gdb_thread_id_t owner =
            ActiveMainDebuggerThread();
        {
            std::lock_guard<std::mutex> lock(
                nativeDebugger.mutex);
            if (nativeDebugger.resumeMode !=
                    NativeDebuggerResumeMode::ContinueAll &&
                    nativeDebugger.stepThread != 0) {
                owner = nativeDebugger.stepThread;
            }
        }
        /*
         * The selected worker can retire inside bsdthread_terminate before
         * its host loop publishes the replacement stop. Never expose a stop
         * owner that qfThreadInfo has already dropped.
         */
        if (!Dynarmic_debugger_thread_alive(owner) ||
                !Dynarmic_debugger_thread_resumable(
                    owner)) {
            owner = ActiveMainDebuggerThread();
        }
        if (!Dynarmic_debugger_thread_alive(owner)) {
            owner = 1;
        }
        debuggerInterruptRequested.store(
            true, std::memory_order_release);
        (void)NativeDebuggerRequestStop(
            owner, LC32HaltReasonInterrupt,
            SIGINT, false, true);
        return 0;
    }

    // on_interrupt is invoked by mini-gdbstub's socket-reader thread. That
    // thread has no thread-local dynarmic_thread, so use the JIT published by
    // the shared callbacks instead of threadHandle.jit.
    DynarmicCallbacks32 *callbacks = sharedHandle.cb;
    Dynarmic::A32::Jit *jit =
        DynarmicCallbacks32Jit(callbacks);
    if(jit) {
      debuggerInterruptRequested.store(true, std::memory_order_release);
      jit->HaltExecution(LC32HaltReasonInterrupt);
      InterruptDebuggerMachCalls();
    } else {
      return 1;
    }
  return 0;
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    context_alloc
 * Signature: (J)J
 */
void* Dynarmic_context_1alloc() {
    void *ctx = malloc(sizeof(struct context32));
    return ctx;
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    context_restore
 * Signature: (JJ)V
 */
void Dynarmic_context_1restore(t_context32 ctx) {
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    jit->Regs() = ctx->regs;
    jit->ExtRegs() = ctx->extRegs;
    jit->SetCpsr(ctx->cpsr);
    jit->SetFpscr(ctx->fpscr);

    DynarmicCallbacks32 *cb = threadHandle.cb;
    DynarmicCallbacks32CP15(cb).get()->uro = ctx->uro;
    NativeGuestCallbackRegisterAccessEnd();
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    context_save
 * Signature: (JJ)V
 */
void Dynarmic_context_1save(t_context32 ctx) {
    NativeGuestCallbackRegisterAccessBegin();
    Dynarmic::A32::Jit *jit = threadHandle.jit;
    ctx->regs = jit->Regs();
    ctx->extRegs = jit->ExtRegs();
    ctx->cpsr = jit->Cpsr();
    ctx->fpscr = jit->Fpscr();

    DynarmicCallbacks32 *cb = threadHandle.cb;
    ctx->uro = DynarmicCallbacks32CP15(cb).get()->uro;
}

/*
 * Class:     com_github_unidbg_arm_backend_dynarmic_Dynarmic
 * Method:    free
 * Signature: (J)V
 */
void Dynarmic_free(void *ctx) {
  free(ctx);
}

#ifdef __cplusplus
}
#endif
