// Pre-iOS-8 apps predate UITraitCollection and frequently tear down and
// recreate their OpenGL ES drawable or engine inside -layoutSubviews (for
// example, Apple's classic EAGLView template and Call of Atlantis Lite, whose
// -[EAGLView layoutSubviews] destroys the engine while its detached
// ThreadResourceLoader is still running).
//
// On modern iOS, FrontBoard scene/component trait updates (such as
// SBUISecureRenderingClientComponent) and appearance changes invalidate traits
// asynchronously after launch. Under the pre-iOS-17 effective SDKs used for
// pre-iOS-8 guests, UIKit's legacy fallback calls -[UIView setNeedsLayout]
// directly during trait invalidation.
//
// Calibrate UIKit's exact trait-invalidation return PCs once on the main thread
// using offscreen native views with geometry/hierarchy negative controls (no
// private symbol names, which are redacted on devices), and drop only
// trait-scheduled -setNeedsLayout calls on pre-iOS-8 guest CAEAGLLayer-backed
// views with custom layout implementations. Explicit calls, geometry/hierarchy
// mutations, and subview trait propagation stay intact.
//
// Keep this crash fix active even when optional UIKit compatibility is
// disabled. Set LC32_TRAIT_LAYOUT_FIX=0 to disable it for diagnostics.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <atomic>
#include <dlfcn.h>
#include <pthread.h>
#include <ptrauth.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unordered_map>

extern "C" uint32_t LC32GetGuestExecutableSDKVersion(void);

@interface NSObject (LC32LegacyTraitLayoutGuestClass)
- (BOOL)isGuestClass;
@end

namespace {

using SetNeedsLayoutIMP = void (*)(__unsafe_unretained id, SEL);

constexpr size_t kMaxTraitReturnPCs = 8;
constexpr size_t kMaxRejectedReturnPCs = 24;

SetNeedsLayoutIMP originalSetNeedsLayout;
void *uikitImageBase;
std::atomic<bool> calibrated{false};
bool calibrationValid;
void *traitReturnPCs[kMaxTraitReturnPCs];
size_t traitReturnPCCount;

enum class CalibrationPhase {
    None,
    Direct,
    Negative,
    Trait,
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

bool TraitLayoutFixEnabled(void) {
    static const bool enabled = [] {
        const char *value = getenv("LC32_TRAIT_LAYOUT_FIX");
        const bool on = !value || strcmp(value, "0") != 0;
        if(!on) {
            fprintf(stderr,
                "LC32: legacy trait layout fix disabled (LC32_TRAIT_LAYOUT_FIX=0)\n");
        }
        return on;
    }();
    return enabled;
}

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

// Main-thread only: avoids walking the superclass chain and taking the ObjC
// associated-object lock (via -isGuestClass) on every UIView -setNeedsLayout.
// HasCustomLayout() stays uncached so late overrides on guest views are seen.
bool IsGuestViewClassOnMainThread(Class cls) {
    if(!cls) return false;
    static auto &cache = *new std::unordered_map<Class, bool>();
    auto it = cache.find(cls);
    if(it != cache.end()) return it->second;
    const bool guest = IsGuestViewClass(cls);
    cache.emplace(cls, guest);
    return guest;
}

bool IsEligibleGuestRendererClassOnMainThread(Class cls) {
    return IsGuestViewClassOnMainThread(cls) && HasCustomLayout(cls);
}

CALayer *NativeViewLayer(__unsafe_unretained UIView *view) {
    using LayerGetter = CALayer *(*)(__unsafe_unretained id, SEL);
    static LayerGetter getter = reinterpret_cast<LayerGetter>(
        class_getMethodImplementation(UIView.class, @selector(layer)));
    return view ? getter(view, @selector(layer)) : nil;
}

bool IsEAGLBackedView(__unsafe_unretained UIView *view) {
    static Class eaglLayerClass = NSClassFromString(@"CAEAGLLayer");
    return eaglLayerClass &&
        [NativeViewLayer(view) isKindOfClass:eaglLayerClass];
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
    if(calibrating) return;
    if(calibrated.load(std::memory_order_relaxed)) return;

    size_t rejectedCount = 0;
    {
        CalibrationGuard guard;
        @autoreleasepool {
            // Attach a throwaway native view to both a superview and a
            // controller so UIKit's legacy trait invalidation takes its
            // setNeedsLayout path across pre-iOS-17 effective SDKs, without
            // touching any window or scene state.
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

            for(size_t i = 0; i < calibrationRejectedCount; ++i) {
                if(AddressInUIKit(calibrationRejected[i])) {
                    ++rejectedCount;
                }
            }

            // Only enable suppression if a direct send lands straight in our
            // hook from our own image (no shared UIKit/accessibility trampoline
            // rewriting every caller's return PC).
            if(calibrationDirectReturnPC &&
                    !calibrationRejectedOverflow &&
                    !AddressInUIKit(calibrationDirectReturnPC)) {
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
                calibrationValid = accepted > 0;
            }
        }
    }

    calibrated.store(true, std::memory_order_release);
    fprintf(stderr,
        "LC32: legacy trait layout calibration %s (accepted=%zu, rejected=%zu)\n",
        calibrationValid ? "valid" : "invalid",
        traitReturnPCCount, rejectedCount);
}

void LogSuppressedOnce(__unsafe_unretained UIView *view) {
    static std::atomic<bool> logged{false};
    if(!logged.exchange(true, std::memory_order_relaxed)) {
        fprintf(stderr,
            "LC32: ignoring trait-invalidation setNeedsLayout on %s\n",
            object_getClassName(view));
    }
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
    if(LC32GetGuestExecutableSDKVersion() < 0x80000 &&
            pthread_main_np() &&
            IsEligibleGuestRendererClassOnMainThread(object_getClass(self)) &&
            IsEAGLBackedView(self)) {
        if(!TraitLayoutFixEnabled()) {
            originalSetNeedsLayout(self, selector);
            return;
        }
        if(!calibrated.load(std::memory_order_acquire)) {
            EnsureCalibratedOnMainThread();
        }
        if(calibrated.load(std::memory_order_acquire) &&
                calibrationValid &&
                ListContainsPC(traitReturnPCs, traitReturnPCCount, returnPC)) {
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
}

@end
