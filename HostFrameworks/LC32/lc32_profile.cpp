#include "lc32_profile.h"
#include <malloc/malloc.h>
#include <mach/mach.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <algorithm>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <atomic>
#include <string>
#include <unordered_map>
#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

int LC32ProfileActive = 0;
extern "C" uint64_t LC32GuestMappedBytesForProfile(void);
extern "C" void LC32_OpenGLES_ProfileReport(double seconds);
extern "C" void LC32RetiredGuestMemoryForProfile(uint64_t *count, uint64_t *bytes);
extern "C" void LC32DescribeGuestPageForProfile(uint32_t address, char *buffer, size_t size);
std::atomic<uint64_t> slowMisaligned{0}, slowCrossPage{0}, slowTotal{0}, slowFromJIT{0}, exclusiveWrites{0};
std::mutex slowCallerMutex;
std::unordered_map<const void *, uint64_t> slowCallers;

namespace {

constexpr int kFirstNumber = -200;
constexpr int kNumberCount = 1300; // -200 ... 1099 (mach traps, BSD, LC32 bridge)

struct ThreadStats {
    pthread_t thread;
    uint64_t threadId;
    bool mainThread;
    std::atomic<uint64_t> runTicks{0}, runs{0};
    std::atomic<uint64_t> svcInRunTicks{0}, svcOutRunTicks{0};
    std::atomic<uint64_t> waitInRunTicks{0}, waitOutRunTicks{0};
    std::atomic<uint64_t> glTicks{0}, glCalls{0};
    std::atomic<uint64_t> paceTicks{0}, presentTicks{0};
    std::atomic<uint64_t> compileTicks{0}, slowMemory{0};
    std::atomic<uint32_t> fpscr{0xffffffffu}; // last seen, none yet
    std::atomic<uint64_t> numberTicks[kNumberCount];
    std::atomic<uint64_t> numberCalls[kNumberCount];
    // Values at the previous report, so each report shows one window.
    uint64_t last[13] = {};
    struct HostCallStats { uint64_t ticks = 0, calls = 0; bool selector = false; };
    std::mutex hostCallMutex;
    std::unordered_map<const void *, HostCallStats> hostCalls; // reset each report
    uint64_t lastNumberTicks[kNumberCount] = {};
    uint64_t lastNumberCalls[kNumberCount] = {};
    ThreadStats() {
        for(int i = 0; i < kNumberCount; i++) {
            numberTicks[i].store(0, std::memory_order_relaxed);
            numberCalls[i].store(0, std::memory_order_relaxed);
        }
    }
};

// Calls that block until something happens: time in them is waiting, not work.
bool IsBlockingCall(int number) {
    switch(number) {
        case 334: // __semwait_signal (sleep, usleep, nanosleep)
        case 305: // psynch_cvwait
        case 301: // psynch_mutexwait
        case 309: case 310: // psynch_rw_rdlock / wrlock
        case 93: case 407: // select, select_nocancel
        case 230: case 417: // poll, poll_nocancel
        case 363: case 369: case 374: // kevent, kevent64, kevent_qos
        case 368: // workq_kernreturn
        case -31: case -32: // mach_msg_trap, mach_msg_overwrite_trap
        case -36: case -37: case -38: case -39: // semaphore waits
        case -89: // mach_wait_until
        case 1017: // LC32GuestCallbackExecutorWait
            return true;
        default:
            return false;
    }
}

std::mutex registryMutex;
std::mutex slowPageMutex;              // slow-access page histogram
std::unordered_map<uint32_t, uint64_t> slowPages; // page | 1 for writes
std::vector<ThreadStats *> registry;
std::atomic<uint64_t> frames{0};
mach_timebase_info_data_t timebase;

ThreadStats *Current() {
    static thread_local ThreadStats *stats = nullptr;
    if(stats == nullptr) {
        stats = new ThreadStats();
        stats->thread = pthread_self();
        pthread_threadid_np(nullptr, &stats->threadId);
        stats->mainThread = pthread_main_np() != 0;
        std::lock_guard<std::mutex> lock(registryMutex);
        registry.push_back(stats);
    }
    return stats;
}

double Ms(uint64_t ticks) {
    return (double)ticks * timebase.numer / timebase.denom / 1e6;
}

void Add(std::atomic<uint64_t> &counter, uint64_t value) {
    counter.fetch_add(value, std::memory_order_relaxed);
}

void Report(double seconds) {
    const uint64_t frameCount = frames.exchange(0, std::memory_order_relaxed);
    fprintf(stderr, "LC32PROF ---- %.1f s, %llu presents (%.1f fps); "
        "times are ms per second of wall time\n", seconds,
        (unsigned long long)frameCount, frameCount / seconds);
    {
        // Memory: iOS kills the app at its footprint limit (4 GB on an
        // iPhone 14 Pro). Footprint minus malloc minus guest pages is mostly
        // GPU/driver memory and JIT code.
        task_vm_info_data_t vm = {};
        mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
        const double footprint =
            task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm,
                &vmCount) == KERN_SUCCESS ? vm.phys_footprint / 1048576.0 : 0;
        malloc_statistics_t mallocStats = {};
        malloc_zone_statistics(nullptr, &mallocStats);
        const bool ledgers = vmCount >= TASK_VM_INFO_REV5_COUNT;
        const double MB = 1048576.0;
        fprintf(stderr, "LC32PROF   memory: footprint %.0f MB, malloc in use "
            "%.0f MB, guest pages %.0f MB | graphics %.0f MB, media %.0f MB, "
            "internal %.0f MB, compressed %.0f MB, device %.0f MB, purgeable %.0f MB\n",
            footprint, mallocStats.size_in_use / MB,
            LC32GuestMappedBytesForProfile() / MB,
            ledgers ? (vm.ledger_tag_graphics_footprint +
                vm.ledger_tag_graphics_footprint_compressed) / MB : -1.0,
            ledgers ? (vm.ledger_tag_media_footprint +
                vm.ledger_tag_media_footprint_compressed) / MB : -1.0,
            vm.internal / MB, vm.compressed / MB,
            vm.device / MB, vm.ledger_purgeable_nonvolatile / MB);
        uint64_t retiredCount = 0, retiredBytes = 0;
        LC32RetiredGuestMemoryForProfile(&retiredCount, &retiredBytes);
        fprintf(stderr, "LC32PROF   unmapped guest memory awaiting release: "
            "%llu mappings, %.0f MB\n", (unsigned long long)retiredCount,
            retiredBytes / MB);
        LC32_OpenGLES_ProfileReport(seconds);
    }
    std::lock_guard<std::mutex> lock(registryMutex);
    for(ThreadStats *t : registry) {
        uint64_t now[13] = {
            t->runTicks.load(), t->runs.load(), t->svcInRunTicks.load(),
            t->svcOutRunTicks.load(), t->glTicks.load(), t->glCalls.load(),
            t->paceTicks.load(), t->presentTicks.load(),
            t->compileTicks.load(), t->slowMemory.load(),
            t->waitInRunTicks.load(), t->waitOutRunTicks.load(), 0};
        uint64_t d[13];
        for(int i = 0; i < 13; i++) { d[i] = now[i] - t->last[i]; t->last[i] = now[i]; }
        auto rate = [&](int i) { return Ms(d[i]) / seconds; };
        // Present pacing sleeps to hold 60 fps: count it as waiting.
        const double waiting = rate(10) + rate(11) + rate(6);
        const double guest = rate(0) - rate(2) - rate(10) - rate(8);
        const double busy = guest + rate(8) + rate(2) + rate(3) - rate(6);
        // Skip threads that did almost no work in this window.
        if(busy < 20.0) {
            for(int i = 0; i < kNumberCount; i++) {
                t->lastNumberTicks[i] = t->numberTicks[i].load();
                t->lastNumberCalls[i] = t->numberCalls[i].load();
            }
            continue;
        }
        char name[64] = {};
        pthread_getname_np(t->thread, name, sizeof(name));
        fprintf(stderr, "LC32PROF thread %llu%s%s%s: busy %.0f, waiting %.0f | "
            "guest code %.0f, compile %.0f, syscalls %.0f, host calls %.0f "
            "(GL %.0f in %.0f calls/s = %.0f per present; present %.0f, "
            "pacing %.0f) | run entries %.0f/s, slow memory %.0f/s, fpscr %08x\n",
            (unsigned long long)t->threadId, t->mainThread ? " main" : "",
            name[0] ? " " : "", name, busy, waiting,
            guest, rate(8), rate(2), rate(3), rate(4), d[5] / seconds,
            frameCount ? (double)d[5] / frameCount : 0.0,
            rate(7), rate(6), d[1] / seconds, d[9] / seconds,
            t->fpscr.load(std::memory_order_relaxed) & 0x07c00000u);
        struct Entry { int number; uint64_t ticks, calls; };
        std::vector<Entry> entries;
        for(int i = 0; i < kNumberCount; i++) {
            const uint64_t ticks = t->numberTicks[i].load();
            const uint64_t calls = t->numberCalls[i].load();
            const uint64_t dt = ticks - t->lastNumberTicks[i];
            const uint64_t dc = calls - t->lastNumberCalls[i];
            t->lastNumberTicks[i] = ticks;
            t->lastNumberCalls[i] = calls;
            if(dc) entries.push_back({i + kFirstNumber, dt, dc});
        }
        std::sort(entries.begin(), entries.end(),
            [](const Entry &a, const Entry &b) { return a.ticks > b.ticks; });
        {
            struct Call { const void *key; ThreadStats::HostCallStats stats; };
            std::vector<Call> calls;
            {
                std::lock_guard<std::mutex> callLock(t->hostCallMutex);
                for(auto &entry : t->hostCalls) calls.push_back({entry.first, entry.second});
                t->hostCalls.clear();
            }
            std::sort(calls.begin(), calls.end(), [](const Call &a, const Call &b) {
                return a.stats.ticks > b.stats.ticks;
            });
            std::string text = "LC32PROF   top host calls:";
            for(size_t i = 0; i < calls.size() && i < 6; i++) {
                std::string label;
                if(calls[i].stats.selector) {
                    label = std::string("-") + sel_getName((SEL)calls[i].key);
                } else {
                    Dl_info info = {};
                    if(dladdr(calls[i].key, &info) && info.dli_sname) label = info.dli_sname;
                    else { char hex[32]; snprintf(hex, sizeof(hex), "%p", calls[i].key); label = hex; }
                }
                char item[256];
                snprintf(item, sizeof(item), " %s %.0fms/%.0f", label.c_str(),
                    Ms(calls[i].stats.ticks) / seconds, calls[i].stats.calls / seconds);
                text += item;
            }
            if(!calls.empty()) fprintf(stderr, "%s\n", text.c_str());
        }
        char line[512];
        int used = snprintf(line, sizeof(line), "LC32PROF   top syscalls:");
        for(size_t i = 0; i < entries.size() && i < 6; i++) {
            used += snprintf(line + used, sizeof(line) - used,
                " #%d %.0fms/%.0f", entries[i].number,
                Ms(entries[i].ticks) / seconds, entries[i].calls / seconds);
            if(used >= (int)sizeof(line)) break;
        }
        fprintf(stderr, "%s\n", line);
    }
}

} // namespace

extern "C" void LC32ProfileInitialize(void) {
    const char *value = getenv("LC32_PROFILE");
    if(value == nullptr || value[0] == '\0' || value[0] == '0') return;
    mach_timebase_info(&timebase);
    LC32ProfileActive = 1;
    fprintf(stderr, "LC32: profiling enabled (LC32_PROFILE)\n");
    std::thread([] {
        pthread_setname_np("LC32Profile");
        uint64_t last = mach_absolute_time();
        for(;;) {
            sleep(5);
            const uint64_t now = mach_absolute_time();
            Report(Ms(now - last) / 1000.0);
            std::vector<std::pair<uint32_t, uint64_t>> pages;
            {
                std::lock_guard<std::mutex> lock(slowPageMutex);
                pages.assign(slowPages.begin(), slowPages.end());
                slowPages.clear();
            }
            std::sort(pages.begin(), pages.end(), [](auto &a, auto &b) { return a.second > b.second; });
            const uint64_t total = slowTotal.exchange(0);
            fprintf(stderr, "LC32PROF   slow memory: %.0f/s (from JIT code %.0f/s), misaligned %.0f/s, "
                "crossing a page %.0f/s; exclusive stores %.0f/s; top pages (accesses/s):\n", total / 5.0,
                slowFromJIT.exchange(0) / 5.0,
                slowMisaligned.exchange(0) / 5.0, slowCrossPage.exchange(0) / 5.0,
                exclusiveWrites.exchange(0) / 5.0);
            {
                std::vector<std::pair<const void *, uint64_t>> callers;
                {
                    std::lock_guard<std::mutex> lock(slowCallerMutex);
                    callers.assign(slowCallers.begin(), slowCallers.end());
                    slowCallers.clear();
                }
                std::sort(callers.begin(), callers.end(), [](auto &a, auto &b) { return a.second > b.second; });
                for(size_t i = 0; i < callers.size() && i < 6; i++) {
                    Dl_info info = {};
                    const char *name = dladdr(callers[i].first, &info) && info.dli_sname ? info.dli_sname : "?";
                    fprintf(stderr, "LC32PROF     host caller %s+0x%lx %.0f/s\n", name,
                        info.dli_saddr ? (long)((const char *)callers[i].first - (const char *)info.dli_saddr) : 0L,
                        callers[i].second / 5.0);
                }
            }
            for(size_t i = 0; i < pages.size() && i < 8; i++) {
                char state[96];
                LC32DescribeGuestPageForProfile(pages[i].first & ~1u, state, sizeof(state));
                fprintf(stderr, "LC32PROF     %08x %s %.0f  %s\n", pages[i].first & ~1u,
                    (pages[i].first & 1) ? "write" : "read", pages[i].second / 5.0, state);
            }
            last = now;
        }
    }).detach();
}

extern "C" void LC32ProfileAddRun(uint64_t ticks) {
    if(!LC32ProfileActive) return;
    ThreadStats *t = Current();
    Add(t->runTicks, ticks);
    Add(t->runs, 1);
}

extern "C" void LC32ProfileAddSVC(int number, int insideRun, uint64_t ticks) {
    if(!LC32ProfileActive) return;
    ThreadStats *t = Current();
    if(IsBlockingCall(number))
        Add(insideRun ? t->waitInRunTicks : t->waitOutRunTicks, ticks);
    else
        Add(insideRun ? t->svcInRunTicks : t->svcOutRunTicks, ticks);
    const int index = number - kFirstNumber;
    if(index >= 0 && index < kNumberCount) {
        Add(t->numberTicks[index], ticks);
        Add(t->numberCalls[index], 1);
    }
}

extern "C" void LC32ProfileAddGL(uint64_t ticks) {
    if(!LC32ProfileActive) return;
    ThreadStats *t = Current();
    Add(t->glTicks, ticks);
    Add(t->glCalls, 1);
}

extern "C" void LC32ProfileAddPresent(uint64_t paceTicks, uint64_t presentTicks) {
    if(!LC32ProfileActive) return;
    ThreadStats *t = Current();
    Add(t->paceTicks, paceTicks);
    Add(t->presentTicks, presentTicks);
    frames.fetch_add(1, std::memory_order_relaxed);
}


extern "C" void LC32ProfileAddSlowMemory(uint32_t address, int size, int write, int fromJIT, const void *caller) {
    if(!LC32ProfileActive) return;
    ThreadStats *t = Current();
    Add(t->slowMemory, 1);
    Add(slowTotal, 1);
    if(fromJIT) Add(slowFromJIT, 1);
    else if((t->slowMemory.load(std::memory_order_relaxed) & 15) == 0) {
        std::lock_guard<std::mutex> lock(slowCallerMutex);
        slowCallers[caller] += 16;
    }
    if(address & (size - 1)) Add(slowMisaligned, 1);
    if(((address & 0xfff) + size) > 0x1000) Add(slowCrossPage, 1);
    // Sample one access in 16 into the page histogram.
    if((t->slowMemory.load(std::memory_order_relaxed) & 15) == 0) {
        std::lock_guard<std::mutex> lock(slowPageMutex);
        slowPages[(address & ~0xfffu) | (write ? 1u : 0u)] += 16;
    }
}

extern "C" void LC32ProfileAddCompile(uint64_t ticks) {
    if(!LC32ProfileActive) return;
    Add(Current()->compileTicks, ticks);
}

extern "C" void LC32ProfileAddHostCall(const void *key, int isSelector, uint64_t ticks) {
    if(!LC32ProfileActive) return;
    ThreadStats *t = Current();
    std::lock_guard<std::mutex> lock(t->hostCallMutex);
    auto &entry = t->hostCalls[key];
    entry.ticks += ticks;
    entry.calls += 1;
    entry.selector = isSelector != 0;
}

extern "C" void LC32ProfileNoteFpscr(uint32_t fpscr) {
    if(LC32ProfileActive) Current()->fpscr.store(fpscr, std::memory_order_relaxed);
}

extern "C" void LC32ProfileAddExclusiveWrite(void) {
    if(LC32ProfileActive) exclusiveWrites.fetch_add(1, std::memory_order_relaxed);
}
