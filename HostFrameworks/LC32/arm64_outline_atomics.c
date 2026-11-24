/*
 * Runtime-dispatched ARMv8.1 LSE outline atomics for Apple arm64 targets.
 *
 * Apple's iOS 15 SDK does not ship compiler-rt's ___aarch64_* outline-atomic
 * helpers. Providing them here lets the rest of LiveExec32Shared and Dynarmic
 * compile with -moutline-atomics while remaining 100% compatible with ARMv8.0
 * devices (Apple A9/A10 on iOS 15) and executing single-instruction LSE
 * atomics (casal, ldaddal, swpal, etc.) on Apple A11+ / M1+ silicon.
 *
 * This translation unit MUST be compiled without -moutline-atomics and without
 * LTO so the fallback path emits ARMv8.0 LL/SC instructions directly and the
 * symbols remain visible to post-LTO code generation.
 */

#if defined(__aarch64__)

#include <stdint.h>
#include <sys/sysctl.h>

static int lc32_arm64_have_lse = 0;

static int lc32_sysctl_feature_enabled(const char *name) {
    int value = 0;
    size_t size = sizeof(value);
    return sysctlbyname(name, &value, &size, NULL, 0) == 0 && value != 0;
}

__attribute__((constructor(101)))
static void lc32_init_arm64_outline_atomics(void) {
    lc32_arm64_have_lse =
        lc32_sysctl_feature_enabled("hw.optional.arm.FEAT_LSE") ||
        lc32_sysctl_feature_enabled("hw.optional.armv8_1_atomics");
}

/*
 * Outlined callers for 1-byte and 2-byte helpers do not guarantee zero-extended
 * upper bits in w0/w1. Taking full-width ABI_TYPE (uint32_t for 1/2-byte ops)
 * and narrowing to MEM_TYPE forces explicit uxtb/uxth before the ARMv8.0 LL/SC
 * comparison, matching LLVM compiler-rt's lse.S contract.
 */
#define LC32_DEF_CAS(SIZE, MEM_TYPE, ABI_TYPE, SUFFIX, SUCC_ORDER, FAIL_ORDER) \
    __attribute__((target("lse"), noinline))                                   \
    static ABI_TYPE lc32_cas##SIZE##_##SUFFIX##_lse(                           \
            ABI_TYPE expected_raw, ABI_TYPE desired_raw, MEM_TYPE *ptr) {      \
        MEM_TYPE expected = (MEM_TYPE)expected_raw;                            \
        MEM_TYPE desired = (MEM_TYPE)desired_raw;                              \
        __atomic_compare_exchange_n(                                           \
            ptr, &expected, desired, 0, SUCC_ORDER, FAIL_ORDER);               \
        return (ABI_TYPE)expected;                                             \
    }                                                                          \
    __attribute__((used, visibility("hidden")))                                \
    ABI_TYPE __aarch64_cas##SIZE##_##SUFFIX(                                   \
            ABI_TYPE expected_raw, ABI_TYPE desired_raw, MEM_TYPE *ptr) {      \
        if (__builtin_expect(lc32_arm64_have_lse != 0, 1)) {                   \
            return lc32_cas##SIZE##_##SUFFIX##_lse(                            \
                expected_raw, desired_raw, ptr);                               \
        }                                                                      \
        MEM_TYPE expected = (MEM_TYPE)expected_raw;                            \
        MEM_TYPE desired = (MEM_TYPE)desired_raw;                              \
        __atomic_compare_exchange_n(                                           \
            ptr, &expected, desired, 0, SUCC_ORDER, FAIL_ORDER);               \
        return (ABI_TYPE)expected;                                             \
    }

#define LC32_DEF_CAS_ALL_ORDERS(SIZE, MEM_TYPE, ABI_TYPE)                      \
    LC32_DEF_CAS(SIZE, MEM_TYPE, ABI_TYPE, relax,                              \
        __ATOMIC_RELAXED, __ATOMIC_RELAXED)                                    \
    LC32_DEF_CAS(SIZE, MEM_TYPE, ABI_TYPE, acq,                                \
        __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)                                    \
    LC32_DEF_CAS(SIZE, MEM_TYPE, ABI_TYPE, rel,                                \
        __ATOMIC_RELEASE, __ATOMIC_RELAXED)                                    \
    LC32_DEF_CAS(SIZE, MEM_TYPE, ABI_TYPE, acq_rel,                            \
        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)

LC32_DEF_CAS_ALL_ORDERS(1, uint8_t, uint32_t)
LC32_DEF_CAS_ALL_ORDERS(2, uint16_t, uint32_t)
LC32_DEF_CAS_ALL_ORDERS(4, uint32_t, uint32_t)
LC32_DEF_CAS_ALL_ORDERS(8, uint64_t, uint64_t)
LC32_DEF_CAS_ALL_ORDERS(16, __uint128_t, __uint128_t)

#define LC32_DEF_RMW(OP, BUILTIN, SIZE, MEM_TYPE, ABI_TYPE, SUFFIX, ORDER)     \
    __attribute__((target("lse"), noinline))                                   \
    static ABI_TYPE lc32_##OP##SIZE##_##SUFFIX##_lse(                          \
            ABI_TYPE val_raw, MEM_TYPE *ptr) {                                 \
        return (ABI_TYPE)BUILTIN(ptr, (MEM_TYPE)val_raw, ORDER);               \
    }                                                                          \
    __attribute__((used, visibility("hidden")))                                \
    ABI_TYPE __aarch64_##OP##SIZE##_##SUFFIX(                                  \
            ABI_TYPE val_raw, MEM_TYPE *ptr) {                                 \
        if (__builtin_expect(lc32_arm64_have_lse != 0, 1)) {                   \
            return lc32_##OP##SIZE##_##SUFFIX##_lse(val_raw, ptr);             \
        }                                                                      \
        return (ABI_TYPE)BUILTIN(ptr, (MEM_TYPE)val_raw, ORDER);               \
    }

#define LC32_DEF_LDCLR(SIZE, MEM_TYPE, ABI_TYPE, SUFFIX, ORDER)                \
    __attribute__((target("lse"), noinline))                                   \
    static ABI_TYPE lc32_ldclr##SIZE##_##SUFFIX##_lse(                         \
            ABI_TYPE val_raw, MEM_TYPE *ptr) {                                 \
        return (ABI_TYPE)__atomic_fetch_and(                                   \
            ptr, (MEM_TYPE)~(MEM_TYPE)val_raw, ORDER);                         \
    }                                                                          \
    __attribute__((used, visibility("hidden")))                                \
    ABI_TYPE __aarch64_ldclr##SIZE##_##SUFFIX(                                 \
            ABI_TYPE val_raw, MEM_TYPE *ptr) {                                 \
        if (__builtin_expect(lc32_arm64_have_lse != 0, 1)) {                   \
            return lc32_ldclr##SIZE##_##SUFFIX##_lse(val_raw, ptr);            \
        }                                                                      \
        return (ABI_TYPE)__atomic_fetch_and(                                   \
            ptr, (MEM_TYPE)~(MEM_TYPE)val_raw, ORDER);                         \
    }

#define LC32_DEF_RMW_ALL_ORDERS(OP, BUILTIN, SIZE, MEM_TYPE, ABI_TYPE)         \
    LC32_DEF_RMW(OP, BUILTIN, SIZE, MEM_TYPE, ABI_TYPE, relax,                 \
        __ATOMIC_RELAXED)                                                      \
    LC32_DEF_RMW(OP, BUILTIN, SIZE, MEM_TYPE, ABI_TYPE, acq,                   \
        __ATOMIC_ACQUIRE)                                                      \
    LC32_DEF_RMW(OP, BUILTIN, SIZE, MEM_TYPE, ABI_TYPE, rel,                   \
        __ATOMIC_RELEASE)                                                      \
    LC32_DEF_RMW(OP, BUILTIN, SIZE, MEM_TYPE, ABI_TYPE, acq_rel,               \
        __ATOMIC_ACQ_REL)

#define LC32_DEF_LDCLR_ALL_ORDERS(SIZE, MEM_TYPE, ABI_TYPE)                    \
    LC32_DEF_LDCLR(SIZE, MEM_TYPE, ABI_TYPE, relax, __ATOMIC_RELAXED)          \
    LC32_DEF_LDCLR(SIZE, MEM_TYPE, ABI_TYPE, acq, __ATOMIC_ACQUIRE)            \
    LC32_DEF_LDCLR(SIZE, MEM_TYPE, ABI_TYPE, rel, __ATOMIC_RELEASE)            \
    LC32_DEF_LDCLR(SIZE, MEM_TYPE, ABI_TYPE, acq_rel, __ATOMIC_ACQ_REL)

#define LC32_DEF_ALL_RMW_FOR_SIZE(SIZE, MEM_TYPE, ABI_TYPE)                    \
    LC32_DEF_RMW_ALL_ORDERS(swp, __atomic_exchange_n, SIZE, MEM_TYPE,          \
        ABI_TYPE)                                                              \
    LC32_DEF_RMW_ALL_ORDERS(ldadd, __atomic_fetch_add, SIZE, MEM_TYPE,         \
        ABI_TYPE)                                                              \
    LC32_DEF_LDCLR_ALL_ORDERS(SIZE, MEM_TYPE, ABI_TYPE)                        \
    LC32_DEF_RMW_ALL_ORDERS(ldeor, __atomic_fetch_xor, SIZE, MEM_TYPE,         \
        ABI_TYPE)                                                              \
    LC32_DEF_RMW_ALL_ORDERS(ldset, __atomic_fetch_or, SIZE, MEM_TYPE,          \
        ABI_TYPE)

LC32_DEF_ALL_RMW_FOR_SIZE(1, uint8_t, uint32_t)
LC32_DEF_ALL_RMW_FOR_SIZE(2, uint16_t, uint32_t)
LC32_DEF_ALL_RMW_FOR_SIZE(4, uint32_t, uint32_t)
LC32_DEF_ALL_RMW_FOR_SIZE(8, uint64_t, uint64_t)

#endif /* defined(__aarch64__) */
