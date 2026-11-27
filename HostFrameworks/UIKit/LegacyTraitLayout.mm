// Pre-iOS-8 apps predate UITraitCollection and frequently tear down and
// recreate their OpenGL ES drawable or engine inside -layoutSubviews (for
// example, Apple's classic EAGLView template and Call of Atlantis Lite, whose
// -[EAGLView layoutSubviews] destroys the engine while its detached
// ThreadResourceLoader is still running).
//
// On modern iOS, FrontBoard scene/component trait updates (such as
// SBUISecureRenderingClientComponent) and appearance changes invalidate traits
// asynchronously after launch. Under pre-iOS-17 effective SDKs, UIKit's legacy
// fallback calls -[UIView setNeedsLayout] directly during trait invalidation;
// under iOS 17+ effective SDKs, CALayer's pre-layout pass still calls
// -[UIView setNeedsLayout] on theme changes for views overriding -layoutSubviews.
//
// Calibrate UIKit's exact trait-invalidation return PCs once on the main thread
// using offscreen native views with geometry/hierarchy negative controls (no
// private symbol names, which are redacted on devices), and drop only
// trait-scheduled -setNeedsLayout calls on pre-iOS-8 guest CAEAGLLayer-backed
// views with custom layout implementations. Explicit calls, geometry/hierarchy
// mutations (including reentrant ones), and subview trait propagation stay intact.
//
// Keep this crash fix active even when optional UIKit compatibility is disabled.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <atomic>
#include <dlfcn.h>
#include <pthread.h>
#include <ptrauth.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern "C" uint32_t LC32GetGuestExecutableSDKVersion(void);

@interface NSObject (LC32LegacyTraitLayoutGuestClass)
- (BOOL)isGuestClass;
@end

namespace {

using SetNeedsLayoutIMP = void (*)(__unsafe_unretained id, SEL);
using PerformPreLayoutIMP = void (*)(__unsafe_unretained id, SEL,
                                     __unsafe_unretained CALayer *);

constexpr size_t kMaxTraitReturnPCs = 8;
constexpr size_t kMaxRejectedReturnPCs = 24;

SetNeedsLayoutIMP originalSetNeedsLayout;
PerformPreLayoutIMP originalPerformPreLayoutUpdate;
void *uikitImageBase;
std::atomic<bool> calibrated{false};
bool calibrationValid;
void *traitReturnPCs[kMaxTraitReturnPCs];
size_t traitReturnPCCount;
void *rejectedReturnPCs[kMaxRejectedReturnPCs];
size_t rejectedReturnPCCount;

enum class CalibrationPhase {
    None,
    Direct,
    Negative,
    Trait,
};

struct PreLayoutState {
    __unsafe_unretained UIView *view;
    CGRect bounds;
    __unsafe_unretained NSArray *sublayers;
    bool suppressed;
};

thread_local bool calibrating;
thread_local __unsafe_unretained UIView *calibrationTarget;
thread_local CalibrationPhase calibrationPhase = CalibrationPhase::None;
thread_local void *calibrationDirectReturnPC;
thread_local void *calibrationRejected[kMaxRejectedReturnPCs];
thread_local size_t calibrationRejectedCount;
thread_local bool calibrationRejectedOverflow;
thread_local void *calibrationCandidates[kMaxTraitReturnPCs];
thread_local size_t calibrationCandidateCount;
thread_local PreLayoutState preLayoutState;

void *CodeAddress(void *address) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(address, ptrauth_key_function_pointer);
#else
    return address;
#endif
}

bool AddressInUIKit(void *returnPC) {
    if(!returnPC || !uikitImageBase) return false;
    Dl_info info = {};
    // Look inside the calling instruction, not the next function boundary.
    return dladdr((void *)((uintptr_t)returnPC - 1), &info) &&
        info.dli_fbase == uikitImageBase;
}

bool IsGuestViewClass(Class cls) {
    for(; cls && cls != UIView.class; cls = class_getSuperclass(cls)) {
        if([(id)cls isGuestClass]) return true;
    }
    return false;
}

bool HasCustomLayout(Class cls) {
    static IMP baseLayoutSubviews =
        class_getMethodImplementation(UIView.class, @selector(layoutSubviews));
    static IMP baseLayoutSublayers = class_getMethodImplementation(
        UIView.class, @selector(layoutSublayersOfLayer:));
    return class_getMethodImplementation(cls, @selector(layoutSubviews)) !=
            baseLayoutSubviews ||
        class_getMethodImplementation(cls, @selector(layoutSublayersOfLayer:)) !=
            baseLayoutSublayers;
}

bool IsEligibleGuestRendererClass(Class cls) {
    return IsGuestViewClass(cls) && HasCustomLayout(cls);
}

CALayer *NativeViewLayer(__unsafe_unretained UIView *view) {
    using LayerGetter = CALayer *(*)(__unsafe_unretained id, SEL);
    static LayerGetter getter = reinterpret_cast<LayerGetter>(
        class_getMethodImplementation(UIView.class, @selector(layer)));
    return view ? getter(view, @selector(layer)) : nil;
}

CGRect NativeViewBounds(__unsafe_unretained UIView *view) {
    using BoundsGetter = CGRect (*)(__unsafe_unretained id, SEL);
    static BoundsGetter getter = reinterpret_cast<BoundsGetter>(
        class_getMethodImplementation(UIView.class, @selector(bounds)));
    return view ? getter(view, @selector(bounds)) : CGRectZero;
}

bool IsEAGLBackedView(__unsafe_unretained UIView *view) {
    static Class eaglLayerClass = NSClassFromString(@"CAEAGLLayer");
    return eaglLayerClass &&
        [NativeViewLayer(view) isKindOfClass:eaglLayerClass];
}

bool SublayersEqual(__unsafe_unretained NSArray *a,
                    __unsafe_unretained NSArray *b) {
    return a == b || (a != nil && b != nil && [a isEqualToArray:b]);
}

bool AppendUniquePC(void **list, size_t &count, size_t capacity, void *pc) {
    if(!pc) return true;
    for(size_t i = 0; i < count; ++i) {
        if(list[i] == pc) return true;
    }
    if(count >= capacity) return false;
    list[count++] = pc;
    return true;
}

bool ListContainsPC(void *const *list, size_t count, void *pc) {
    for(size_t i = 0; i < count; ++i) {
        if(list[i] == pc) return true;
    }
    return false;
}

void RecordCalibrationReturnPC(void *returnPC) {
    if(!returnPC) return;
    switch(calibrationPhase) {
        case CalibrationPhase::Direct:
            if(!calibrationDirectReturnPC) calibrationDirectReturnPC = returnPC;
            if(!AppendUniquePC(calibrationRejected, calibrationRejectedCount,
                    kMaxRejectedReturnPCs, returnPC)) {
                calibrationRejectedOverflow = true;
            }
            break;
        case CalibrationPhase::Negative:
            if(!AppendUniquePC(calibrationRejected, calibrationRejectedCount,
                    kMaxRejectedReturnPCs, returnPC)) {
                calibrationRejectedOverflow = true;
            }
            break;
        case CalibrationPhase::Trait:
            AppendUniquePC(calibrationCandidates, calibrationCandidateCount,
                kMaxTraitReturnPCs, returnPC);
            break;
        case CalibrationPhase::None:
            break;
    }
}

__attribute__((noinline)) void CallDirectSetNeedsLayout(UIView *view) {
    [view setNeedsLayout];
    // Prevent tail-call optimization so directReturnPC stays in this function.
    asm volatile("" ::: "memory");
}

struct CalibrationGuard {
    CalibrationGuard() {
        calibrating = true;
        calibrationTarget = nil;
        calibrationPhase = CalibrationPhase::None;
        calibrationDirectReturnPC = nullptr;
        calibrationRejectedCount = 0;
        calibrationRejectedOverflow = false;
        calibrationCandidateCount = 0;
    }
    ~CalibrationGuard() {
        calibrationTarget = nil;
        calibrationPhase = CalibrationPhase::None;
        calibrating = false;
    }
    CalibrationGuard(const CalibrationGuard &) = delete;
    CalibrationGuard &operator=(const CalibrationGuard &) = delete;
};

void EnsureCalibratedOnMainThread(void) {
    if(!pthread_main_np()) return;
    if(calibrated.load(std::memory_order_relaxed)) return;

    {
        CalibrationGuard guard;
        @autoreleasepool {
            // Attach a throwaway native view to both a superview and a
            // controller so UIKit's legacy trait invalidation takes its
            // setNeedsLayout path across pre-iOS-17 effective SDKs, without
            // touching any window or scene state. On iOS 17+ effective SDKs
            // UIKit uses pre-layout instead, so capturing zero legacy trait
            // PCs is expected and does not retry per call.
            UIView *parent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
            UIView *child = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
            UIViewController *controller = [[UIViewController alloc] init];
            controller.view = child;
            [parent addSubview:child];

            calibrationTarget = child;
            calibrationPhase = CalibrationPhase::Direct;
            CallDirectSetNeedsLayout(child);

            // Negative controls: capture UIKit's own geometry, subview
            // insertion/removal, and subview reordering setNeedsLayout call
            // sites on the same probe view so a shared helper can never be
            // accepted as trait-specific.
            calibrationPhase = CalibrationPhase::Negative;
            child.frame = CGRectMake(0, 0, 20, 20);
            child.bounds = CGRectMake(0, 0, 30, 30);
            UIView *subA = [[UIView alloc] initWithFrame:CGRectZero];
            UIView *subB = [[UIView alloc] initWithFrame:CGRectZero];
            [child addSubview:subA];
            [child addSubview:subB];
            [child bringSubviewToFront:subA];
            [child sendSubviewToBack:subA];
            [child exchangeSubviewAtIndex:0 withSubviewAtIndex:1];
            [subA removeFromSuperview];
            [subB removeFromSuperview];

            // Only enable suppression if a direct send lands straight in our
            // hook from our own image (no shared UIKit/accessibility trampoline
            // rewriting every caller's return PC).
            if(calibrationDirectReturnPC &&
                    !calibrationRejectedOverflow &&
                    !AddressInUIKit(calibrationDirectReturnPC)) {
                size_t rejected = 0;
                for(size_t i = 0; i < calibrationRejectedCount; ++i) {
                    if(AddressInUIKit(calibrationRejected[i])) {
                        rejectedReturnPCs[rejected++] = calibrationRejected[i];
                    }
                }
                rejectedReturnPCCount = rejected;

                calibrationPhase = CalibrationPhase::Trait;
                parent.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
                child.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
                if(@available(iOS 17.0, *)) {
                    parent.traitOverrides.horizontalSizeClass =
                        UIUserInterfaceSizeClassRegular;
                    child.traitOverrides.horizontalSizeClass =
                        UIUserInterfaceSizeClassCompact;
                }

                size_t accepted = 0;
                for(size_t i = 0; i < calibrationCandidateCount; ++i) {
                    void *pc = calibrationCandidates[i];
                    if(AddressInUIKit(pc) &&
                            !ListContainsPC(calibrationRejected,
                                calibrationRejectedCount, pc)) {
                        traitReturnPCs[accepted++] = pc;
                    }
                }
                traitReturnPCCount = accepted;
                calibrationValid = true;
            }
        }
    }

    calibrated.store(true, std::memory_order_release);
}

void LogSuppressedOnce(__unsafe_unretained UIView *view) {
    static std::atomic<bool> logged{false};
    if(!logged.exchange(true, std::memory_order_relaxed)) {
        fprintf(stderr,
            "LC32: ignoring trait-invalidation setNeedsLayout on %s\n",
            object_getClassName(view));
    }
}

struct PreLayoutSuppressScope {
    PreLayoutState previous = preLayoutState;
    NSArray *ownedSublayers;
    explicit PreLayoutSuppressScope(__unsafe_unretained UIView *view)
        : ownedSublayers([NativeViewLayer(view).sublayers copy]) {
        preLayoutState = {view, NativeViewBounds(view), ownedSublayers, false};
    }
    ~PreLayoutSuppressScope() { preLayoutState = previous; }
    PreLayoutSuppressScope(const PreLayoutSuppressScope &) = delete;
    PreLayoutSuppressScope &operator=(const PreLayoutSuppressScope &) = delete;
};

void LC32PerformPreLayoutUpdate(__unsafe_unretained UIView *self, SEL selector,
                                __unsafe_unretained CALayer *layer) {
    // On modern effective SDKs (iOS 17+), UIKit processes theme trait changes
    // during CALayer's pre-layout phase (_performPreLayoutUpdateOfLayer:) and
    // still calls -[UIView setNeedsLayout] on subclasses with -layoutSubviews.
    // Scope suppression strictly to this exact pre-iOS-8 guest EAGL view once
    // calibration succeeds, and restore layout if a reentrant callback mutates
    // bounds or sublayers during the pass.
    if(LC32GetGuestExecutableSDKVersion() < 0x80000 &&
            pthread_main_np() &&
            IsEligibleGuestRendererClass(object_getClass(self)) &&
            IsEAGLBackedView(self)) {
        if(!calibrated.load(std::memory_order_acquire)) {
            EnsureCalibratedOnMainThread();
        }
        if(calibrated.load(std::memory_order_acquire) && calibrationValid) {
            bool restoreLayout = false;
            {
                PreLayoutSuppressScope scope(self);
                originalPerformPreLayoutUpdate(self, selector, layer);
                if(preLayoutState.suppressed &&
                        (!CGRectEqualToRect(NativeViewBounds(self),
                             preLayoutState.bounds) ||
                         !SublayersEqual(NativeViewLayer(self).sublayers,
                             preLayoutState.sublayers))) {
                    restoreLayout = true;
                }
            }
            if(restoreLayout) {
                originalSetNeedsLayout(self, @selector(setNeedsLayout));
            }
            return;
        }
    }
    originalPerformPreLayoutUpdate(self, selector, layer);
}

__attribute__((noinline)) void LC32SetNeedsLayout(
        __unsafe_unretained UIView *self, SEL selector) {
    void *returnPC = CodeAddress(
        __builtin_extract_return_addr(__builtin_return_address(0)));
    if(__builtin_expect(calibrating, 0)) {
        if(self == calibrationTarget) {
            RecordCalibrationReturnPC(returnPC);
            return;
        }
        originalSetNeedsLayout(self, selector);
        return;
    }
    if(__builtin_expect(self == preLayoutState.view, 0)) {
        if(pthread_main_np() &&
                AddressInUIKit(returnPC) &&
                !ListContainsPC(rejectedReturnPCs, rejectedReturnPCCount, returnPC) &&
                CGRectEqualToRect(NativeViewBounds(self), preLayoutState.bounds) &&
                SublayersEqual(NativeViewLayer(self).sublayers,
                    preLayoutState.sublayers)) {
            preLayoutState.suppressed = true;
            LogSuppressedOnce(self);
            return;
        }
        originalSetNeedsLayout(self, selector);
        return;
    }
    if(LC32GetGuestExecutableSDKVersion() < 0x80000 &&
            pthread_main_np() &&
            IsEligibleGuestRendererClass(object_getClass(self))) {
        if(!calibrated.load(std::memory_order_acquire)) {
            EnsureCalibratedOnMainThread();
        }
        if(calibrated.load(std::memory_order_acquire) &&
                calibrationValid &&
                ListContainsPC(traitReturnPCs, traitReturnPCCount, returnPC) &&
                IsEAGLBackedView(self)) {
            LogSuppressedOnce(self);
            return;
        }
    }
    originalSetNeedsLayout(self, selector);
}

} // namespace

@interface LC32LegacyTraitLayout : NSObject
@end

@implementation LC32LegacyTraitLayout

+ (void)load {
    Dl_info viewImage = {};
    if(!dladdr((__bridge const void *)UIView.class, &viewImage) ||
            !viewImage.dli_fbase) return;
    Method method = class_getInstanceMethod(UIView.class, @selector(setNeedsLayout));
    char returnType[8] = {};
    if(method) method_getReturnType(method, returnType, sizeof(returnType));
    if(!method || method_getNumberOfArguments(method) != 2 ||
            strcmp(returnType, @encode(void)) != 0) return;

    IMP original = method_getImplementation(method);
    Dl_info methodImage = {};
    if(!dladdr(CodeAddress((void *)original), &methodImage) ||
            methodImage.dli_fbase != viewImage.dli_fbase) return;

    uikitImageBase = viewImage.dli_fbase;
    originalSetNeedsLayout = reinterpret_cast<SetNeedsLayoutIMP>(original);
    class_replaceMethod(UIView.class, @selector(setNeedsLayout),
        (IMP)LC32SetNeedsLayout, method_getTypeEncoding(method));

    SEL preLayoutSel = sel_registerName("_performPreLayoutUpdateOfLayer:");
    Method preLayout = class_getInstanceMethod(UIView.class, preLayoutSel);
    char preRet[8] = {};
    char preArg[8] = {};
    if(preLayout && method_getNumberOfArguments(preLayout) == 3) {
        method_getReturnType(preLayout, preRet, sizeof(preRet));
        method_getArgumentType(preLayout, 2, preArg, sizeof(preArg));
        IMP preOrig = method_getImplementation(preLayout);
        Dl_info preImage = {};
        if(strcmp(preRet, @encode(void)) == 0 &&
                strcmp(preArg, @encode(id)) == 0 &&
                dladdr(CodeAddress((void *)preOrig), &preImage) &&
                preImage.dli_fbase == viewImage.dli_fbase) {
            originalPerformPreLayoutUpdate =
                reinterpret_cast<PerformPreLayoutIMP>(preOrig);
            class_replaceMethod(UIView.class, preLayoutSel,
                (IMP)LC32PerformPreLayoutUpdate,
                method_getTypeEncoding(preLayout));
        }
    }
}

@end
