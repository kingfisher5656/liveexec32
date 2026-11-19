// A32 NEON VQDMLAL/VQDMLSL/VQDMULL (vector and by-scalar) and V(R)ADDHN/V(R)SUBHN, checked against a
// scalar reference. Modern Combat 4's cutscene decoder executes
// "vqdmlal.s16 q4, d0, d17" (0xf2908921), which dynarmic used to reject.
// Build: xcrun clang -arch armv7 -marm -O1 -isysroot tmp/iPhoneOS10.3.sdk \
//   -miphoneos-version-min=6.0 -o /tmp/neon_vqdmlal test/neon_vqdmlal.c
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures;

static int64_t sat(int64_t v, int bits) {
    const int64_t max = (bits == 64) ? INT64_MAX : (((int64_t)1 << (bits - 1)) - 1);
    const int64_t min = -max - 1;
    return v > max ? max : v < min ? min : v;
}

// Exact 2*a*b saturated to 64 bits, then acc +/- product saturated to 64 bits.
static int64_t sat64_add(int64_t a, int64_t b) {
    int64_t r;
    if(__builtin_add_overflow(a, b, &r)) return a < 0 ? INT64_MIN : INT64_MAX;
    return r;
}
static int64_t sat64_sub(int64_t a, int64_t b) {
    int64_t r;
    if(__builtin_sub_overflow(a, b, &r)) return a < 0 ? INT64_MIN : INT64_MAX;
    return r;
}
static int64_t dmull32(int32_t a, int32_t b) {
    if(a == INT32_MIN && b == INT32_MIN) return INT64_MAX;
    return 2 * (int64_t)a * b;
}

static void check(const char *name, const void *got, const void *want, size_t size) {
    if(memcmp(got, want, size)) {
        failures++;
        printf("FAIL %s\n", name);
        const uint32_t *g = got, *w = want;
        for(size_t i = 0; i < size / 4; i++) printf("  [%zu] got %08x want %08x\n", i, g[i], w[i]);
    } else {
        printf("ok   %s\n", name);
    }
}

static uint32_t read_fpscr(void) {
    uint32_t v;
    __asm__ volatile("vmrs %0, fpscr" : "=r"(v));
    return v;
}
static void clear_qc(void) {
    uint32_t v = read_fpscr() & ~(1u << 27);
    __asm__ volatile("vmsr fpscr, %0" :: "r"(v));
}

int main(void) {
    const int16_t n16[4] = {1000, -32768, 32767, -12345};
    const int16_t m16[4] = {-3, -32768, 2, 777};
    const int32_t acc32[4] = {5, 100, 0x7ffffff0, -0x7ffffff0};
    const int32_t n32[2] = {123456, INT32_MIN};
    const int32_t m32[2] = {-7, INT32_MIN};
    const int64_t acc64[2] = {42, INT64_MIN + 5};

    // vqdmlal.s16 / vqdmlsl.s16 / vqdmull.s16 (vector)
    for(int op = 0; op < 3; op++) {
        int32_t got[4], want[4];
        for(int i = 0; i < 4; i++) {
            int64_t p = sat(2 * (int64_t)n16[i] * m16[i], 32);
            want[i] = op == 0 ? (int32_t)sat(acc32[i] + p, 32)
                    : op == 1 ? (int32_t)sat(acc32[i] - p, 32) : (int32_t)p;
        }
        clear_qc();
        if(op == 0)
            __asm__ volatile("vld1.16 {d0}, [%1]\n vld1.16 {d17}, [%2]\n vld1.32 {q4}, [%3]\n"
                             ".long 0xf2908921\n" // vqdmlal.s16 q4, d0, d17 (the MC4 encoding)
                             "vst1.32 {q4}, [%0]\n"
                             :: "r"(got), "r"(n16), "r"(m16), "r"(acc32) : "d0", "d17", "q4", "memory");
        else if(op == 1)
            __asm__ volatile("vld1.16 {d0}, [%1]\n vld1.16 {d17}, [%2]\n vld1.32 {q4}, [%3]\n"
                             "vqdmlsl.s16 q4, d0, d17\n vst1.32 {q4}, [%0]\n"
                             :: "r"(got), "r"(n16), "r"(m16), "r"(acc32) : "d0", "d17", "q4", "memory");
        else
            __asm__ volatile("vld1.16 {d0}, [%1]\n vld1.16 {d17}, [%2]\n"
                             "vqdmull.s16 q4, d0, d17\n vst1.32 {q4}, [%0]\n"
                             :: "r"(got), "r"(n16), "r"(m16) : "d0", "d17", "q4", "memory");
        const char *names[] = {"vqdmlal.s16", "vqdmlsl.s16", "vqdmull.s16"};
        check(names[op], got, want, sizeof got);
        if(!(read_fpscr() & (1u << 27))) { failures++; printf("FAIL %s: QC not set\n", names[op]); }
    }

    // .s32 forms (64-bit lanes)
    for(int op = 0; op < 3; op++) {
        int64_t got[2], want[2];
        for(int i = 0; i < 2; i++) {
            int64_t p = dmull32(n32[i], m32[i]);
            want[i] = op == 0 ? sat64_add(acc64[i], p) : op == 1 ? sat64_sub(acc64[i], p) : p;
        }
        if(op == 0)
            __asm__ volatile("vld1.32 {d0}, [%1]\n vld1.32 {d17}, [%2]\n vld1.64 {q4}, [%3]\n"
                             "vqdmlal.s32 q4, d0, d17\n vst1.64 {q4}, [%0]\n"
                             :: "r"(got), "r"(n32), "r"(m32), "r"(acc64) : "d0", "d17", "q4", "memory");
        else if(op == 1)
            __asm__ volatile("vld1.32 {d0}, [%1]\n vld1.32 {d17}, [%2]\n vld1.64 {q4}, [%3]\n"
                             "vqdmlsl.s32 q4, d0, d17\n vst1.64 {q4}, [%0]\n"
                             :: "r"(got), "r"(n32), "r"(m32), "r"(acc64) : "d0", "d17", "q4", "memory");
        else
            __asm__ volatile("vld1.32 {d0}, [%1]\n vld1.32 {d17}, [%2]\n"
                             "vqdmull.s32 q4, d0, d17\n vst1.64 {q4}, [%0]\n"
                             :: "r"(got), "r"(n32), "r"(m32) : "d0", "d17", "q4", "memory");
        const char *names[] = {"vqdmlal.s32", "vqdmlsl.s32", "vqdmull.s32"};
        check(names[op], got, want, sizeof got);
    }

    // By scalar: vqdmlal.s16 q4, d0, d1[2] / vqdmlsl.s16
    for(int op = 0; op < 2; op++) {
        int32_t got[4], want[4];
        for(int i = 0; i < 4; i++) {
            int64_t p = sat(2 * (int64_t)n16[i] * m16[2], 32);
            want[i] = (int32_t)sat(op ? acc32[i] - p : acc32[i] + p, 32);
        }
        if(op == 0)
            __asm__ volatile("vld1.16 {d0}, [%1]\n vld1.16 {d1}, [%2]\n vld1.32 {q4}, [%3]\n"
                             "vqdmlal.s16 q4, d0, d1[2]\n vst1.32 {q4}, [%0]\n"
                             :: "r"(got), "r"(n16), "r"(m16), "r"(acc32) : "d0", "d1", "q4", "memory");
        else
            __asm__ volatile("vld1.16 {d0}, [%1]\n vld1.16 {d1}, [%2]\n vld1.32 {q4}, [%3]\n"
                             "vqdmlsl.s16 q4, d0, d1[2]\n vst1.32 {q4}, [%0]\n"
                             :: "r"(got), "r"(n16), "r"(m16), "r"(acc32) : "d0", "d1", "q4", "memory");
        check(op ? "vqdmlsl.s16 scalar" : "vqdmlal.s16 scalar", got, want, sizeof got);
    }
    {
        int64_t got[2], want[2];
        for(int i = 0; i < 2; i++) want[i] = sat64_add(acc64[i], dmull32(n32[i], m32[1]));
        __asm__ volatile("vld1.32 {d0}, [%1]\n vld1.32 {d1}, [%2]\n vld1.64 {q4}, [%3]\n"
                         "vqdmlal.s32 q4, d0, d1[1]\n vst1.64 {q4}, [%0]\n"
                         :: "r"(got), "r"(n32), "r"(m32), "r"(acc64) : "d0", "d1", "q4", "memory");
        check("vqdmlal.s32 scalar", got, want, sizeof got);
    }

    // vaddhn/vraddhn/vsubhn/vrsubhn .i32 (MC4: "vaddhn.i32 d0, q4, q4", 0xf2980408)
    {
        const uint32_t a[4] = {0x12345678u, 0xffff8000u, 0x00017fffu, 0x80000000u};
        const uint32_t b[4] = {0x00008000u, 0x00008000u, 0x00000001u, 0x7fffffffu};
        for(int op = 0; op < 4; op++) {
            uint16_t got[4], want[4];
            for(int i = 0; i < 4; i++) {
                uint32_t w = (op & 2) ? a[i] - b[i] : a[i] + b[i];
                if(op & 1) w += 0x8000u;
                want[i] = (uint16_t)(w >> 16);
            }
            if(op == 0)
                __asm__ volatile("vld1.32 {q4}, [%1]\n vld1.32 {q5}, [%2]\n"
                                 "vaddhn.i32 d0, q4, q5\n vst1.16 {d0}, [%0]\n"
                                 :: "r"(got), "r"(a), "r"(b) : "d0", "q4", "q5", "memory");
            else if(op == 1)
                __asm__ volatile("vld1.32 {q4}, [%1]\n vld1.32 {q5}, [%2]\n"
                                 "vraddhn.i32 d0, q4, q5\n vst1.16 {d0}, [%0]\n"
                                 :: "r"(got), "r"(a), "r"(b) : "d0", "q4", "q5", "memory");
            else if(op == 2)
                __asm__ volatile("vld1.32 {q4}, [%1]\n vld1.32 {q5}, [%2]\n"
                                 "vsubhn.i32 d0, q4, q5\n vst1.16 {d0}, [%0]\n"
                                 :: "r"(got), "r"(a), "r"(b) : "d0", "q4", "q5", "memory");
            else
                __asm__ volatile("vld1.32 {q4}, [%1]\n vld1.32 {q5}, [%2]\n"
                                 "vrsubhn.i32 d0, q4, q5\n vst1.16 {d0}, [%0]\n"
                                 :: "r"(got), "r"(a), "r"(b) : "d0", "q4", "q5", "memory");
            const char *names[] = {"vaddhn.i32", "vraddhn.i32", "vsubhn.i32", "vrsubhn.i32"};
            check(names[op], got, want, sizeof got);
        }
    }
    // vsubhn.i16 (MC4 0x45d054) and vaddhn.i64
    {
        const uint16_t a[8] = {0x1234, 0x8000, 0xffff, 0x0100, 0x7f80, 0x0001, 0xabcd, 0x00ff};
        const uint16_t b[8] = {0x0034, 0x0001, 0x0001, 0x0200, 0x0080, 0x0002, 0x1111, 0x0001};
        uint8_t got[8], want[8];
        for(int i = 0; i < 8; i++) want[i] = (uint8_t)((uint16_t)(a[i] - b[i]) >> 8);
        __asm__ volatile("vld1.16 {q4}, [%1]\n vld1.16 {q5}, [%2]\n"
                         "vsubhn.i16 d0, q4, q5\n vst1.8 {d0}, [%0]\n"
                         :: "r"(got), "r"(a), "r"(b) : "d0", "q4", "q5", "memory");
        check("vsubhn.i16", got, want, sizeof got);
        const uint64_t c[2] = {0x123456789abcdef0ull, 0xffffffff00000000ull};
        const uint64_t e[2] = {0x0000000100000000ull, 0x0000000100000000ull};
        uint32_t got32[2], want32[2];
        for(int i = 0; i < 2; i++) want32[i] = (uint32_t)((c[i] + e[i]) >> 32);
        __asm__ volatile("vld1.64 {q4}, [%1]\n vld1.64 {q5}, [%2]\n"
                         "vaddhn.i64 d0, q4, q5\n vst1.32 {d0}, [%0]\n"
                         :: "r"(got32), "r"(c), "r"(e) : "d0", "q4", "q5", "memory");
        check("vaddhn.i64", got32, want32, sizeof got32);
    }

    printf(failures ? "FAILED %d\n" : "PASS\n", failures);
    return failures != 0;
}
