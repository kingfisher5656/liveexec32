#pragma once
/*
 * LC32_PROFILE=1 (environment or LiveExec32.env): every five seconds, log
 * where each guest thread's time went. Off by default; when off every hook
 * is a single predictable branch.
 */
#include <stdint.h>
#include <mach/mach_time.h>

#ifdef __cplusplus
extern "C" {
#endif

extern int LC32ProfileActive; /* 0 off, 1 on; set once at startup */

void LC32ProfileInitialize(void);
void LC32ProfileAddRun(uint64_t ticks);               /* inside jit->Run/Step */
void LC32ProfileAddSVC(int number, int insideRun, uint64_t ticks);
void LC32ProfileAddGL(uint64_t ticks);                /* one bridged GL call */
void LC32ProfileAddPresent(uint64_t paceTicks, uint64_t presentTicks);
void LC32ProfileAddSlowMemory(uint32_t address, int size, int write, int fromJIT, const void *caller); /* callback-path access */
void LC32ProfileAddCompile(uint64_t ticks);           /* dynarmic Emit */
void LC32ProfileAddExclusiveWrite(void);
void LC32ProfileNoteFpscr(uint32_t fpscr);           /* guest FPSCR seen at a syscall */
/* A bridged host call: key is a host function pointer, or a SEL when
 * isSelector is set. */
void LC32ProfileAddHostCall(const void *key, int isSelector, uint64_t ticks);

#ifdef __cplusplus
}
#endif

static inline uint64_t LC32ProfileNow(void) {
    return LC32ProfileActive ? mach_absolute_time() : 0;
}
