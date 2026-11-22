// A32 NEON VQRSHL (all element sizes, signed/unsigned, D and Q forms) and
// VQADD/VQSUB with 64-bit elements, checked against a scalar reference.
// dynarmic used to reject both: VQRSHL was missing from its decoder and the
// 64-bit VQADD/VQSUB forms raised UndefinedInstruction (found by tools/a32scan).
// Build (ARM encodings; add -DTHUMB_WRAPPERS for the Thumb ones):
//   xcrun clang -arch armv7 -marm -O1 -isysroot tmp/iPhoneOS10.3.sdk \
//   -miphoneos-version-min=6.0 -o /tmp/neon_vqrshl test/neon_vqrshl.c
// QC (saturation flag) results depend on LC32_FAST_FP, like neon_vqdmlal.c.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures, qc_failures, checks;
static uint64_t rng_state = 0x9e3779b97f4a7c15ull;

static uint64_t rnd(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

static uint32_t read_fpscr(void) {
    uint32_t v;
    __asm__ volatile("vmrs %0, fpscr" : "=r"(v));
    return v;
}
static void set_qc(int on) {
    uint32_t v = (read_fpscr() & ~(1u << 27)) | ((uint32_t)!!on << 27);
    __asm__ volatile("vmsr fpscr, %0" :: "r"(v));
}

// ---- reference ------------------------------------------------------------------

static uint64_t emask(int esize) { return esize == 64 ? ~0ull : (1ull << esize) - 1; }

static uint64_t get_lane(const uint8_t *v, int esize, int lane) {
    uint64_t x = 0;
    memcpy(&x, v + lane * esize / 8, esize / 8);
    return x;
}
static void put_lane(uint8_t *v, int esize, int lane, uint64_t x) {
    memcpy(v + lane * esize / 8, &x, esize / 8);
}
static int64_t sext(uint64_t x, int esize) {
    return esize == 64 ? (int64_t)x : (int64_t)(x << (64 - esize)) >> (64 - esize);
}

static int64_t smax(int esize) { return (int64_t)(emask(esize) >> 1); }
static int64_t smin(int esize) { return -smax(esize) - 1; }
static uint64_t lsr(uint64_t x, int s) { return s >= 64 ? 0 : x >> s; }
static int64_t asr(int64_t v, int s) { return s >= 64 ? (v < 0 ? -1 : 0) : v >> s; }

// VQRSHL: (operand + round_const) << shift, saturated; shift = signed low byte.
// Left shifts round by 0 and may saturate; right shifts round to nearest
// ((x >> k) + bit k-1 of x) and can never overflow.
static uint64_t ref_vqrshl(uint64_t x, uint64_t shift_elem, int esize, int u, int *sat) {
    const int sh = (int8_t)(shift_elem & 0xff);
    if(u) {
        if(sh >= 0) {
            if(x == 0) return 0;
            if(sh >= esize || x > lsr(emask(esize), sh)) { *sat = 1; return emask(esize); }
            return (x << sh) & emask(esize);
        }
        const int k = -sh;
        return (lsr(x, k) + (lsr(x, k - 1) & 1)) & emask(esize);
    }
    const int64_t v = sext(x, esize);
    if(sh >= 0) {
        if(v == 0) return 0;
        if(sh >= esize || v > asr(smax(esize), sh)) {
            if(v > 0) { *sat = 1; return (uint64_t)smax(esize) & emask(esize); }
        }
        if(sh >= esize || v < asr(smin(esize), sh)) {
            if(v < 0) { *sat = 1; return (uint64_t)smin(esize) & emask(esize); }
        }
        return ((uint64_t)v << sh) & emask(esize);
    }
    const int k = -sh;
    return (uint64_t)(asr(v, k) + (asr(v, k - 1) & 1)) & emask(esize);
}

static uint64_t ref_qaddsub(uint64_t a, uint64_t b, int esize, int u, int sub, int *sat) {
    if(u) {
        uint64_t r;
        if(sub ? __builtin_sub_overflow(a, b, &r) : __builtin_add_overflow(a, b, &r) || r > emask(esize)) {
            *sat = 1;
            return sub ? 0 : emask(esize);
        }
        return r;
    }
    int64_t r;
    const int64_t x = sext(a, esize), y = sext(b, esize);
    if(sub ? __builtin_sub_overflow(x, y, &r) : __builtin_add_overflow(x, y, &r)) {
        *sat = 1;
        return (uint64_t)(x < 0 ? smin(esize) : smax(esize)) & emask(esize);
    }
    if(r > smax(esize) || r < smin(esize)) {
        *sat = 1;
        return (uint64_t)(r < 0 ? smin(esize) : smax(esize)) & emask(esize);
    }
    return (uint64_t)r & emask(esize);
}

// ---- guest instructions -----------------------------------------------------------
// d0/q0 = value (Vm), d2/q1 = shift or second operand, result in d4/q2.

// -DTHUMB_WRAPPERS: the wrappers below become Thumb code inside an ARM build.
// They are only reached through the function-pointer table (blx register), so
// no ARM<->Thumb call fixups are needed: the current Xcode linker leaves bit 0
// clear in LC_MAIN for a Thumb main and emits plain BL for ARM->Thumb calls.
#ifdef THUMB_WRAPPERS
#define WRAPPER __attribute__((target("thumb"), noinline))
#else
#define WRAPPER __attribute__((noinline))
#endif

#define QRSHL(name, mnem)                                                                         \
    WRAPPER static void name##_d(uint8_t *o, const uint8_t *a, const uint8_t *b) {                \
        __asm__ volatile("vld1.8 {d0}, [%1]\n vld1.8 {d2}, [%2]\n" mnem " d4, d0, d2\n"           \
                         "vst1.8 {d4}, [%0]\n" :: "r"(o), "r"(a), "r"(b) : "d0", "d2", "d4", "memory"); \
    }                                                                                             \
    WRAPPER static void name##_q(uint8_t *o, const uint8_t *a, const uint8_t *b) {                \
        __asm__ volatile("vld1.8 {q0}, [%1]\n vld1.8 {q1}, [%2]\n" mnem " q2, q0, q1\n"           \
                         "vst1.8 {q2}, [%0]\n" :: "r"(o), "r"(a), "r"(b) : "q0", "q1", "q2", "memory"); \
    }

QRSHL(qrshl_s8, "vqrshl.s8")
QRSHL(qrshl_s16, "vqrshl.s16")
QRSHL(qrshl_s32, "vqrshl.s32")
QRSHL(qrshl_s64, "vqrshl.s64")
QRSHL(qrshl_u8, "vqrshl.u8")
QRSHL(qrshl_u16, "vqrshl.u16")
QRSHL(qrshl_u32, "vqrshl.u32")
QRSHL(qrshl_u64, "vqrshl.u64")
QRSHL(qadd_s64, "vqadd.s64")
QRSHL(qadd_u64, "vqadd.u64")
QRSHL(qsub_s64, "vqsub.s64")
QRSHL(qsub_u64, "vqsub.u64")

typedef void (*fn_t)(uint8_t *, const uint8_t *, const uint8_t *);
struct op {
    const char *name;
    fn_t d, q;
    int esize, u, kind;   // kind 0 = vqrshl, 1 = vqadd, 2 = vqsub
};
static const struct op ops[] = {
    {"vqrshl.s8", qrshl_s8_d, qrshl_s8_q, 8, 0, 0},    {"vqrshl.s16", qrshl_s16_d, qrshl_s16_q, 16, 0, 0},
    {"vqrshl.s32", qrshl_s32_d, qrshl_s32_q, 32, 0, 0}, {"vqrshl.s64", qrshl_s64_d, qrshl_s64_q, 64, 0, 0},
    {"vqrshl.u8", qrshl_u8_d, qrshl_u8_q, 8, 1, 0},    {"vqrshl.u16", qrshl_u16_d, qrshl_u16_q, 16, 1, 0},
    {"vqrshl.u32", qrshl_u32_d, qrshl_u32_q, 32, 1, 0}, {"vqrshl.u64", qrshl_u64_d, qrshl_u64_q, 64, 1, 0},
    {"vqadd.s64", qadd_s64_d, qadd_s64_q, 64, 0, 1},    {"vqadd.u64", qadd_u64_d, qadd_u64_q, 64, 1, 1},
    {"vqsub.s64", qsub_s64_d, qsub_s64_q, 64, 0, 2},    {"vqsub.u64", qsub_u64_d, qsub_u64_q, 64, 1, 2},
};

static uint64_t value(int esize) {
    const uint64_t m = emask(esize);
    const uint64_t edges[] = {0, 1, m, m - 1, m >> 1, (m >> 1) + 1, 2, 3};
    return (rnd() & 1) ? edges[rnd() % 8] : rnd() & m;
}
static uint64_t shift(int esize) {
    int8_t s = (rnd() & 1) ? (int8_t)((int)(rnd() % (2 * esize + 6)) - esize - 3) : (int8_t)rnd();
    return ((rnd() << 8) | (uint8_t)s) & emask(esize);
}

int main(void) {
    for(size_t i = 0; i < sizeof ops / sizeof ops[0]; i++) {
        const struct op *op = &ops[i];
        int bad = 0, bad_qc = 0;
        for(int it = 0; it < 400; it++) {
            for(int q = 0; q < 2; q++) {
                const int lanes = (q ? 128 : 64) / op->esize;
                uint8_t a[16] = {0}, b[16] = {0}, got[16] = {0}, want[16] = {0};
                int sat = 0;
                for(int l = 0; l < lanes; l++) {
                    put_lane(a, op->esize, l, value(op->esize));
                    put_lane(b, op->esize, l, op->kind ? value(op->esize) : shift(op->esize));
                    uint64_t r = op->kind == 0
                        ? ref_vqrshl(get_lane(a, op->esize, l), get_lane(b, op->esize, l), op->esize, op->u, &sat)
                        : ref_qaddsub(get_lane(a, op->esize, l), get_lane(b, op->esize, l), op->esize, op->u, op->kind == 2, &sat);
                    put_lane(want, op->esize, l, r);
                }
                // QC is sticky: every other case starts with it set and must keep it.
                const int qc_before = it & 1;
                set_qc(qc_before);
                (q ? op->q : op->d)(got, a, b);
                const int qc = (read_fpscr() >> 27) & 1;
                sat |= qc_before;
                checks++;
                if(memcmp(got, want, q ? 16 : 8)) {
                    if(bad++ < 2) {
                        printf("FAIL %s %s a=", op->name, q ? "q" : "d");
                        for(int k = 0; k < (q ? 16 : 8); k++) printf("%02x", a[k]);
                        printf(" b=");
                        for(int k = 0; k < (q ? 16 : 8); k++) printf("%02x", b[k]);
                        printf(" got=");
                        for(int k = 0; k < (q ? 16 : 8); k++) printf("%02x", got[k]);
                        printf(" want=");
                        for(int k = 0; k < (q ? 16 : 8); k++) printf("%02x", want[k]);
                        printf("\n");
                    }
                } else if(qc != sat) {
                    bad_qc++;
                }
            }
        }
        failures += bad;
        qc_failures += bad_qc;
        printf("%s %s: %d value mismatches, %d QC mismatches\n", bad ? "FAIL" : "ok  ", op->name, bad, bad_qc);
    }
    printf("%d checks: %d value failures, %d QC-only failures\n", checks, failures, qc_failures);
    return failures || qc_failures ? 1 : 0;
}
