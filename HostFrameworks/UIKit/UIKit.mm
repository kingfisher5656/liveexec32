@import Darwin;
@import QuartzCore;
@import UIKit;
#import <objc/runtime.h>
#include "bridge.h"
#include "crash_exception.h"
#include "LiveExec32Shared.h"
#include "LC32LegacyCanvas.h"
#include "LC32GameProfile.h"
#include "LC32LegacyRotation.h"
#include "LC32NativeViewGeometry.h"
#include "LC32ClassicPresentation.h"
#include "../CoreGraphics/LC32CoreGraphicsHost.h"

#include <atomic>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void LC32FlushHostThreadTransactions() {
    [CATransaction flush];
}

typedef NS_ENUM(NSUInteger, LC32LegacyIPadGeometryMode) {
    /* Pre-root-controller applications and some early fixed-surface engines
     * keep a portrait iPad drawable and rely on UIKit's compositor turn. */
    LC32LegacyIPadGeometryModePreservePortraitCanvas,
    /* Applications using UIWindow.rootViewController expect UIKit to resize
     * the controller hierarchy into the requested interface orientation. */
    LC32LegacyIPadGeometryModeReflowRootController,
    /* Some legacy landscape phone applications deliberately render through
     * a portrait 320x480 surface and rotate in their projection matrix. Keep
     * that drawable contract and turn only the native wrapper. */
    LC32LegacyIPadGeometryModePreservePhonePortraitCanvas,
    /* Some 568-point phone applications advertise tall launch art but retain
     * a 480x320 game view. Keep that already-landscape drawable centered at
     * 1x inside the modern scene. */
    LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas,
};

@interface LC32LegacyIPadContainerController : UIViewController {
@private
    UIViewController *_guestContentController;
    UIView *_guestContentView;
    UIView *_canvasView;
    CGRect _canonicalGuestBounds;
    LC32LegacyIPadGeometryMode _geometryMode;
    BOOL _fittingGuestContent;
    BOOL _guestLayoutPending;
    NSUInteger _guestContentGeneration;
    UIInterfaceOrientation _layoutLandscapeSide;
    UIWindowScene *_observedScene;
    /* Landscape bounds/center the guest asked for through a portrait
     * root frame (see -applyGuestRootFrame:); zero size when unset. */
    CGRect _guestRootLayout;
}
@property(nonatomic, readonly) UIViewController *guestContentController;
@property(nonatomic, readonly) LC32LegacyIPadGeometryMode geometryMode;
- (instancetype)initWithGuestContentController:
    (UIViewController *)controller
                          geometryMode:(LC32LegacyIPadGeometryMode)mode;
- (void)setGuestContentController:(UIViewController *)controller
                      geometryMode:(LC32LegacyIPadGeometryMode)mode;
- (void)fitGuestContentForViewport:(CGRect)viewport
                   hostOrientation:(UIInterfaceOrientation)orientation;
- (void)scheduleGuestLayout;
- (void)fitGuestCanvasSiblings;
- (BOOL)applyGuestRootFrame:(CGRect)frame;
- (BOOL)isGuestContentView:(UIView *)view;
- (BOOL)restoreGuestContentView:(UIView *)view;
@end

/*
 * UIWindow.rootViewController did not exist before iOS 4.  Main-nib games
 * from that era commonly archive their drawable view directly under the
 * window and leave the root controller nil.  Modern UIKit rejects such a
 * window at the end of application launch, so give the host a controller
 * whose inert view sits behind the untouched guest hierarchy.  The guest
 * rootViewController accessor deliberately hides this implementation detail.
 */
@interface LC32LegacyWindowRootController : UIViewController
@end

@interface LC32LegacyRendererAutoresizingState : NSObject
@property(nonatomic) UIViewAutoresizing originalMask;
@property(nonatomic) BOOL yielded;
@end

@implementation LC32LegacyRendererAutoresizingState
@end

/* Refits a portrait-hosted window when its scene settles portrait; the
 * window itself keeps its 320x480 size, so no layout pass notices. */
@interface LC32PortraitHostGeometryObserver : NSObject
@property(nonatomic, assign) UIWindow *window;
@end

/* Refits a full-screen rootless window (LC32FitFullScreenRootlessWindow) when
 * its scene turns; the window keeps its portrait size, so no layout pass
 * notices. */
@interface LC32FullScreenRootlessGeometryObserver : NSObject
@property(nonatomic, assign) UIWindow *window;
@end

/*
symbol = r0 + r1 << 32
r0 = r2
r1 = r3
r2 = sp
r3 = sp+4
...
*/

namespace {

const void *LC32LegacyOrientationMaskKey =
    &LC32LegacyOrientationMaskKey;
const void *LC32GuestSupportedOrientationsIMPKey =
    &LC32GuestSupportedOrientationsIMPKey;
const void *LC32GuestPreferredOrientationIMPKey =
    &LC32GuestPreferredOrientationIMPKey;
const void *LC32SettledLegacyOrientationKey =
    &LC32SettledLegacyOrientationKey;
const void *LC32HideLegacyDirectGuestWindowRootKey =
    &LC32HideLegacyDirectGuestWindowRootKey;
const void *LC32LegacyDirectWindowSublayerTransformKey =
    &LC32LegacyDirectWindowSublayerTransformKey;
const void *LC32LegacyDirectWindowAppliedSublayerTransformKey =
    &LC32LegacyDirectWindowAppliedSublayerTransformKey;
const void *LC32LegacyWindowLayersLayoutPendingKey =
    &LC32LegacyWindowLayersLayoutPendingKey;
const void *LC32LegacyRootlessWindowPlacementKey =
    &LC32LegacyRootlessWindowPlacementKey;
const void *LC32LegacyRootlessRendererAutoresizingKey =
    &LC32LegacyRootlessRendererAutoresizingKey;
const void *LC32LegacyRootlessRendererAutoresizingStateKey =
    &LC32LegacyRootlessRendererAutoresizingStateKey;
const void *LC32LegacyOverlayLayoutPendingKey =
    &LC32LegacyOverlayLayoutPendingKey;
const void *LC32LegacyRootWindowGeometryKey =
    &LC32LegacyRootWindowGeometryKey;

struct LC32GuestUIKitPolicy {
    UIInterfaceOrientationMask declaredOrientations;
    UIInterfaceOrientation preferredOrientation;
    bool statusBarHidden;
    bool constrainsControllerOrientations;
    bool usesLegacyInitialOrientation;
};

const LC32GuestUIKitPolicy& LC32GuestInterfacePolicy(void);
UIInterfaceOrientation LC32FirstOrientationInMask(
    UIInterfaceOrientationMask mask);
id LC32ObjectProperty(id object, const char *name);

std::atomic<NSInteger> LC32LegacyRequestedOrientation{
    UIInterfaceOrientationUnknown};
// See LC32WidenLegacyLandscapeSides.
std::atomic<bool> LC32LegacyLandscapeSidesWidened{false};
thread_local bool LC32SuppressGuestOrientationQuery = false;
thread_local bool LC32AllowGuestOrientationQuery = false;
// A registered guest thread is not necessarily ready for renderer callbacks.
// Legacy engines can show their window before initializing the screen manager,
// sometimes in a zero-delay selector scheduled by the launch delegate.
std::atomic<bool> LC32GuestOrientationStartupComplete{true};
u32 LC32GuestOrientationStartupCallbackDepth = 0;

bool LC32CanQueryGuestOrientation(void) {
    return LC32GuestOrientationStartupComplete.load(std::memory_order_acquire) &&
        !LC32SuppressGuestOrientationQuery &&
        Dynarmic_guest_thread_is_registered();
}

class LC32GuestOrientationQueryScope {
public:
    LC32GuestOrientationQueryScope()
        : previous_(LC32AllowGuestOrientationQuery) {
        LC32AllowGuestOrientationQuery = true;
    }

    ~LC32GuestOrientationQueryScope() {
        LC32AllowGuestOrientationQuery = previous_;
    }

private:
    bool previous_;
};

} // namespace

/*
 * Do not replace these calls with ordinary Objective-C messages. A view can
 * be an instance of a synthesized guest subclass whose override is backed by
 * LC32InvokeGuestSelector. UIKit invokes the compatibility layout code from
 * native scene callbacks, where dynamically dispatching into ARM32 guest code
 * is unsafe (and may run on a host thread that is not registered for guest
 * execution). Calling UIView's typed IMP directly deliberately applies only
 * the native base implementation while preserving the arm64 aggregate ABI.
 */
CGRect LC32NativeViewBounds(UIView *view) {
    using Getter = CGRect (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(bounds)));
    return view ? getter(view, @selector(bounds)) : CGRectZero;
}

static UIView *LC32NativeViewSuperview(UIView *view) {
    using Getter = UIView *(*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(superview)));
    return view ? getter(view, @selector(superview)) : nil;
}

static NSArray<UIView *> *LC32NativeViewSubviews(UIView *view) {
    using Getter = NSArray<UIView *> *(*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(subviews)));
    return view ? getter(view, @selector(subviews)) : nil;
}

static UIWindow *LC32NativeViewWindow(UIView *view) {
    using Getter = UIWindow *(*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(window)));
    return view ? getter(view, @selector(window)) : nil;
}

static BOOL LC32NativeViewHidden(UIView *view) {
    using Getter = BOOL (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(isHidden)));
    return view ? getter(view, @selector(isHidden)) : NO;
}

CALayer *LC32NativeViewLayer(UIView *view) {
    using Getter = CALayer *(*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(layer)));
    return view ? getter(view, @selector(layer)) : nil;
}

static UIApplicationState LC32NativeApplicationState(void) {
    UIApplication *application = UIApplication.sharedApplication;
    using Getter = UIApplicationState (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(
            UIApplication.class, @selector(applicationState)));
    return application
        ? getter(application, @selector(applicationState))
        : UIApplicationStateInactive;
}

CGAffineTransform LC32NativeViewTransform(UIView *view) {
    using Getter = CGAffineTransform (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class,
                                      @selector(transform)));
    return view ? getter(view, @selector(transform))
                : CGAffineTransformIdentity;
}

CGPoint LC32NativeViewCenter(UIView *view) {
    using Getter = CGPoint (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(center)));
    return view ? getter(view, @selector(center)) : CGPointZero;
}

void LC32NativeSetViewBounds(UIView *view, CGRect bounds) {
    using Setter = void (*)(id, SEL, CGRect);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIView.class, @selector(setBounds:)));
    if(view) setter(view, @selector(setBounds:), bounds);
}

void LC32NativeSetViewCenter(UIView *view, CGPoint center) {
    using Setter = void (*)(id, SEL, CGPoint);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIView.class, @selector(setCenter:)));
    if(view) setter(view, @selector(setCenter:), center);
}

void LC32NativeSetViewTransform(
        UIView *view, CGAffineTransform transform) {
    using Setter = void (*)(id, SEL, CGAffineTransform);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIView.class,
                                      @selector(setTransform:)));
    if(view) setter(view, @selector(setTransform:), transform);
}

namespace {

void LC32NativeSetViewAutoresizingMask(
        UIView *view, UIViewAutoresizing mask) {
    using Setter = void (*)(id, SEL, UIViewAutoresizing);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(
            UIView.class, @selector(setAutoresizingMask:)));
    if(view) setter(view, @selector(setAutoresizingMask:), mask);
}

UIViewAutoresizing LC32NativeViewAutoresizingMask(UIView *view) {
    using Getter = UIViewAutoresizing (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class,
            @selector(autoresizingMask)));
    return view ? getter(view, @selector(autoresizingMask))
                : UIViewAutoresizingNone;
}

void LC32NativeSetViewNeedsLayout(UIView *view) {
    using Setter = void (*)(id, SEL);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIView.class,
                                      @selector(setNeedsLayout)));
    if(view) setter(view, @selector(setNeedsLayout));
}

void LC32NativeLayoutViewIfNeeded(UIView *view) {
    using Layout = void (*)(id, SEL);
    static Layout layout = reinterpret_cast<Layout>(
        class_getMethodImplementation(UIView.class,
                                      @selector(layoutIfNeeded)));
    if(view) layout(view, @selector(layoutIfNeeded));
}

void LC32NativeSendSubviewToBack(UIView *view, UIView *subview) {
    using SendSubviewToBack = void (*)(id, SEL, UIView *);
    static SendSubviewToBack sendSubviewToBack =
        reinterpret_cast<SendSubviewToBack>(
            class_getMethodImplementation(
                UIView.class, @selector(sendSubviewToBack:)));
    if(view && subview) {
        sendSubviewToBack(view, @selector(sendSubviewToBack:), subview);
    }
}

UIInterfaceOrientationMask LC32CachedGuestOrientationMask(
        UIViewController *controller) {
    NSNumber *cached = controller ? objc_getAssociatedObject(
        controller, LC32LegacyOrientationMaskKey) : nil;
    return cached ? (UIInterfaceOrientationMask)cached.unsignedLongLongValue
                  : LC32GuestInterfacePolicy().declaredOrientations;
}

UIInterfaceOrientation LC32InterfaceOrientationFromName(NSString *name) {
    if([name isEqualToString:@"UIInterfaceOrientationPortrait"]) {
        return UIInterfaceOrientationPortrait;
    }
    if([name isEqualToString:@"UIInterfaceOrientationPortraitUpsideDown"]) {
        return UIInterfaceOrientationPortraitUpsideDown;
    }
    if([name isEqualToString:@"UIInterfaceOrientationLandscapeLeft"]) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    if([name isEqualToString:@"UIInterfaceOrientationLandscapeRight"]) {
        return UIInterfaceOrientationLandscapeRight;
    }
    return UIInterfaceOrientationUnknown;
}

UIInterfaceOrientationMask LC32MaskForInterfaceOrientation(
        UIInterfaceOrientation orientation) {
    switch(orientation) {
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationPortraitUpsideDown:
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return (UIInterfaceOrientationMask)1 << orientation;
        default:
            return 0;
    }
}

UIInterfaceOrientationMask LC32ConstrainGuestOrientationMask(
        UIInterfaceOrientationMask mask) {
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    if(!mask) return policy.declaredOrientations;
    if(!policy.constrainsControllerOrientations) return mask;

    /* A real supported-orientations array is an outer constraint on every
     * controller. UIInterfaceOrientation is only an initial-side hint and is
     * handled later, where the active window scene is known. */
    const UIInterfaceOrientationMask constrained =
        mask & policy.declaredOrientations;
    return constrained ? constrained : policy.declaredOrientations;
}

const LC32GuestUIKitPolicy& LC32GuestInterfacePolicy(void) {
    static LC32GuestUIKitPolicy policy = {
        UIInterfaceOrientationMaskPortrait,
        UIInterfaceOrientationPortrait,
        false,
        false,
        false,
    };
    /* UIKit can query native controller policy while the shim dylib is
     * loading. Do not permanently cache the fallback until LC32RunGuest has
     * published the selected guest executable. */
    const char *guestExecutable = getenv("LC32_GUEST_EXECUTABLE");
    if(!guestExecutable || !guestExecutable[0]) return policy;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSString stringWithUTF8String:
            getenv("LC32_GUEST_EXECUTABLE")];
        NSBundle *bundle = [NSBundle bundleWithPath:
            path.stringByDeletingLastPathComponent];
        NSDictionary *info = bundle.infoDictionary;
        if(!info) return;

        const bool usesIPadPolicy = LC32BundleNeedsLegacyIPadCanvas(
            bundle, LC32GetGuestExecutableSDKVersion());
        NSArray *orientationNames = usesIPadPolicy
            ? info[@"UISupportedInterfaceOrientations~ipad"] : nil;
        if(![orientationNames isKindOfClass:NSArray.class]) {
            orientationNames = info[@"UISupportedInterfaceOrientations"];
        }
        /* An empty array (Zenonia 5) declares nothing; iOS then used the
         * legacy UIInterfaceOrientation key, as for a missing one. */
        const bool hasSupportedOrientationArray =
            [orientationNames isKindOfClass:NSArray.class] &&
            [orientationNames count] != 0;

        UIInterfaceOrientationMask declared = 0;
        for(id value in orientationNames) {
            if(![value isKindOfClass:NSString.class]) continue;
            declared |= LC32MaskForInterfaceOrientation(
                LC32InterfaceOrientationFromName(value));
        }

        const UIInterfaceOrientation preferred =
            LC32InterfaceOrientationFromName(info[@"UIInterfaceOrientation"]);
        const UIInterfaceOrientationMask preferredMask =
            LC32MaskForInterfaceOrientation(preferred);
        const bool usesLegacyInitialOrientation =
            !hasSupportedOrientationArray && preferredMask;
        if(!declared && usesLegacyInitialOrientation) {
            declared = preferredMask;
        }
        if(!declared) declared = UIInterfaceOrientationMaskPortrait;

        policy.declaredOrientations = declared;
        policy.preferredOrientation =
            preferredMask & declared
            ? preferred
            : UIInterfaceOrientationUnknown;
        policy.statusBarHidden = [info[@"UIStatusBarHidden"] boolValue];
        policy.constrainsControllerOrientations =
            hasSupportedOrientationArray;
        policy.usesLegacyInitialOrientation =
            usesLegacyInitialOrientation;
    });
    return policy;
}

void LC32CacheSettledLegacyOrientation(
        id object, UIInterfaceOrientation orientation) {
    if(!object || !LC32GuestInterfacePolicy().usesLegacyInitialOrientation ||
            !LC32MaskForInterfaceOrientation(orientation)) {
        return;
    }
    objc_setAssociatedObject(object, LC32SettledLegacyOrientationKey,
        @((NSInteger)orientation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UIInterfaceOrientation LC32SettledLegacyOrientation(
        id object, UIInterfaceOrientationMask mask) {
    if(!LC32GuestInterfacePolicy().usesLegacyInitialOrientation) {
        return UIInterfaceOrientationUnknown;
    }
    NSNumber *cached = object ? objc_getAssociatedObject(
        object, LC32SettledLegacyOrientationKey) : nil;
    const UIInterfaceOrientation settled = cached
        ? (UIInterfaceOrientation)cached.integerValue
        : UIInterfaceOrientationUnknown;
    return LC32MaskForInterfaceOrientation(settled) & mask
        ? settled : UIInterfaceOrientationUnknown;
}

IMP LC32GuestOrientationImplementation(id object, const void *key) {
    for(Class cls = object_getClass(object); cls;
            cls = class_getSuperclass(cls)) {
        NSNumber *value = objc_getAssociatedObject((id)cls, key);
        if(value) return reinterpret_cast<IMP>(
            static_cast<uintptr_t>(value.unsignedLongLongValue));
        if(cls == UIViewController.class) break;
    }
    return nullptr;
}

UIInterfaceOrientationMask LC32GuestSupportedInterfaceOrientations(
        UIViewController *controller, SEL selector) {
    NSNumber *cached = objc_getAssociatedObject(
        controller, LC32LegacyOrientationMaskKey);
    if(!LC32AllowGuestOrientationQuery || !LC32CanQueryGuestOrientation()) {
        return cached
            ? (UIInterfaceOrientationMask)cached.unsignedLongLongValue
            : LC32GuestInterfacePolicy().declaredOrientations;
    }

    using SupportedOrientations =
        UIInterfaceOrientationMask (*)(id, SEL);
    SupportedOrientations original =
        reinterpret_cast<SupportedOrientations>(
            LC32GuestOrientationImplementation(
                controller, LC32GuestSupportedOrientationsIMPKey));
    UIInterfaceOrientationMask mask = original
        ? original(controller, selector) : 0;
    mask = LC32ConstrainGuestOrientationMask(mask);
    objc_setAssociatedObject(controller, LC32LegacyOrientationMaskKey,
        @(mask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return mask;
}

UIInterfaceOrientationMask LC32ControllerSupportedInterfaceOrientations(
        UIViewController *controller) {
    using SupportedOrientations =
        UIInterfaceOrientationMask (*)(id, SEL);
    UIInterfaceOrientationMask mask = controller
        ? reinterpret_cast<SupportedOrientations>(objc_msgSend)(
            controller, @selector(supportedInterfaceOrientations))
        : 0;
    mask = LC32ConstrainGuestOrientationMask(mask);
    if(controller) {
        objc_setAssociatedObject(controller, LC32LegacyOrientationMaskKey,
            @(mask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return mask;
}

UIInterfaceOrientation LC32GuestPreferredInterfaceOrientation(
        UIViewController *controller, SEL selector) {
    using PreferredOrientation = UIInterfaceOrientation (*)(id, SEL);
    PreferredOrientation original =
        reinterpret_cast<PreferredOrientation>(
            LC32GuestOrientationImplementation(
                controller, LC32GuestPreferredOrientationIMPKey));
    const UIInterfaceOrientation guestPreferred =
        original && LC32AllowGuestOrientationQuery &&
                LC32CanQueryGuestOrientation()
            ? original(controller, selector)
            : UIInterfaceOrientationUnknown;

    const UIInterfaceOrientationMask mask =
        LC32ControllerSupportedInterfaceOrientations(controller);
    const UIInterfaceOrientation requested = (UIInterfaceOrientation)
        LC32LegacyRequestedOrientation.load(std::memory_order_relaxed);
    if(LC32MaskForInterfaceOrientation(requested) & mask) {
        return requested;
    }
    const UIInterfaceOrientation settled =
        LC32SettledLegacyOrientation(controller, mask);
    if(settled != UIInterfaceOrientationUnknown) {
        return settled;
    }
    if(LC32MaskForInterfaceOrientation(guestPreferred) & mask) {
        return guestPreferred;
    }
    const UIInterfaceOrientation bundlePreferred =
        LC32GuestInterfacePolicy().preferredOrientation;
    if(LC32MaskForInterfaceOrientation(bundlePreferred) & mask) {
        return bundlePreferred;
    }
    return LC32FirstOrientationInMask(mask);
}

Method LC32ClassOwnMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = nullptr;
    for(unsigned int index = 0; index < count; index++) {
        if(method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

struct LC32GuestLoadViewFrame {
    __unsafe_unretained UIViewController *controller;
    LC32GuestLoadViewFrame *previous;
};

thread_local LC32GuestLoadViewFrame *LC32GuestLoadViewFrames = nullptr;

bool LC32GuestLoadViewIsActive(UIViewController *controller) {
    for(LC32GuestLoadViewFrame *frame = LC32GuestLoadViewFrames;
            frame; frame = frame->previous) {
        if(frame->controller == controller) return true;
    }
    return false;
}

class LC32GuestLoadViewScope {
public:
    explicit LC32GuestLoadViewScope(UIViewController *controller)
        : frame{controller, LC32GuestLoadViewFrames} {
        LC32GuestLoadViewFrames = &frame;
    }

    ~LC32GuestLoadViewScope() {
        LC32GuestLoadViewFrames = frame.previous;
    }

private:
    LC32GuestLoadViewFrame frame;
};

void LC32GuestLoadView(UIViewController *controller, SEL selector) {
    if(LC32GuestLoadViewIsActive(controller)) {
        /* LC32InvokeHostSelector normally intercepts the reentrant -view read
         * before native UIKit reaches this callback. Keep a no-op backstop for
         * any other same-controller native load path; installing a generic
         * UIView here would make the legacy override believe loading finished. */
        return;
    }

    LC32GuestLoadViewScope scope(controller);
    (void)LC32InvokeGuestSelector(
        controller, selector, 0, 0, 0, 0, 0, 0);
}

void LC32GuestWillRotate(UIViewController *controller, SEL selector,
        UIInterfaceOrientation orientation, NSTimeInterval duration) {
    if(!LC32CanQueryGuestOrientation()) return;

    // A typed native IMP receives duration in d0. Darwin ARMv7 uses four-byte
    // argument alignment here: self/cmd/orientation occupy r0-r2, the double's
    // low word is r3, and its high word is the first stack argument. Do not
    // insert the eight-byte alignment padding used by generic AAPCS examples.
    // Verified with Clang's armv7-apple-ios Objective-C caller and callee.
    static_assert(sizeof(duration) == sizeof(u64));
    u64 durationBits;
    memcpy(&durationBits, &duration, sizeof(durationBits));
    u32 arguments[] = {
        [controller guest_self],
        guest_sel_registerName(sel_getName(selector)),
        static_cast<u32>(orientation),
        static_cast<u32>(durationBits),
        static_cast<u32>(durationBits >> 32),
    };
    (void)guest_objc_msgSend(sizeof(arguments) / sizeof(*arguments), arguments);
}

bool LC32NativeViewIfLoaded(UIViewController *controller, UIView **view) {
    if(!view) return false;
    using Getter = UIView *(*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(
            UIViewController.class, @selector(viewIfLoaded)));
    *view = controller ? getter(controller, @selector(viewIfLoaded)) : nil;
    return true;
}

bool LC32ClassIsUIViewController(Class cls) {
    const Class viewControllerClass = UIViewController.class;
    for(Class current = cls; current;
            current = class_getSuperclass(current)) {
        if(current == viewControllerClass) return true;
    }
    return false;
}

bool LC32GuestClassHierarchyDefinesSelector(Class cls, SEL selector) {
    for(Class current = cls; current && current != UIViewController.class;
            current = class_getSuperclass(current)) {
        if(LC32ClassOwnMethod(current, selector)) return true;
        /* The class currently being registered is not marked until after
         * objc_registerClassPair. Registered guest superclasses are marked,
         * while the first native superclass terminates this search. */
        if(current != cls && ![(id)current isGuestClass]) break;
    }
    return false;
}

UIInterfaceOrientation LC32FirstOrientationInMask(
        UIInterfaceOrientationMask mask) {
    static const UIInterfaceOrientation order[] = {
        UIInterfaceOrientationPortrait,
        UIInterfaceOrientationLandscapeLeft,
        UIInterfaceOrientationLandscapeRight,
        UIInterfaceOrientationPortraitUpsideDown,
    };
    for(UIInterfaceOrientation orientation : order) {
        if(mask & LC32MaskForInterfaceOrientation(orientation)) {
            return orientation;
        }
    }
    return UIInterfaceOrientationPortrait;
}

UIInterfaceOrientationMask LC32LegacySupportedInterfaceOrientations(
        UIViewController *controller, SEL) {
    if(!LC32AllowGuestOrientationQuery || !LC32CanQueryGuestOrientation()) {
        NSNumber *cached = objc_getAssociatedObject(
            controller, LC32LegacyOrientationMaskKey);
        return cached ? (UIInterfaceOrientationMask)cached.unsignedLongLongValue
                      : LC32GuestInterfacePolicy().declaredOrientations;
    }

    UIInterfaceOrientationMask mask = 0;
    const SEL legacySelector =
        @selector(shouldAutorotateToInterfaceOrientation:);
    using LegacyAutorotation = BOOL (*)(id, SEL, UIInterfaceOrientation);
    LegacyAutorotation shouldAutorotate =
        reinterpret_cast<LegacyAutorotation>(objc_msgSend);
    static const UIInterfaceOrientation orientations[] = {
        UIInterfaceOrientationPortrait,
        UIInterfaceOrientationPortraitUpsideDown,
        UIInterfaceOrientationLandscapeLeft,
        UIInterfaceOrientationLandscapeRight,
    };
    for(UIInterfaceOrientation orientation : orientations) {
        if(shouldAutorotate(controller, legacySelector, orientation)) {
            mask |= LC32MaskForInterfaceOrientation(orientation);
        }
    }
    mask = LC32ConstrainGuestOrientationMask(mask);
    objc_setAssociatedObject(controller, LC32LegacyOrientationMaskKey,
        @(mask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return mask;
}

UIInterfaceOrientation LC32LegacyPreferredInterfaceOrientation(
        UIViewController *controller, SEL) {
    const UIInterfaceOrientationMask mask =
        LC32ControllerSupportedInterfaceOrientations(controller);
    const UIInterfaceOrientation requested = (UIInterfaceOrientation)
        LC32LegacyRequestedOrientation.load(std::memory_order_relaxed);
    if(LC32MaskForInterfaceOrientation(requested) & mask) return requested;
    const UIInterfaceOrientation settled =
        LC32SettledLegacyOrientation(controller, mask);
    if(settled != UIInterfaceOrientationUnknown) return settled;
    const UIInterfaceOrientation declared =
        LC32GuestInterfacePolicy().preferredOrientation;
    if(LC32MaskForInterfaceOrientation(declared) & mask) return declared;
    return LC32FirstOrientationInMask(mask);
}

BOOL LC32LegacyPrefersStatusBarHidden(UIViewController *, SEL) {
    return LC32GuestInterfacePolicy().statusBarHidden;
}

void LC32ScaleLegacyIPadWindow(UIWindow *window);
void LC32ApplyLegacyWindowPolicy(UIWindow *window);
bool LC32InstallLegacyDirectSubviewRoot(UIWindow *window);
CGRect LC32WindowSceneBounds(UIWindow *window);
bool LC32UsesClassicFullScreenViewport(UIWindow *window);
CGRect LC32LegacyViewportInView(UIWindow *window, UIView *view);
UIInterfaceOrientation LC32WindowSceneOrientation(
    UIWindow *window, CGRect sceneBounds);
UIInterfaceOrientationMask LC32SupportedOrientationsForController(
    UIViewController *controller);
bool LC32ObjectUsesGuestClass(id object);
UIViewController *LC32NativeWindowRootViewController(UIWindow *window);
void LC32NativeSetWindowRootViewController(
    UIWindow *window, UIViewController *controller);
void LC32NativeSetWindowFrame(UIWindow *window, CGRect frame);
UIViewController *LC32GuestWindowRootViewController(UIWindow *window);
void LC32InstallGuestWindowRootViewController(
    UIWindow *window, UIViewController *controller,
    LC32LegacyIPadGeometryMode geometryMode);
UIInterfaceOrientation LC32LegacyTargetOrientation(
    UIViewController *controller);
bool LC32WindowNeedsLegacyPhoneCanvas(
    UIWindow *window, UIViewController *controller);
bool LC32WindowNeedsImmediateLegacyPhoneCanvas(
    UIWindow *window, UIViewController *controller);
bool LC32FitLegacyDirectWindowLayers(UIWindow *window);
void LC32RestoreRootlessRendererAutoresizing(UIWindow *window);
bool LC32TransformNearlyEquals(
    CGAffineTransform left, CGAffineTransform right);
UIInterfaceOrientation LC32LegacyRootWindowGeometry(
    UIView *view, bool requireGuestLandscapeBounds,
    UIWindow *installingWindow = nil, UIViewController *installingRoot = nil);
void LC32FitLegacyControllerRoot(UIView *view);

bool LC32GeometryModePreservesPhoneCanvas(
        LC32LegacyIPadGeometryMode geometryMode) {
    return geometryMode ==
            LC32LegacyIPadGeometryModePreservePhonePortraitCanvas ||
        geometryMode ==
            LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas;
}

LC32LegacyIPadContainerController *LC32LegacyContainerForWindow(
        UIWindow *window) {
    UIViewController *root = LC32NativeWindowRootViewController(window);
    return [root isKindOfClass:LC32LegacyIPadContainerController.class]
        ? (LC32LegacyIPadContainerController *)root : nil;
}

struct LC32LegacyCanvasPolicy {
    LC32LegacyIPadCanvasKind kind;
    bool usesFixedLandscapeIPadCanvas;
    bool usesFixedLandscapePhoneCanvas;
    bool mayRetainLegacyLandscapePhoneCanvas;
    bool usesFixedPortraitPhoneCanvas;
    /* Long edge of the fixed phone canvas: 480, or 568 for tall-art apps. */
    CGFloat phoneCanvasLongEdge;
    /* The host may composite a fixed phone canvas: always on an iPhone, and
     * on an iPad for phone-only guests, which iOS ran in a phone-sized
     * compatibility screen there (Tapsonic). Universal guests keep their
     * native iPad layout. */
    bool phoneCanvasHost;
};

const LC32LegacyCanvasPolicy& LC32GuestLegacyCanvasPolicy(void) {
    static LC32LegacyCanvasPolicy result = {
        LC32LegacyIPadCanvasNone,
        false,
        false,
        false,
        false,
        480,
        false,
    };
    const char *guestExecutable = getenv("LC32_GUEST_EXECUTABLE");
    /* UIKit can create internal windows while the shim dylib is loading.
     * Do not consume the cache until LC32RunGuest has published the guest. */
    if(!guestExecutable || !guestExecutable[0]) return result;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSString stringWithUTF8String:
            getenv("LC32_GUEST_EXECUTABLE")];
        NSBundle *bundle = [NSBundle bundleWithPath:
            path.stringByDeletingLastPathComponent];
        result.kind = LC32BundleLegacyIPadCanvasKind(
            bundle, LC32GetGuestExecutableSDKVersion());
        result.usesFixedLandscapeIPadCanvas =
            LC32BundleUsesFixedLandscapeIPadCanvas(bundle, result.kind);
        const LC32SupportedDeviceFamilies families =
            LC32BundleSupportedDeviceFamilies(bundle);
        const bool phoneHost =
            UIDevice.currentDevice.userInterfaceIdiom ==
                UIUserInterfaceIdiomPhone ||
            (families.supportsPhone && !families.supportsPad);
        result.phoneCanvasHost = phoneHost;
        result.usesFixedLandscapePhoneCanvas =
            LC32BundleUsesFixedLandscapePhoneCanvasForHost(
                bundle, LC32GetGuestExecutableSDKVersion(), phoneHost);
        result.mayRetainLegacyLandscapePhoneCanvas =
            LC32BundleMayRetainLegacyLandscapePhoneCanvas(
                bundle, LC32GetGuestExecutableSDKVersion());
        if(!result.usesFixedLandscapePhoneCanvas &&
                (LC32BundleUsesFixedLandscapeTallPhoneCanvasForHost(
                    bundle, LC32GetGuestExecutableSDKVersion(), phoneHost) ||
                 (LC32NativeLegacyRotationEnabled() &&
                  LC32GameProfileTallPhoneCanvas() &&
                  LC32BundleUsesNativeTallLandscapePhoneCanvas(bundle,
                      LC32GetGuestExecutableSDKVersion(), phoneHost)))) {
            result.usesFixedLandscapePhoneCanvas = true;
            result.phoneCanvasLongEdge = 568;
        }
        result.usesFixedPortraitPhoneCanvas =
            result.kind == LC32LegacyIPadCanvasNone &&
            !result.usesFixedLandscapePhoneCanvas &&
            LC32BundleUsesFixedPortraitPhoneCanvasForHost(
                bundle, LC32GetGuestExecutableSDKVersion(), phoneHost);
    });
    return result;
}

CGFloat LC32GuestPhoneCanvasLongEdge(void) {
    return LC32GuestLegacyCanvasPolicy().phoneCanvasLongEdge;
}

LC32LegacyIPadCanvasKind LC32GuestLegacyIPadCanvasKind(void) {
    return LC32GuestLegacyCanvasPolicy().kind;
}

bool LC32GuestNeedsLegacyIPadCanvas(void) {
    return LC32GuestLegacyIPadCanvasKind() != LC32LegacyIPadCanvasNone;
}

bool LC32GuestUsesFixedLandscapeIPadCanvas(void) {
    return LC32GuestLegacyCanvasPolicy().usesFixedLandscapeIPadCanvas;
}

bool LC32GuestUsesFixedLandscapePhoneCanvas(void) {
    return LC32GuestLegacyCanvasPolicy()
        .usesFixedLandscapePhoneCanvas;
}

/* Only with native legacy rotation (device: LiveContainer spoofs the guest's
 * SDK) on a phone canvas host; the older full compatibility path keeps its own screen. */
bool LC32GuestUsesFixedPortraitPhoneCanvas(void) {
    return LC32GuestLegacyCanvasPolicy().usesFixedPortraitPhoneCanvas &&
        !LC32UIKitLegacyCompatibilityEnabled() &&
        LC32NativeLegacyRotationEnabled() &&
        LC32GuestLegacyCanvasPolicy().phoneCanvasHost;
}

bool LC32GuestMayRetainLegacyLandscapePhoneCanvas(void) {
    return LC32GuestLegacyCanvasPolicy()
        .mayRetainLegacyLandscapePhoneCanvas;
}

Class LC32NativeWindowDispatchClass(UIWindow *window) {
    Class dispatchClass = object_getClass(window);
    while(dispatchClass && [(id)dispatchClass isGuestClass]) {
        dispatchClass = class_getSuperclass(dispatchClass);
    }
    return dispatchClass;
}

UIViewController *LC32NativeWindowRootViewController(UIWindow *window) {
    Class dispatchClass = LC32NativeWindowDispatchClass(window);
    if(!window || !dispatchClass) return nil;
    struct objc_super superInfo = {window, dispatchClass};
    using GetRootViewController =
        UIViewController *(*)(struct objc_super *, SEL);
    return reinterpret_cast<GetRootViewController>(objc_msgSendSuper)(
        &superInfo, @selector(rootViewController));
}

void LC32NativeSetWindowRootViewController(
        UIWindow *window, UIViewController *controller) {
    Class dispatchClass = LC32NativeWindowDispatchClass(window);
    if(!window || !dispatchClass) return;
    if(LC32UIKitLegacyCompatibilityEnabled() &&
            ![controller isKindOfClass:LC32LegacyWindowRootController.class]) {
        LC32RestoreRootlessRendererAutoresizing(window);
    }
    struct objc_super superInfo = {window, dispatchClass};
    using SetRootViewController =
        void (*)(struct objc_super *, SEL, UIViewController *);
    reinterpret_cast<SetRootViewController>(objc_msgSendSuper)(
        &superInfo, @selector(setRootViewController:), controller);
}

void LC32NativeSetWindowFrame(UIWindow *window, CGRect frame) {
    Class dispatchClass = LC32NativeWindowDispatchClass(window);
    if(!window || !dispatchClass) return;
    using SetFrame = void (*)(id, SEL, CGRect);
    SetFrame setter = reinterpret_cast<SetFrame>(
        class_getMethodImplementation(dispatchClass, @selector(setFrame:)));
    setter(window, @selector(setFrame:), frame);
}

bool LC32WindowNeedsLegacyIPadContainer(UIWindow *window) {
    if(!window || !LC32UIKitLegacyIPadCanvasEnabled()) return false;
    const CGRect hostBounds = LC32WindowSceneBounds(window);
    const CGFloat shortEdge = MIN(hostBounds.size.width,
                                  hostBounds.size.height);
    return shortEdge > 0 && shortEdge < 600;
}

UIInterfaceOrientation LC32LegacyTargetOrientation(
        UIViewController *controller) {
    const UIInterfaceOrientation requested = (UIInterfaceOrientation)
        LC32LegacyRequestedOrientation.load(std::memory_order_relaxed);
    if(LC32MaskForInterfaceOrientation(requested)) return requested;
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    const UIInterfaceOrientation settled =
        LC32SettledLegacyOrientation(
            controller, UIInterfaceOrientationMaskAll);
    if(settled != UIInterfaceOrientationUnknown) return settled;
    if(LC32MaskForInterfaceOrientation(policy.preferredOrientation)) {
        return policy.preferredOrientation;
    }
    return LC32FirstOrientationInMask(policy.declaredOrientations);
}

UIViewController *LC32GuestWindowRootViewController(UIWindow *window) {
    UIViewController *root = LC32NativeWindowRootViewController(window);
    if([root isKindOfClass:LC32LegacyIPadContainerController.class]) {
        root = ((LC32LegacyIPadContainerController *)root)
            .guestContentController;
    }
    return [root isKindOfClass:LC32LegacyWindowRootController.class]
        ? nil : root;
}

void LC32InstallGuestWindowRootViewController(
        UIWindow *window, UIViewController *controller,
        LC32LegacyIPadGeometryMode geometryMode) {
    if(!window || !window.guest_selfOrNull) return;
    LC32LegacyIPadContainerController *container =
        LC32LegacyContainerForWindow(window);
    const bool requestsPhoneCanvas =
        LC32GeometryModePreservesPhoneCanvas(geometryMode);
    const bool preservesInstalledPhoneCanvas = container &&
        LC32GeometryModePreservesPhoneCanvas(container.geometryMode);
    const bool needsPhoneCanvas = requestsPhoneCanvas &&
        (preservesInstalledPhoneCanvas ||
         LC32WindowNeedsLegacyPhoneCanvas(window, controller));
    const bool needsContainer = controller &&
        (LC32WindowNeedsLegacyIPadContainer(window) || needsPhoneCanvas);

    if(!needsContainer) {
        /* nil uninstalls the compatibility root. If the scene no longer
         * needs classic-iPad virtualization, detach the child before
         * promoting it back to UIWindow.rootViewController. */
#if !__has_feature(objc_arc)
        [controller retain];
#endif
        if(container) {
            [container setGuestContentController:nil
                                     geometryMode:geometryMode];
        }
        UIView *rootView = nil;
        LC32NativeViewIfLoaded(controller, &rootView);
        const UIInterfaceOrientation oldRootOrientation = rootView
            ? LC32LegacyRootWindowGeometry(rootView, true, window, controller)
            : UIInterfaceOrientationUnknown;
        LC32NativeSetWindowRootViewController(window, controller);
        if(!controller && LC32GuestUsesFixedLandscapePhoneCanvas() &&
                LC32GetGuestExecutableSDKVersion() < 0x80000 &&
                LC32InstallLegacyDirectSubviewRoot(window)) {
            /* Some games (9mm) show a loading controller, then clear the
             * root and keep drawing into a renderer added directly to the
             * window. Old UIKit composited that rootless window; keep the
             * hidden synthetic root (the guest still reads nil) so the
             * fixed canvas continues to be fitted to the scene. */
            LC32ApplyLegacyWindowPolicy(window);
            LC32ScaleLegacyIPadWindow(window);
        }
        if(oldRootOrientation) {
            /* Capture before UIKit's initial root layout can transpose the
             * guest's already-landscape bounds. Unattached renderers perform
             * their old orientation setup before setRootViewController:. */
            objc_setAssociatedObject(rootView, LC32LegacyRootWindowGeometryKey,
                @(oldRootOrientation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_async(dispatch_get_main_queue(), ^{
                LC32FitLegacyControllerRoot(rootView);
            });
        }
#if !__has_feature(objc_arc)
        [controller release];
#endif
        return;
    }

    if(!container) {
        /* Retain across replacing UIWindow's old root: UIKit is allowed to
         * release that controller as part of the assignment. Install an
         * empty native container first so addChildViewController: never sees
         * a controller which is simultaneously UIWindow's root. */
#if !__has_feature(objc_arc)
        [controller retain];
#endif
        container = [[LC32LegacyIPadContainerController alloc]
            initWithGuestContentController:nil geometryMode:geometryMode];
        LC32NativeSetWindowRootViewController(window, container);
        [container setGuestContentController:controller
                                 geometryMode:geometryMode];
#if !__has_feature(objc_arc)
        [controller release];
        [container release];
#endif
    } else {
        [container setGuestContentController:controller
                                 geometryMode:geometryMode];
    }
    LC32ScaleLegacyIPadWindow(window);
}

CGRect LC32WindowSceneBounds(UIWindow *window) {
    CGRect classicBounds, classicScene;
    if(LC32GetClassicWindowGeometry(window, &classicBounds, &classicScene)) return classicScene;
    UIWindowScene *scene = window.windowScene;
    /* Keep this helper in scene coordinates for eligibility and orientation
     * policy. Canvas placement uses LC32LegacyViewportInView below, which
     * preserves the source coordinate space instead of copying raw numbers. */
    id<UICoordinateSpace> coordinateSpace = nil;
    if(@available(iOS 26.0, *)) {
        coordinateSpace = (id<UICoordinateSpace>)LC32ObjectProperty(
            scene.effectiveGeometry, "coordinateSpace");
        if(coordinateSpace) return coordinateSpace.bounds;
    }
    coordinateSpace = scene.coordinateSpace;
    if(coordinateSpace) return coordinateSpace.bounds;
    return (window.screen ?: UIScreen.mainScreen).bounds;
}

bool LC32WindowNeedsLegacyPhoneCanvas(
        UIWindow *window, UIViewController *controller) {
    if(!window || !window.guest_selfOrNull || !controller ||
            !LC32ObjectUsesGuestClass(controller) ||
            LC32GuestNeedsLegacyIPadCanvas()) {
        return false;
    }

    if(LC32GuestUsesFixedLandscapePhoneCanvas()) {
        /* The bundle classifier already restricts this to pre-iPhone-5,
         * landscape-only phone apps without tall launch art. They need the
         * legacy compositor even when Classic Mode exposes exactly 480x320. */
        return true;
    }

    if(!LC32GuestMayRetainLegacyLandscapePhoneCanvas()) {
        return false;
    }

    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    if(!policy.usesLegacyInitialOrientation ||
            !UIInterfaceOrientationIsLandscape(
                policy.preferredOrientation)) {
        return false;
    }

    UIView *contentView = nil;
    if(!LC32NativeViewIfLoaded(controller, &contentView) || !contentView) {
        return false;
    }
    const CGRect sceneBounds = LC32WindowSceneBounds(window);
    const CGRect contentBounds = LC32NativeViewBounds(contentView);
    const CGFloat sceneShort = MIN(sceneBounds.size.width,
                                   sceneBounds.size.height);
    const CGFloat sceneLong = MAX(sceneBounds.size.width,
                                  sceneBounds.size.height);
    const CGFloat contentShort = MIN(contentBounds.size.width,
                                     contentBounds.size.height);
    const CGFloat contentLong = MAX(contentBounds.size.width,
                                    contentBounds.size.height);
    constexpr CGFloat epsilon = 0.5;

    /* A few 568-point games include the tall launch image but deliberately
     * retain their old 480x320 drawable. Newer hosts can expose the physical
     * scene (for example 956x440) even when LiveContainer's Classic Mode is
     * enabled, so accept a larger scene while keeping the distinctive legacy
     * content dimensions and initial-orientation policy exact. */
    return sceneShort >= 320 - epsilon &&
           sceneLong >= 568 - epsilon &&
           fabs(contentShort - 320) < epsilon &&
           fabs(contentLong - 480) < epsilon;
}

bool LC32WindowNeedsImmediateLegacyPhoneCanvas(
        UIWindow *window, UIViewController *controller) {
    if(!window || !window.guest_selfOrNull || !controller ||
            !LC32ObjectUsesGuestClass(controller) ||
            LC32GuestNeedsLegacyIPadCanvas()) {
        return false;
    }

    if(!LC32GuestUsesFixedLandscapePhoneCanvas()) return false;

    UIView *contentView = nil;
    if(LC32NativeViewIfLoaded(controller, &contentView) &&
            LC32NativeViewHidden(contentView) &&
            LC32NativeViewSuperview(contentView) == window) return false;

    /* Unattached roots still need their fixed portrait surface isolated
     * before UIKit creates and lays out the renderer. */
    return true;
}

NSNumber *LC32LegacyDirectGuestRootStateForAssignment(
        UIWindow *window, UIViewController *controller) {
    if(!window || !window.guest_selfOrNull || !controller ||
            !LC32ObjectUsesGuestClass(controller) ||
            !LC32GuestUsesFixedLandscapePhoneCanvas()) {
        return nil;
    }
    UIViewController *currentController =
        LC32GuestWindowRootViewController(window);
    if(currentController) {
        if(currentController != controller) return nil;
        return objc_getAssociatedObject(
            window, LC32HideLegacyDirectGuestWindowRootKey);
    }
    if(LC32NativeApplicationState() == UIApplicationStateActive) return nil;

    UIView *contentView = nil;
    if(!LC32NativeViewIfLoaded(controller, &contentView) ||
            !LC32NativeViewHidden(contentView) ||
            LC32NativeViewSuperview(contentView) != window) return nil;

    /* Main-nib games can archive a hidden bookkeeping controller alongside
     * their real renderer as direct UIWindow children, then assign that
     * controller as root during launch. Old UIKit left rootViewController nil
     * through the first renderer layouts. Modern UIKit exposes it immediately,
     * which can enter post-launch guest UI before engine-owned buffers exist.
     * Keep the native root for scene policy, but preserve the old
     * guest-visible nil for the lifetime of this direct hierarchy. Exposing
     * or reparenting it can synchronously force layout before engine-owned
     * buffers have finished initializing. */
    return @YES;
}

void LC32RestoreLegacyDirectWindowSublayerTransform(
        UIWindow *window, CALayer *windowLayer, NSValue *savedTransform) {
    if(!window || !windowLayer || !savedTransform) return;

    CATransform3D originalTransform;
    [savedTransform getValue:&originalTransform
                        size:sizeof(originalTransform)];
    NSValue *appliedValue = objc_getAssociatedObject(
        window, LC32LegacyDirectWindowAppliedSublayerTransformKey);
    CATransform3D appliedTransform = CATransform3DIdentity;
    if(appliedValue) {
        [appliedValue getValue:&appliedTransform
                          size:sizeof(appliedTransform)];
    }
    const CATransform3D currentTransform = windowLayer.sublayerTransform;
    const bool stillOwnsTransform = appliedValue &&
        CATransform3DEqualToTransform(currentTransform, appliedTransform);
    if(stillOwnsTransform && !CATransform3DEqualToTransform(
            currentTransform, originalTransform)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        windowLayer.sublayerTransform = originalTransform;
        [CATransaction commit];
    }
    objc_setAssociatedObject(
        window, LC32LegacyDirectWindowSublayerTransformKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(
        window, LC32LegacyDirectWindowAppliedSublayerTransformKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/* The legacy canvas is a sublayerTransform on the window layer, which UIKit
 * hit testing honours but window-space touch locations do not. A guest that
 * asks for -[UITouch locationInView:nil] (Top Gear Stunt School) expects its
 * own 320x480 window space, so map the point back through that transform. */
extern "C" bool LC32UIKitGuestWindowPointFromHost(
        UIWindow *window, CGPoint *point) {
    if(!window || !point) return false;
    NSValue *appliedValue = objc_getAssociatedObject(
        window, LC32LegacyDirectWindowAppliedSublayerTransformKey);
    if(!appliedValue) return false;
    CATransform3D applied;
    [appliedValue getValue:&applied size:sizeof(applied)];
    CALayer *windowLayer = window.layer;
    if(!CATransform3DEqualToTransform(windowLayer.sublayerTransform,
            applied) || CATransform3DIsIdentity(applied) ||
            !CATransform3DIsAffine(applied)) {
        return false;
    }
    const CGAffineTransform forward =
        CATransform3DGetAffineTransform(applied);
    const CGAffineTransform inverse = CGAffineTransformInvert(forward);
    if(CGAffineTransformEqualToTransform(inverse, forward)) return false;
    const CGRect bounds = windowLayer.bounds;
    const CGPoint anchor = {
        bounds.origin.x + windowLayer.anchorPoint.x * bounds.size.width,
        bounds.origin.y + windowLayer.anchorPoint.y * bounds.size.height,
    };
    const CGPoint relative = CGPointApplyAffineTransform(
        CGPointMake(point->x - anchor.x, point->y - anchor.y), inverse);
    *point = CGPointMake(anchor.x + relative.x, anchor.y + relative.y);
    return true;
}

bool LC32LegacyLayerPreservesPortraitCanvas(CALayer *layer) {
    const CGRect bounds = layer.bounds;
    const CGPoint position = layer.position;
    const CGPoint anchor = layer.anchorPoint;
    constexpr CGFloat epsilon = 0.5;
    return fabs(bounds.origin.x) < epsilon &&
        fabs(bounds.origin.y) < epsilon &&
        fabs(bounds.size.width - 320) < epsilon &&
        fabs(bounds.size.height - LC32GuestPhoneCanvasLongEdge()) < epsilon &&
        fabs(position.x - anchor.x * bounds.size.width) < epsilon &&
        fabs(position.y - anchor.y * bounds.size.height) < epsilon &&
        CATransform3DIsIdentity(layer.transform) &&
        CATransform3DIsIdentity(layer.sublayerTransform);
}

bool LC32FindLegacyNestedPortraitRenderer(
        CALayer *layer, Class rendererClass, bool portraitAncestors,
        unsigned depth, unsigned &remainingLayers, CALayer *&renderer) {
    /* Inspect native backing layers only. Guest CALayer overrides can enter
     * the emulator even for a getter; an unfamiliar or overly deep tree is
     * not evidence that its compositor is missing. */
    if(!layer || !remainingLayers || depth > 32 ||
            LC32ObjectUsesGuestClass(layer)) return false;
    --remainingLayers;
    const bool portraitChain = portraitAncestors &&
        LC32LegacyLayerPreservesPortraitCanvas(layer);
    if([layer isKindOfClass:rendererClass]) {
        if(!portraitChain || renderer) return false;
        renderer = layer;
    }
    for(CALayer *child in layer.sublayers) {
        if(!LC32FindLegacyNestedPortraitRenderer(child, rendererClass,
                portraitChain, depth + 1, remainingLayers, renderer)) {
            return false;
        }
    }
    return true;
}

bool LC32TransformIsQuarterTurn(CATransform3D transform) {
    if(!CATransform3DIsAffine(transform)) return false;
    const CGAffineTransform t = CATransform3DGetAffineTransform(transform);
    constexpr CGFloat epsilon = 0.0001;
    const bool axisAligned = (fabs(t.b) < epsilon && fabs(t.c) < epsilon &&
            fabs(fabs(t.a) - 1) < epsilon && fabs(fabs(t.d) - 1) < epsilon) ||
        (fabs(t.a) < epsilon && fabs(t.d) < epsilon &&
            fabs(fabs(t.b) - 1) < epsilon && fabs(fabs(t.c) - 1) < epsilon);
    return axisAligned && fabs(t.a * t.d - t.b * t.c - 1) < epsilon;
}

/* allowQuarterTurns: with native legacy rotation UIKit hosts the portrait
 * guest window in a rotated (unscaled) window layer to present it in a
 * landscape scene. That orientation compositor is not a fit of its own. */
bool LC32LegacyWindowHasAncestorCompositor(
        CALayer *windowLayer, CATransform3D allowedWindowTransform,
        bool allowQuarterTurns = false) {
    if(!CATransform3DEqualToTransform(
            windowLayer.transform, allowedWindowTransform)) return true;
    unsigned remainingLayers = 32;
    for(CALayer *layer = windowLayer.superlayer; layer;
            layer = layer.superlayer) {
        const bool transformAllowed =
            CATransform3DIsIdentity(layer.transform) ||
            (allowQuarterTurns && LC32TransformIsQuarterTurn(layer.transform));
        if(!remainingLayers-- || LC32ObjectUsesGuestClass(layer) ||
                !transformAllowed ||
                !CATransform3DIsIdentity(layer.sublayerTransform)) {
            return true;
        }
    }
    return false;
}

bool LC32WindowUsesRootlessPhoneCanvas(UIWindow *window) {
    return window && window.guest_selfOrNull &&
        LC32GetGuestExecutableSDKVersion() < 0x80000 &&
        LC32GuestUsesFixedLandscapePhoneCanvas() &&
        [LC32NativeWindowRootViewController(window)
            isKindOfClass:LC32LegacyWindowRootController.class];
}

void LC32RestoreRootlessRendererAutoresizing(UIWindow *window) {
    NSMapTable<UIView *, LC32LegacyRendererAutoresizingState *> *saved =
        objc_getAssociatedObject(
            window, LC32LegacyRootlessRendererAutoresizingKey);
    for(UIView *view in saved.keyEnumerator) {
        LC32LegacyRendererAutoresizingState *state = [saved objectForKey:view];
        if(objc_getAssociatedObject(view,
                LC32LegacyRootlessRendererAutoresizingStateKey) != state) continue;
        if(!state.yielded &&
                LC32NativeViewAutoresizingMask(view) == UIViewAutoresizingNone) {
            LC32NativeSetViewAutoresizingMask(view, state.originalMask);
        }
        objc_setAssociatedObject(view,
            LC32LegacyRootlessRendererAutoresizingStateKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(window, LC32LegacyRootlessRendererAutoresizingKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LC32PreserveRootlessRendererAutoresizing(
        UIWindow *window, bool installingSyntheticRoot = false) {
    if(!window || !window.guest_selfOrNull ||
            LC32GetGuestExecutableSDKVersion() >= 0x80000 ||
            !LC32GuestUsesFixedLandscapePhoneCanvas()) return;
    UIViewController *root = LC32NativeWindowRootViewController(window);
    if(installingSyntheticRoot ? root != nil
            : ![root isKindOfClass:LC32LegacyWindowRootController.class]) return;

    NSMapTable<UIView *, LC32LegacyRendererAutoresizingState *> *saved =
        objc_getAssociatedObject(
            window, LC32LegacyRootlessRendererAutoresizingKey);
    bool alreadyPreserved = false;
    for(UIView *view in saved.keyEnumerator) {
        LC32LegacyRendererAutoresizingState *state = [saved objectForKey:view];
        if(state.yielded || objc_getAssociatedObject(view,
                LC32LegacyRootlessRendererAutoresizingStateKey) != state) continue;
        if(LC32NativeViewAutoresizingMask(view) != UIViewAutoresizingNone) {
            /* A later guest setting takes ownership. Remember that decision
             * while this window remains rootless instead of freezing it again. */
            state.yielded = YES;
        } else if(LC32NativeViewSuperview(view) != window) {
            LC32NativeSetViewAutoresizingMask(view, state.originalMask);
            state.yielded = YES;
            objc_setAssociatedObject(view,
                LC32LegacyRootlessRendererAutoresizingStateKey, nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            alreadyPreserved = true;
        }
    }
    if(alreadyPreserved) return;

    CALayer *windowLayer = LC32NativeViewLayer(window);
    if(!windowLayer || LC32ObjectUsesGuestClass(windowLayer) ||
            !LC32TransformNearlyEquals(LC32NativeViewTransform(window),
                CGAffineTransformIdentity) ||
            !CATransform3DIsIdentity(windowLayer.sublayerTransform)) return;
    static Class rendererClass = NSClassFromString(@"CAEAGLLayer");
    if(!rendererClass) return;
    CALayer *renderer = nil;
    unsigned remainingLayers = 1024;
    for(CALayer *layer in windowLayer.sublayers) {
        if(!LC32FindLegacyNestedPortraitRenderer(layer, rendererClass,
                true, 0, remainingLayers, renderer)) return;
    }
    if(!renderer) return;

    for(UIView *view in LC32NativeViewSubviews(window)) {
        if(LC32NativeViewLayer(view) != renderer || !view.guest_selfOrNull ||
                [saved objectForKey:view]) continue;
        LC32LegacyRendererAutoresizingState *previous = objc_getAssociatedObject(
            view, LC32LegacyRootlessRendererAutoresizingStateKey);
        if(previous) {
            /* A renderer can move to a different rootless window before its
             * former window refits. Retire only that old preservation record;
             * its later cleanup must not alter this window's new ownership. */
            if(!previous.yielded &&
                    LC32NativeViewAutoresizingMask(view) ==
                        UIViewAutoresizingNone) {
                LC32NativeSetViewAutoresizingMask(view, previous.originalMask);
            }
            previous.yielded = YES;
            objc_setAssociatedObject(view,
                LC32LegacyRootlessRendererAutoresizingStateKey, nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        const UIViewAutoresizing mask = LC32NativeViewAutoresizingMask(view);
        if(!(mask & (UIViewAutoresizingFlexibleWidth |
                     UIViewAutoresizingFlexibleHeight))) return;
        if(!saved) {
            /* Weak pointer-identity keys neither extend a removed renderer's
             * lifetime nor call guest -hash/-isEqual: implementations. */
            saved = [NSMapTable
                mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                    NSPointerFunctionsObjectPointerPersonality
                valueOptions:NSPointerFunctionsStrongMemory];
            objc_setAssociatedObject(window,
                LC32LegacyRootlessRendererAutoresizingKey, saved,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        LC32LegacyRendererAutoresizingState *state =
            [LC32LegacyRendererAutoresizingState new];
        state.originalMask = mask;
        [saved setObject:state forKey:view];
        objc_setAssociatedObject(view,
            LC32LegacyRootlessRendererAutoresizingStateKey, state,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#if !__has_feature(objc_arc)
        [state release];
#endif
        /* The synthetic root makes modern UIWindow adopt scene-oriented
         * bounds. A main-nib portrait drawable with flexible dimensions would
         * otherwise be resized before our compositor can recognize it.
         * Preserve only the proven direct renderer, without changing its
         * bounds, center, descendants, or parent or forcing guest layout. */
        LC32NativeSetViewAutoresizingMask(view, UIViewAutoresizingNone);
        return;
    }
}

struct LC32LegacyRootlessWindowPlacement {
    CGAffineTransform originalTransform;
    CGAffineTransform appliedTransform;
    CGPoint originalCenter;
    CGPoint appliedCenter;
    bool yielded;
};

void LC32SaveRootlessWindowPlacement(
        UIWindow *window, const LC32LegacyRootlessWindowPlacement &placement) {
    objc_setAssociatedObject(window, LC32LegacyRootlessWindowPlacementKey,
        [NSValue value:&placement
            withObjCType:@encode(LC32LegacyRootlessWindowPlacement)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

bool LC32ReadRootlessWindowPlacement(
        UIWindow *window, LC32LegacyRootlessWindowPlacement &placement) {
    NSValue *value = objc_getAssociatedObject(
        window, LC32LegacyRootlessWindowPlacementKey);
    if(!value) return false;
    [value getValue:&placement size:sizeof(placement)];
    return true;
}

bool LC32ReconcileRootlessWindowPlacement(
        UIWindow *window, CALayer *layer, bool restore) {
    LC32LegacyRootlessWindowPlacement placement;
    if(!LC32ReadRootlessWindowPlacement(window, placement) ||
            placement.yielded || !layer || LC32ObjectUsesGuestClass(layer)) {
        return false;
    }
    const bool ownsTransform = CATransform3DEqualToTransform(
        layer.transform, CATransform3DMakeAffineTransform(
            placement.appliedTransform));
    const bool ownsCenter = CGPointEqualToPoint(
        LC32NativeViewCenter(window), placement.appliedCenter);
    if(ownsTransform && ownsCenter && !restore) return true;

    /* An application/scene can take over either component independently.
     * Restore only the pieces still ours, then stop fitting this window if
     * another owner intervened. Otherwise the next pass could silently
     * replace an authored center after restoring our scale to identity. */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if(ownsTransform) {
        LC32NativeSetViewTransform(window, placement.originalTransform);
    }
    if(ownsCenter) LC32NativeSetViewCenter(window, placement.originalCenter);
    [CATransaction commit];
    if(!ownsTransform || !ownsCenter) {
        placement.yielded = true;
        LC32SaveRootlessWindowPlacement(window, placement);
    } else {
        objc_setAssociatedObject(window, LC32LegacyRootlessWindowPlacementKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return false;
}

void LC32FitRootlessWindowPlacement(UIWindow *window, CALayer *layer) {
    /* Do not resize the guest window: its local 480x320 bounds and every
     * locked 320x480 drawable must survive. Moving/scaling the native window
     * also keeps UIKit hit-testing aligned with the visible content, unlike
     * drawing enlarged sublayers beyond the original window hit region. */
    const CGRect bounds = layer.bounds;
    const CGPoint anchor = layer.anchorPoint;
    if(LC32ObjectUsesGuestClass(window) || !window.windowScene ||
            !CGRectEqualToRect(bounds, CGRectMake(
                0, 0, LC32GuestPhoneCanvasLongEdge(), 320)) ||
            !CGPointEqualToPoint(anchor, CGPointMake(0.5, 0.5))) {
        LC32ReconcileRootlessWindowPlacement(window, layer, true);
        return;
    }
    LC32LegacyRootlessWindowPlacement placement;
    const bool hasPlacement = LC32ReadRootlessWindowPlacement(window, placement);
    if(hasPlacement && placement.yielded) return;
    const CGAffineTransform current = LC32NativeViewTransform(window);
    if(!hasPlacement && !CGAffineTransformIsIdentity(current)) return;
    const CGPoint center = LC32NativeViewCenter(window);
    const CGRect viewport = LC32LegacyViewportInView(window, window);
    /* The window can reach landscape before its scene/source space settles.
     * Do not claim placement ownership in that provisional portrait space:
     * UIKit's subsequent ordinary recenter is not an application takeover. */
    if(!(viewport.size.width > viewport.size.height) ||
            !(viewport.size.height > 0) || !isfinite(viewport.size.width) ||
            !isfinite(viewport.size.height)) return;
    /* Coordinate conversion removes our existing scale. Put the viewport
     * back into the native parent space before fitting, so repeated passes
     * neither compound nor cancel the previous placement. */
    const CGFloat scale = MIN(viewport.size.width / bounds.size.width,
                              viewport.size.height / bounds.size.height) *
        current.a;
    const CGPoint targetCenter = {
        center.x + (CGRectGetMidX(viewport) - CGRectGetMidX(bounds)) * current.a,
        center.y + (CGRectGetMidY(viewport) - CGRectGetMidY(bounds)) * current.d,
    };
    if(!(scale > 0) || !isfinite(scale) || !isfinite(targetCenter.x) ||
            !isfinite(targetCenter.y)) return;
    const CGAffineTransform target = CGAffineTransformMakeScale(scale, scale);
    if(!hasPlacement && CGAffineTransformEqualToTransform(current, target) &&
            CGPointEqualToPoint(center, targetCenter)) return;
    if(!hasPlacement) {
        placement.originalTransform = current;
        placement.originalCenter = center;
        placement.yielded = false;
    }
    placement.appliedTransform = target;
    placement.appliedCenter = targetCenter;
    LC32SaveRootlessWindowPlacement(window, placement);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if(!CGAffineTransformEqualToTransform(current, target)) {
        LC32NativeSetViewTransform(window, target);
    }
    if(!CGPointEqualToPoint(center, targetCenter)) {
        LC32NativeSetViewCenter(window, targetCenter);
    }
    [CATransaction commit];
}

/* With native legacy rotation, iOS 3/4 phone games (Starfront) that never
 * install a root controller keep their window at the 320x480 guest screen
 * size. UIKit now only quarter-turns windows that it rotates for a root
 * controller, so this window would sit unrotated in a corner of the
 * landscape scene. Do what the old compositor did and turn the whole native
 * window: its portrait drawable, touch coordinates and any presented
 * controller (which UIKit counter-rotates for the scene) stay intact. */
bool LC32LegacyWindowHasQuarterTurnAncestor(CALayer *windowLayer) {
    unsigned remainingLayers = 32;
    for(CALayer *layer = windowLayer.superlayer; layer && remainingLayers--;
            layer = layer.superlayer) {
        if(!CATransform3DIsIdentity(layer.transform) &&
                LC32TransformIsQuarterTurn(layer.transform)) return true;
    }
    return false;
}

/* Whether the window's ancestors together swap its axes (a net quarter
 * turn), unlike LC32LegacyWindowHasQuarterTurnAncestor, which also counts a
 * half turn or two turns that cancel out. */
bool LC32LegacyWindowAncestorRotation(CALayer *windowLayer, CGFloat &angle) {
    CGAffineTransform total = CGAffineTransformIdentity;
    unsigned remainingLayers = 32;
    for(CALayer *layer = windowLayer.superlayer; layer && remainingLayers--;
            layer = layer.superlayer) {
        if(!CATransform3DIsAffine(layer.transform)) return false;
        total = CGAffineTransformConcat(total,
            CATransform3DGetAffineTransform(layer.transform));
    }
    if(!(hypot(total.a, total.b) > 0)) return false;
    angle = atan2(total.b, total.a);
    return true;
}

bool LC32LegacyWindowAncestorsSwapAxes(CALayer *windowLayer) {
    CGFloat angle;
    return LC32LegacyWindowAncestorRotation(windowLayer, angle) &&
        fabs(sin(angle)) > 0.5;
}

/* A landscape-only rootless phone game launched while the device is held
 * upright (the normal case from LiveContainer's portrait UI). Turning the
 * scene to landscape for it leaves UIKit's legacy window layers portrait-sized
 * and the system then routes touches unrotated (clamped to the landscape
 * height), so taps land in the wrong place. Do what iPhone OS did instead:
 * keep the scene portrait and show the game's sideways portrait drawable
 * scaled to the screen; the guest still reports its landscape status-bar
 * orientation and converts its portrait touches itself. Decided once, from
 * the scene orientation when the window's policy is first applied. */
enum class LC32PortraitHostState { Undecided, Hosted, NotHosted };
/* Atomic: the main queue can leave hosting mid-run
 * (LC32LeavePortraitHostForLandscapeDevice) while guest threads read it
 * through the status-bar hooks. */
std::atomic<LC32PortraitHostState> LC32PortraitHostedLandscape{
    LC32PortraitHostState::Undecided};

bool LC32WindowHasGuestPortraitCanvasSize(CALayer *windowLayer) {
    const CGRect bounds = windowLayer.bounds;
    constexpr CGFloat epsilon = 0.5;
    return fabs(bounds.size.width - 320) < epsilon &&
        fabs(bounds.size.height - LC32GuestPhoneCanvasLongEdge()) < epsilon;
}

bool LC32WindowIsPortraitHostedLandscape(UIWindow *window) {
    return LC32PortraitHostedLandscape == LC32PortraitHostState::Hosted &&
        LC32WindowUsesRootlessPhoneCanvas(window) &&
        LC32WindowHasGuestPortraitCanvasSize(LC32NativeViewLayer(window));
}

/* The other two shapes a landscape phone game's portrait drawable takes under
 * native legacy rotation: a rootless renderer in a native-size window, fitted
 * by a scale-only sublayer transform (9mm), or an adopted root controller kept
 * as a portrait canvas in the compatibility container (Grabatron). Both are
 * upright in their window once UIKit no longer turns it for a landscape scene,
 * so hosting them only needs the portrait scene. */
bool LC32WindowUsesPortraitPhoneCanvas(UIWindow *window) {
    if(LC32WindowUsesRootlessPhoneCanvas(window)) return true;
    LC32LegacyIPadContainerController *container =
        window && window.guest_selfOrNull
            ? LC32LegacyContainerForWindow(window) : nil;
    /* A turned 480x320 root canvas (Zenonia 2/4) is hosted the same way:
     * UIKit still quarter-turns the root for the landscape status bar. */
    return container && (container.geometryMode ==
            LC32LegacyIPadGeometryModePreservePhonePortraitCanvas ||
         container.geometryMode ==
            LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas) &&
        LC32GetGuestExecutableSDKVersion() < 0x80000 &&
        LC32GuestUsesFixedLandscapePhoneCanvas();
}

bool LC32WindowIsPortraitHosted(UIWindow *window) {
    return LC32PortraitHostedLandscape == LC32PortraitHostState::Hosted &&
        LC32WindowUsesPortraitPhoneCanvas(window);
}

extern "C" bool LC32UIKitGuestFixedCanvasDeviceOrientation(
    UIDeviceOrientation *orientation);
UIDeviceOrientation LC32SceneDeviceOrientation(UIWindowScene *scene);

/* Modern Combat 4 (SDK 7.1, fixed 568 canvas, lists Portrait and both
 * landscape sides) draws for its launch side whatever the device does (see
 * LC32UIKitGuestFixedCanvasDeviceOrientation); a sideways launch turns the
 * whole window to either landscape side. Hosting it upright is only needed
 * while the phone is upright: once it is actually held sideways, let the
 * scene follow and leave hosting for that turned window (see
 * LC32LeavePortraitHostForLandscapeDevice). */
bool LC32PortraitHostFollowsLandscapeDevice(UIWindow *window) {
    if(@available(iOS 16.0, *)) {
    } else {
        return false;
    }
    return LC32WindowIsPortraitHostedLandscape(window) &&
        LC32UIKitGuestFixedCanvasDeviceOrientation(nullptr) &&
        (LC32GuestInterfacePolicy().declaredOrientations &
            UIInterfaceOrientationMaskLandscape) ==
                UIInterfaceOrientationMaskLandscape;
}

/* The phone was turned sideways after an upright launch and the scene
 * followed (LC32PortraitHostFollowsLandscapeDevice). The touch problem that
 * hosting avoids only exists while the device is upright, so from here on
 * the window is placed like a sideways launch: turned and filling the
 * landscape scene, on either side, and kept landscape. */
bool LC32LeavePortraitHostForLandscapeDevice(UIWindow *window) {
    if(!LC32PortraitHostFollowsLandscapeDevice(window)) return false;
    UIWindowScene *scene = window.windowScene;
    if(!scene || !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation) ||
            !UIDeviceOrientationIsLandscape(
                LC32SceneDeviceOrientation(scene))) return false;
    LC32PortraitHostedLandscape = LC32PortraitHostState::NotHosted;
    fprintf(stderr, "LC32: portrait-hosted game follows the phone to "
        "landscape (io=%ld); window turned like a sideways launch\n",
        (long)scene.interfaceOrientation);
    UIViewController *root = LC32NativeWindowRootViewController(window);
    [root setNeedsStatusBarAppearanceUpdate];
    if(@available(iOS 16.0, *))
        [root setNeedsUpdateOfSupportedInterfaceOrientations];
    return true;
}

/* While hosted, the root allows landscape only when the phone is held
 * sideways (LC32PortraitHostDeviceIsSideways), so nothing presented can turn
 * the scene under an upright phone. UIKit hands FrontBoard a new mask only
 * when asked, so ask on every device turn. */
bool LC32PortraitHostDeviceIsSideways(UIWindow *window) {
    return UIDeviceOrientationIsLandscape(
            LC32SceneDeviceOrientation(window.windowScene)) ||
        UIDeviceOrientationIsLandscape(UIDevice.currentDevice.orientation);
}

void LC32WatchPortraitHostDeviceTurns(UIWindow *window) {
    static bool installed;
    if(installed || !LC32PortraitHostFollowsLandscapeDevice(window)) return;
    installed = true;
    UIWindow *target = window;
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *) {
            if(!LC32PortraitHostFollowsLandscapeDevice(target)) return;
            if(@available(iOS 16.0, *)) {
                [LC32NativeWindowRootViewController(target)
                    setNeedsUpdateOfSupportedInterfaceOrientations];
            }
        }];
}

/* The device side FrontBoard reports to the scene (it honors the rotation
 * lock); UIDevice only learns it once orientation tracking has started. */
UIDeviceOrientation LC32SceneDeviceOrientation(UIWindowScene *scene) {
    @try {
        SEL fbsSceneSelector = sel_registerName("_FBSScene");
        id fbsScene = [scene respondsToSelector:fbsSceneSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(scene, fbsSceneSelector) : nil;
        id settings = [fbsScene respondsToSelector:@selector(settings)]
            ? ((id (*)(id, SEL))objc_msgSend)(fbsScene, @selector(settings))
            : nil;
        SEL deviceSelector = sel_registerName("deviceOrientation");
        if([settings respondsToSelector:deviceSelector]) {
            const NSInteger orientation = ((NSInteger (*)(id, SEL))
                objc_msgSend)(settings, deviceSelector);
            if(orientation >= UIDeviceOrientationPortrait &&
                    orientation <= UIDeviceOrientationLandscapeRight) {
                return (UIDeviceOrientation)orientation;
            }
        }
    } @catch(id) {
    }
    return UIDevice.currentDevice.orientation;
}

void LC32DecidePortraitHostedLandscape(UIWindow *window,
                                       UIInterfaceOrientation current) {
    if(LC32PortraitHostedLandscape != LC32PortraitHostState::Undecided ||
            !LC32MaskForInterfaceOrientation(current) ||
            !LC32WindowUsesPortraitPhoneCanvas(window)) return;
    /* A rootless window sized like the guest screen is turned as a whole
     * (Starfront); one already resized to the scene is the 9mm shape. */
    const bool rootless = LC32WindowUsesRootlessPhoneCanvas(window);
    const CGRect windowBounds = LC32NativeViewLayer(window).bounds;
    if(rootless && !LC32WindowHasGuestPortraitCanvasSize(
            LC32NativeViewLayer(window)) &&
            !(windowBounds.size.height > windowBounds.size.width &&
              windowBounds.size.width > 320.5)) return;
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    /* The system routes touches by the device's (lock-aware) orientation,
     * not by the scene's: a landscape-only guest plist can start the scene
     * landscape on an upright phone and taps are still delivered portrait.
     * Use the scene's side only while the device has no upright/sideways
     * reading (flat, unknown). */
    const UIDeviceOrientation device =
        LC32SceneDeviceOrientation(window.windowScene);
    const bool uprightDevice = UIDeviceOrientationIsPortrait(device) ||
        (!UIDeviceOrientationIsLandscape(device) &&
         UIInterfaceOrientationIsPortrait(current));
    /* The fixed phone canvas is a landscape screen whatever else the plist
     * lists (Modern Combat 4 also names Portrait). */
    UIInterfaceOrientationMask declared = policy.declaredOrientations;
    if(LC32GuestUsesFixedLandscapePhoneCanvas() &&
            (declared & UIInterfaceOrientationMaskLandscape))
        declared &= UIInterfaceOrientationMaskLandscape;
    const bool hosted = LC32NativeLegacyRotationEnabled() && uprightDevice &&
        !(declared & (UIInterfaceOrientationMaskPortrait |
            UIInterfaceOrientationMaskPortraitUpsideDown));
    LC32PortraitHostedLandscape = hosted ? LC32PortraitHostState::Hosted
                                         : LC32PortraitHostState::NotHosted;
}

/* The landscape side a hosted legacy window was last turned to while its
 * scene stayed portrait (LegacyRotation.mm announces that turn to the guest);
 * 0 until the phone is first turned to the other side. */
std::atomic<long> LC32PortraitHostedTurnedSide{0};

extern "C" void LC32UIKitPortraitHostedSideChanged(
        UIInterfaceOrientation side) {
    if(UIInterfaceOrientationIsLandscape(side))
        LC32PortraitHostedTurnedSide.store(side);
}

/* The side the guest draws its sideways canvas for: its launch side
 * (UIInterfaceOrientation), not whatever side a transient landscape scene
 * settled on before it was turned back to portrait, until the phone turns
 * the hosted window to the other side (Alien Space Retro). */
UIInterfaceOrientation LC32PortraitHostedLandscapeSide(void) {
    const UIInterfaceOrientation turned =
        (UIInterfaceOrientation)LC32PortraitHostedTurnedSide.load();
    if(UIInterfaceOrientationIsLandscape(turned)) return turned;
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    if(UIInterfaceOrientationIsLandscape(policy.preferredOrientation)) {
        return policy.preferredOrientation;
    }
    return (policy.declaredOrientations &
            UIInterfaceOrientationMaskLandscapeRight) ||
        !(policy.declaredOrientations &
            UIInterfaceOrientationMaskLandscapeLeft)
        ? UIInterfaceOrientationLandscapeRight
        : UIInterfaceOrientationLandscapeLeft;
}

/* The landscape area the turned window must cover, in its superlayer's
 * coordinates. When the device itself is portrait and the scene was turned to
 * landscape for the guest (the usual case on a phone held upright at launch,
 * or when the scene geometry request is refused), UIKit's legacy rotation
 * leaves the window transform layers at their portrait size while the scene
 * is presented landscape: the layer origin is the landscape screen's corner
 * and its long edge runs along x. */
bool LC32TurnedRootlessWindowViewport(UIWindow *window, CALayer *windowLayer,
                                      CGRect &viewport) {
    const CGRect parent = windowLayer.superlayer.bounds;
    if(parent.size.width > parent.size.height) {
        viewport = parent;
        return true;
    }
    UIWindowScene *scene = window.windowScene;
    if(!scene || !UIInterfaceOrientationIsLandscape(
            scene.interfaceOrientation)) return false;
    const CGRect sceneBounds = scene.coordinateSpace.bounds;
    if(!(sceneBounds.size.width > sceneBounds.size.height) ||
            fabs(sceneBounds.size.width - parent.size.height) > 0.5 ||
            fabs(sceneBounds.size.height - parent.size.width) > 0.5) {
        return false;
    }
    viewport = CGRectMake(parent.origin.x, parent.origin.y,
                          parent.size.height, parent.size.width);
    return true;
}

/* The 9mm shape: a rootless window UIKit already resized to the portrait
 * scene (while a guest root was installed) rather than the guest screen. */
bool LC32WindowHasScenePortraitSize(UIWindow *window, CALayer *windowLayer) {
    UIWindowScene *scene = window.windowScene;
    if(!scene || !windowLayer) return false;
    const CGSize sceneSize = scene.coordinateSpace.bounds.size;
    const CGSize size = windowLayer.bounds.size;
    constexpr CGFloat epsilon = 0.5;
    return size.height > size.width && size.width > 320 + epsilon &&
        fabs(size.width - MIN(sceneSize.width, sceneSize.height)) < epsilon &&
        fabs(size.height - MAX(sceneSize.width, sceneSize.height)) < epsilon;
}

bool LC32RootlessWindowNeedsTurnedPlacement(
        UIWindow *window, CALayer *windowLayer) {
    if(!windowLayer || LC32ObjectUsesGuestClass(window)) return false;
    if(LC32WindowIsPortraitHostedLandscape(window)) return true;
    CGRect viewport;
    /* A scene-sized window normally sits in transform layers UIKit
     * quarter-turned for the scene. UIKit rebuilds them unturned once the
     * phone turns (no guest controller is left to ask for the legacy
     * backing), so it then needs the same turn as a guest-sized one. */
    if(LC32WindowHasScenePortraitSize(window, windowLayer)) {
        return LC32TurnedRootlessWindowViewport(window, windowLayer, viewport) &&
            !LC32LegacyWindowAncestorsSwapAxes(windowLayer);
    }
    return LC32WindowHasGuestPortraitCanvasSize(windowLayer) &&
        LC32TurnedRootlessWindowViewport(window, windowLayer, viewport) &&
        !LC32LegacyWindowHasQuarterTurnAncestor(windowLayer);
}

void LC32FitTurnedRootlessWindowPlacement(
        UIWindow *window, CALayer *layer, UIInterfaceOrientation orientation) {
    CGFloat angle;
    const bool hosted = LC32WindowIsPortraitHostedLandscape(window);
    if(hosted) {
        angle = 0;
    } else if(orientation == UIInterfaceOrientationLandscapeLeft) {
        angle = M_PI_2;
    } else if(orientation == UIInterfaceOrientationLandscapeRight) {
        angle = -M_PI_2;
    } else {
        LC32ReconcileRootlessWindowPlacement(window, layer, true);
        return;
    }
    /* A scene-sized window can still sit in transform layers UIKit
     * quarter-turned for the scene side it had when a guest controller was
     * last installed (the logo movie). UIKit rebuilds them only when the
     * phone passes through portrait, not on a direct landscape flip (seen on
     * iOS 27 devices), so they keep the old side: turn the window by the
     * difference, a half turn or none. */
    CGFloat ancestorAngle = 0;
    const bool ancestorsTurned = !hosted &&
        LC32WindowHasScenePortraitSize(window, layer) &&
        LC32LegacyWindowAncestorRotation(layer, ancestorAngle) &&
        fabs(sin(ancestorAngle)) > 0.5;
    if(ancestorsTurned) {
        ancestorAngle = round(ancestorAngle / M_PI_2) * M_PI_2;
        angle = remainder(angle - ancestorAngle, 2 * M_PI);
        if(fabs(angle) < 0.01) {
            LC32ReconcileRootlessWindowPlacement(window, layer, true);
            return;
        }
    }
    LC32LegacyRootlessWindowPlacement placement;
    bool hasPlacement = LC32ReadRootlessWindowPlacement(window, placement);
    if(hasPlacement && placement.yielded && !hosted &&
            LC32WindowHasScenePortraitSize(window, layer) &&
            CGAffineTransformIsIdentity(LC32NativeViewTransform(window))) {
        /* UIKit re-centred or reset the window while it rebuilt its layers
         * (a movie root, a device turn). Nothing else turns this window, and
         * left as it is it stays sideways: own its placement again. */
        objc_setAssociatedObject(window, LC32LegacyRootlessWindowPlacementKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hasPlacement = false;
    }
    if(hasPlacement && placement.yielded) {
        static int remaining = 4;
        if(remaining > 0) {
            remaining--;
            fprintf(stderr, "LC32: rootless window turn for side %ld skipped "
                "(placement yielded)\n", (long)orientation);
        }
        return;
    }
    const CGAffineTransform current = LC32NativeViewTransform(window);
    if(!hasPlacement && !CGAffineTransformIsIdentity(current)) return;
    const CGPoint center = LC32NativeViewCenter(window);
    /* The window's center lives in its superlayer (the scene transform
     * layer), which is unaffected by the window's own transform. */
    CGRect parent = layer.superlayer.bounds;
    if(hosted) {
        /* A scene that started landscape and was turned back to portrait
         * keeps landscape-sized window layers, while the screen now shows
         * them unrotated: fit to the scene's portrait bounds instead. */
        const CGRect sceneBounds = window.windowScene.coordinateSpace.bounds;
        if(sceneBounds.size.height > sceneBounds.size.width) {
            parent = CGRectMake(parent.origin.x, parent.origin.y,
                sceneBounds.size.width, sceneBounds.size.height);
        }
    } else if(!ancestorsTurned &&
            !LC32TurnedRootlessWindowViewport(window, layer, parent)) {
        return;
    }
    const CGRect bounds = layer.bounds;
    /* The ancestors' turn already swaps the axes; a half turn does not. */
    const CGFloat scale = hosted || ancestorsTurned
        ? MIN(parent.size.width / bounds.size.width,
              parent.size.height / bounds.size.height)
        : MIN(parent.size.width / bounds.size.height,
              parent.size.height / bounds.size.width);
    const CGPoint targetCenter = {CGRectGetMidX(parent), CGRectGetMidY(parent)};
    if(!(scale > 0) || !isfinite(scale)) return;
    const CGAffineTransform target = CGAffineTransformScale(
        CGAffineTransformMakeRotation(angle), scale, scale);
    if(!hasPlacement) {
        placement.originalTransform = current;
        placement.originalCenter = center;
        placement.yielded = false;
    }
    placement.appliedTransform = target;
    placement.appliedCenter = targetCenter;
    LC32SaveRootlessWindowPlacement(window, placement);
    if(!LC32TransformNearlyEquals(current, target)) {
        static int remaining = 40;
        if(remaining > 0) {
            remaining--;
            fprintf(stderr, "LC32: rootless window turned for side %ld "
                "(%.0fx%.0f, scale %.2f)\n", (long)orientation,
                bounds.size.width, bounds.size.height, scale);
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if(!LC32TransformNearlyEquals(current, target)) {
        LC32NativeSetViewTransform(window, target);
    }
    if(!CGPointEqualToPoint(center, targetCenter)) {
        LC32NativeSetViewCenter(window, targetCenter);
    }
    [CATransaction commit];
}

/* A full-screen controller presented inside a turned rootless window (the
 * game's movie player) is laid out by UIKit's legacy window-controller
 * transition from scene geometry, which ignores the window's own turn and
 * puts it off-canvas. As old UIKit did, cover the window with a landscape
 * view, counter-rotated against the window's turn. Returns true when the view
 * is counter-turned (now or already). */
bool LC32FitPresentedViewInTurnedRootlessWindow(UIView *view) {
    UIWindow *window = LC32NativeViewWindow(view);
    UIView *container = LC32NativeViewSuperview(view);
    LC32LegacyRootlessWindowPlacement placement;
    if(!window || !container || !LC32WindowUsesRootlessPhoneCanvas(window) ||
            !LC32ReadRootlessWindowPlacement(window, placement) ||
            placement.yielded) return false;
    CGAffineTransform turn = placement.appliedTransform;
    if(!LC32TransformNearlyEquals(LC32NativeViewTransform(window), turn))
        return false;
    if(LC32WindowIsPortraitHostedLandscape(window)) {
        /* The window itself stays upright; turn the presentation as the
         * window would have been turned for the guest's landscape side. */
        const UIInterfaceOrientation orientation =
            LC32PortraitHostedLandscapeSide();
        turn = CGAffineTransformMakeRotation(
            orientation == UIInterfaceOrientationLandscapeLeft
                ? M_PI_2 : -M_PI_2);
    }
    if(fabs(turn.a) > 0.0001 || fabs(turn.d) > 0.0001) return false;
    UIResponder *next = view.nextResponder;
    if(![next isKindOfClass:UIViewController.class] ||
            !((UIViewController *)next).presentingViewController) return false;
    for(UIView *ancestor = container; ancestor && ancestor != window;
            ancestor = LC32NativeViewSuperview(ancestor)) {
        if(!LC32TransformNearlyEquals(LC32NativeViewTransform(ancestor),
                CGAffineTransformIdentity)) return false;
    }
    const CGFloat scale = hypot(turn.a, turn.b);
    if(!(scale > 0)) return false;
    const CGAffineTransform counterTurn = CGAffineTransformMake(
        turn.a / scale, -turn.b / scale, -turn.c / scale, turn.d / scale, 0, 0);
    const CGRect windowBounds = LC32NativeViewBounds(window);
    const CGPoint center = [container convertPoint:CGPointMake(
            CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds))
        fromView:window];
    const CGRect bounds = CGRectMake(0, 0,
        windowBounds.size.height, windowBounds.size.width);
    const CGPoint childCenter =
        CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    /* The transition also leaves the presented content (AVPlayerView) offset
     * for the scene-sized frame; autoresizing keeps that offset. */
    constexpr UIViewAutoresizing fill =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    auto fillsView = [&](UIView *child) {
        return !LC32ObjectUsesGuestClass(child) &&
            (LC32NativeViewAutoresizingMask(child) & fill) == fill &&
            LC32TransformNearlyEquals(LC32NativeViewTransform(child),
                CGAffineTransformIdentity);
    };
    auto samePoint = [](CGPoint a, CGPoint b) {
        return fabs(a.x - b.x) < 0.01 && fabs(a.y - b.y) < 0.01;
    };
    bool placed =
        LC32TransformNearlyEquals(LC32NativeViewTransform(view), counterTurn) &&
        CGRectEqualToRect(LC32NativeViewBounds(view), bounds) &&
        samePoint(LC32NativeViewCenter(view), center);
    for(UIView *child in placed ? view.subviews : nil) {
        if(fillsView(child) &&
                (!CGRectEqualToRect(LC32NativeViewBounds(child), bounds) ||
                 !samePoint(LC32NativeViewCenter(child), childCenter))) {
            placed = false;
        }
    }
    if(placed) return true;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LC32NativeSetViewTransform(view, counterTurn);
    LC32NativeSetViewBounds(view, bounds);
    LC32NativeSetViewCenter(view, center);
    for(UIView *child in view.subviews) {
        if(!fillsView(child)) continue;
        LC32NativeSetViewBounds(child, bounds);
        LC32NativeSetViewCenter(child, childCenter);
    }
    [CATransaction commit];
    return true;
}

/* UIKit lays a presented view out from scene geometry again when the scene
 * turns: after a landscape flip during Modern Combat 4's logo, AVKit's
 * full-screen container kept our counter-turn but got the 874x402 scene size
 * inside the 320x568 canvas (enlarged, off-centre). The window refits after
 * a device turn or a movie put such views back. Only UIKit's own views are
 * searched; the game's views are left alone. */
void LC32FitPresentedViewsInTurnedRootlessWindow(UIView *view, int depth) {
    for(UIView *child in LC32NativeViewSubviews(view)) {
        if(LC32ObjectUsesGuestClass(child)) continue;
        UIResponder *next = child.nextResponder;
        if([next isKindOfClass:UIViewController.class] &&
                ((UIViewController *)next).presentingViewController) {
            /* Mid-transition the transition itself places it on completion. */
            UIViewController *presented = (UIViewController *)next;
            if(!presented.isBeingPresented && !presented.isBeingDismissed)
                LC32FitPresentedViewInTurnedRootlessWindow(child);
        } else if(depth < 3) {
            LC32FitPresentedViewsInTurnedRootlessWindow(child, depth + 1);
        }
    }
}

/* Landscape phone games that are not given the fixed phone canvas (Unity 3.x
 * universal builds such as Air Mail, which allow both landscape sides) put
 * their renderer straight into a screen-sized portrait window and never
 * install a root controller; the renderer turns itself inside that window.
 * iPhone OS showed such a window unrotated on the portrait panel. In a
 * landscape scene UIKit now leaves it unturned, so only a corner of it is
 * visible. Turn it at the layer above the window, as the old compositor did:
 * the guest's window and view geometry stay portrait (Unity sizes overlays
 * from window.frame) and touches still convert through the layer tree. */
const void *LC32FullScreenRootlessTurnKey = &LC32FullScreenRootlessTurnKey;
const void *LC32FullScreenRootlessObserverKey =
    &LC32FullScreenRootlessObserverKey;

/* On a device whose orientation the scene does not take over (held upright,
 * flat, or at launch from LiveContainer's portrait UI), UIKit presents the
 * turned landscape scene with portrait-sized window layers, and touches then
 * arrive unrotated (see LC32DecidePortraitHostedLandscape). There, do what
 * iPhone OS did on its portrait panel instead: keep the scene portrait, leave
 * the window upright and only turn the renderer's view for the guest's
 * landscape side; it shows the game sideways, as the player holds it. */
enum class LC32FullScreenRootlessShape {
    None, Turned, Hosted, Resync,
    /* UIKit quarter-turns an ancestor for the scene itself (after the phone
     * is turned to the other side): only the renderer's view needs turning. */
    NativeTurned,
};
const void *LC32FullScreenRootlessHostedKey = &LC32FullScreenRootlessHostedKey;
const void *LC32FullScreenRootlessResyncKey = &LC32FullScreenRootlessResyncKey;
const void *LC32FullScreenRootlessNativeResyncKey =
    &LC32FullScreenRootlessNativeResyncKey;

std::atomic<bool> LC32FullScreenRootlessHosting{false};

bool LC32WindowIsFullScreenRootlessHosted(UIWindow *window) {
    return window &&
        objc_getAssociatedObject(window, LC32FullScreenRootlessHostedKey);
}

LC32FullScreenRootlessShape LC32ClassifyFullScreenRootlessWindow(
        UIWindow *window, UIInterfaceOrientation &orientation) {
    using Shape = LC32FullScreenRootlessShape;
    if(!window || !window.guest_selfOrNull ||
            LC32GetGuestExecutableSDKVersion() >= 0x80000 ||
            !LC32NativeLegacyRotationEnabled() ||
            UIDevice.currentDevice.userInterfaceIdiom !=
                UIUserInterfaceIdiomPhone ||
            LC32GuestUsesFixedLandscapePhoneCanvas() ||
            LC32GuestNeedsLegacyIPadCanvas() ||
            LC32NativeWindowRootViewController(window)) return Shape::None;
    const UIInterfaceOrientationMask declared =
        LC32GuestInterfacePolicy().declaredOrientations;
    if(!(declared & UIInterfaceOrientationMaskLandscape) ||
            (declared & (UIInterfaceOrientationMaskPortrait |
                         UIInterfaceOrientationMaskPortraitUpsideDown)))
        return Shape::None;
    UIWindowScene *scene = window.windowScene;
    CALayer *layer = LC32NativeViewLayer(window);
    CALayer *parent = layer.superlayer;
    if(!scene || !parent || LC32ObjectUsesGuestClass(layer) ||
            !LC32TransformNearlyEquals(LC32NativeViewTransform(window),
                CGAffineTransformIdentity)) return Shape::None;
    if(LC32LegacyWindowHasQuarterTurnAncestor(layer)) {
        // Our own earlier turn is removed by the caller.
        if(!UIInterfaceOrientationIsLandscape(scene.interfaceOrientation) ||
                (!CATransform3DIsIdentity(parent.sublayerTransform) &&
                 !objc_getAssociatedObject(parent,
                    LC32FullScreenRootlessTurnKey)))
            return Shape::None;
        orientation = scene.interfaceOrientation;
        return Shape::NativeTurned;
    }
    const CGSize sceneSize = scene.coordinateSpace.bounds.size;
    const CGFloat shortEdge = MIN(sceneSize.width, sceneSize.height);
    const CGFloat longEdge = MAX(sceneSize.width, sceneSize.height);
    const CGSize size = layer.bounds.size;
    const CGSize parentSize = parent.bounds.size;
    constexpr CGFloat epsilon = 0.5;
    // A screen-sized portrait window.
    if(fabs(size.width - shortEdge) > epsilon ||
            fabs(size.height - longEdge) > epsilon) return Shape::None;
    const UIInterfaceOrientation sceneOrientation = scene.interfaceOrientation;
    const bool parentLandscape =
        fabs(parentSize.width - longEdge) < epsilon &&
        fabs(parentSize.height - shortEdge) < epsilon;
    const bool parentPortrait =
        fabs(parentSize.width - shortEdge) < epsilon &&
        fabs(parentSize.height - longEdge) < epsilon;
    /* Follow the scene, not the device reading (it is unknown or briefly
     * upright on a phone held sideways, and UIKit refuses a portrait scene
     * while a landscape-only movie is up): a portrait scene is hosted. */
    if(UIInterfaceOrientationIsPortrait(sceneOrientation)) {
        if(!parentPortrait) return Shape::None;
        orientation = LC32PortraitHostedLandscapeSide();
        return Shape::Hosted;
    }
    if(!UIInterfaceOrientationIsLandscape(sceneOrientation)) return Shape::None;
    orientation = sceneOrientation;
    if(parentLandscape) return Shape::Turned;
    /* Created while the scene was still portrait (LiveContainer's UI): UIKit
     * leaves a rootless window's transform layers portrait when the scene
     * turns, until the app is next activated. */
    return parentPortrait ? Shape::Resync : Shape::None;
}

void LC32RotateFullScreenRootlessController(
        UIWindow *window, UIInterfaceOrientation orientation);


// TEMP device diagnostics for the Air Mail/Starfront landscape report.
void LC32LogFullScreenRootlessState(UIWindow *window, const char *where) {
    static int remaining = 600;
    if(!window || remaining <= 0) return;
    remaining--;
    UIWindowScene *scene = window.windowScene;
    const UIInterfaceOrientationMask declared =
        LC32GuestInterfacePolicy().declaredOrientations;
    UIViewController *root = LC32NativeWindowRootViewController(window);
    fprintf(stderr, "LC32GEO %s win=%p cls=%s guest=%d sdk=%x legacyRot=%d "
        "fixedPhone=%d ipad=%d root=%s declared=%lx io=%ld dev=%ld "
        "sceneDev=%ld scene=(%.0fx%.0f) winTf=[%.2f %.2f]\n",
        where, window, object_getClassName(window),
        window.guest_selfOrNull ? 1 : 0, LC32GetGuestExecutableSDKVersion(),
        (int)LC32NativeLegacyRotationEnabled(),
        (int)LC32GuestUsesFixedLandscapePhoneCanvas(),
        (int)LC32GuestNeedsLegacyIPadCanvas(),
        root ? object_getClassName(root) : "nil", (unsigned long)declared,
        scene ? (long)scene.interfaceOrientation : -1L,
        (long)UIDevice.currentDevice.orientation,
        scene ? (long)LC32SceneDeviceOrientation(scene) : -1L,
        scene.coordinateSpace.bounds.size.width,
        scene.coordinateSpace.bounds.size.height,
        LC32NativeViewTransform(window).a, LC32NativeViewTransform(window).b);
    int depth = 0;
    for(CALayer *layer = LC32NativeViewLayer(window); layer && depth < 6;
            layer = layer.superlayer, depth++) {
        const CATransform3D t = layer.transform;
        const CATransform3D st = layer.sublayerTransform;
        fprintf(stderr, "LC32GEO   %d %s b=(%.0f,%.0f %.0fx%.0f) p=(%.0f,%.0f) "
            "tf=[%.2f %.2f %.2f %.2f] sub=[%.2f %.2f %.1f %.1f]\n", depth,
            object_getClassName(layer), layer.bounds.origin.x,
            layer.bounds.origin.y, layer.bounds.size.width,
            layer.bounds.size.height, layer.position.x, layer.position.y,
            t.m11, t.m12, t.m21, t.m22, st.m11, st.m12, st.m41, st.m42);
    }
    UIView *first = LC32NativeViewSubviews(window).firstObject;
    if(first) {
        const CGRect b = LC32NativeViewBounds(first);
        const CGAffineTransform t = LC32NativeViewTransform(first);
        fprintf(stderr, "LC32GEO   first=%s next=%s b=(%.0fx%.0f) tf=[%.2f %.2f]\n",
            object_getClassName(first),
            object_getClassName(first.nextResponder), b.size.width,
            b.size.height, t.a, t.b);
    }
}

/* TEMP device diagnostics (Air Mail: "only the top half shows the game after
 * holding the phone upright"): dump every scene window shortly after each
 * device orientation change, including the first subview's placement. */
void LC32LogDeviceRotationState(UIWindow *window, const char *where) {
    static int remaining = 80;
    if(!window || remaining <= 0) return;
    remaining--;
    UIWindowScene *scene = window.windowScene;
    const CGRect screen = UIScreen.mainScreen.bounds;
    fprintf(stderr, "LC32ROT %s dev=%ld io=%ld screen=(%.0fx%.0f) "
        "windows=%lu\n", where, (long)UIDevice.currentDevice.orientation,
        scene ? (long)scene.interfaceOrientation : -1L, screen.size.width,
        screen.size.height, (unsigned long)scene.windows.count);
    for(UIWindow *w in scene.windows) {
        LC32LogFullScreenRootlessState(w, where);
        for(UIView *view in LC32NativeViewSubviews(w)) {
            CALayer *layer = LC32NativeViewLayer(view);
            const CGRect frame = layer.frame;
            const CGAffineTransform t = LC32NativeViewTransform(view);
            fprintf(stderr, "LC32ROT   sub %s hidden=%d frame=(%.0f,%.0f %.0fx%.0f)"
                " center=(%.0f,%.0f) tf=[%.2f %.2f %.2f %.2f %.0f %.0f]\n",
                object_getClassName(view), (int)view.hidden, frame.origin.x,
                frame.origin.y, frame.size.width, frame.size.height,
                layer.position.x, layer.position.y, t.a, t.b, t.c, t.d,
                t.tx, t.ty);
        }
    }
}

void LC32FitFullScreenRootlessWindow(UIWindow *window);

/* UIKit can re-lay out the game window by itself without the scene turning
 * (on an iOS 27 device after the intro movie closed, while the scene had
 * turned landscape under a portrait launch): the window's layers become
 * portrait-sized under a quarter-turned root layer, our own landscape turn
 * stays on top, and the game shows sideways in a square at one end. No scene
 * geometry change reports it, so fit again whenever the device turns and
 * after a movie is dismissed; the fit then sees NativeTurned and drops ours. */
void LC32RefitFullScreenRootlessWindowLater(UIWindow *window,
                                            const char *why) {
    if(!window || !window.guest_selfOrNull) return;
    // The game's window lives as long as the process.
    UIWindow *target = window;
    for(int64_t delay : {(int64_t)150, (int64_t)1200}) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                delay * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            LC32LogDeviceRotationState(target, why);
            LC32FitFullScreenRootlessWindow(target);
        });
    }
}

void LC32WatchDeviceRotationForDiagnostics(UIWindow *window) {
    static bool installed;
    if(installed || !window) return;
    installed = true;
    UIWindow *target = window;
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *) {
            LC32RefitFullScreenRootlessWindowLater(target, "devrot");
        }];
}

/* A rootless iPad-only main-nib game (Asphalt 6 HD) keeps its archived
 * 768x1024 window and draws into a 768x1024 EAGL surface, rotating in its
 * own projection. The classic-iPad container needs a guest root controller,
 * so on a phone this window was shown 1:1 in a corner of the scene. Present
 * it as the iPad compositor did: turn the portrait window for a landscape
 * scene and scale it into the scene at the layer above the window, keeping
 * every guest geometry (and touch conversion) in iPad points. */
const void *LC32RootlessIPadTransformKey = &LC32RootlessIPadTransformKey;
const void *LC32RootlessIPadResyncKey = &LC32RootlessIPadResyncKey;
const void *LC32RootlessIPadSideKey = &LC32RootlessIPadSideKey;

bool LC32WindowIsRootlessIPadCanvas(UIWindow *window) {
    if(!window || !window.guest_selfOrNull ||
            !LC32GuestNeedsLegacyIPadCanvas() ||
            LC32GetGuestExecutableSDKVersion() >= 0x80000 ||
            !LC32WindowNeedsLegacyIPadContainer(window)) return false;
    UIViewController *root = LC32NativeWindowRootViewController(window);
    if(root && ![root isKindOfClass:LC32LegacyWindowRootController.class])
        return false;
    CALayer *layer = LC32NativeViewLayer(window);
    const CGSize size = layer.bounds.size;
    constexpr CGFloat epsilon = 0.5;
    return layer && !LC32ObjectUsesGuestClass(layer) &&
        fabs(size.width - 768) < epsilon && fabs(size.height - 1024) < epsilon &&
        LC32TransformNearlyEquals(LC32NativeViewTransform(window),
            CGAffineTransformIdentity);
}

/* A controller presented over such a window (Asphalt's intro movie, shown
 * from a controller whose view is embedded in the EAGLView) is laid out by
 * UIKit's legacy window-controller transition from the phone scene, so it
 * covered only a 402x874 corner of the iPad window. iPhone OS 3.2 covered the
 * whole 768x1024 window, turned for the interface orientation; with the
 * window turned for the scene, that is the counter-turn of our turn. */
void LC32FitPresentedViewInRootlessIPadWindow(UIView *view) {
    UIWindow *window = LC32NativeViewWindow(view);
    UIView *container = LC32NativeViewSuperview(view);
    if(!window || !container || LC32ObjectUsesGuestClass(view) ||
            !LC32WindowIsRootlessIPadCanvas(window)) return;
    CALayer *parent = LC32NativeViewLayer(window).superlayer;
    NSValue *applied = objc_getAssociatedObject(
        parent, LC32RootlessIPadTransformKey);
    if(!applied) return;
    UIResponder *next = view.nextResponder;
    if(![next isKindOfClass:UIViewController.class] ||
            !((UIViewController *)next).presentingViewController) return;
    for(UIView *ancestor = container; ancestor && ancestor != window;
            ancestor = LC32NativeViewSuperview(ancestor)) {
        if(!LC32TransformNearlyEquals(LC32NativeViewTransform(ancestor),
                CGAffineTransformIdentity)) return;
    }
    CATransform3D turn;
    [applied getValue:&turn size:sizeof(turn)];
    const CGFloat scale = hypot(turn.m11, turn.m12);
    if(!(scale > 0)) return;
    const CGAffineTransform counterTurn = CGAffineTransformMake(
        turn.m11 / scale, -turn.m12 / scale, -turn.m21 / scale,
        turn.m22 / scale, 0, 0);
    const bool quarter = fabs(counterTurn.a) < 0.0001;
    const CGRect windowBounds = LC32NativeViewBounds(window);
    const CGPoint center = [container convertPoint:CGPointMake(
            CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds))
        fromView:window];
    const CGRect bounds = quarter
        ? CGRectMake(0, 0, windowBounds.size.height, windowBounds.size.width)
        : CGRectMake(0, 0, windowBounds.size.width, windowBounds.size.height);
    if(LC32TransformNearlyEquals(LC32NativeViewTransform(view), counterTurn) &&
            CGSizeEqualToSize(LC32NativeViewBounds(view).size, bounds.size) &&
            CGPointEqualToPoint(LC32NativeViewCenter(view), center)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LC32NativeSetViewTransform(view, counterTurn);
    LC32NativeSetViewBounds(view, bounds);
    LC32NativeSetViewCenter(view, center);
    // The transition leaves the content (AVPlayerView) offset; refill it.
    for(UIView *child in view.subviews) {
        if(LC32ObjectUsesGuestClass(child) ||
                !LC32TransformNearlyEquals(LC32NativeViewTransform(child),
                    CGAffineTransformIdentity)) continue;
        LC32NativeSetViewBounds(child, bounds);
        LC32NativeSetViewCenter(child,
            CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)));
    }
    [CATransaction commit];
    fprintf(stderr, "LC32: presented %s covers rootless iPad window\n",
        object_getClassName(next));
}

void LC32FitPresentedViewsInRootlessIPadWindow(UIView *view, int depth) {
    for(UIView *child in LC32NativeViewSubviews(view)) {
        UIResponder *next = child.nextResponder;
        if([next isKindOfClass:UIViewController.class] &&
                ((UIViewController *)next).presentingViewController) {
            LC32FitPresentedViewInRootlessIPadWindow(child);
        } else if(depth < 3) {
            LC32FitPresentedViewsInRootlessIPadWindow(child, depth + 1);
        }
    }
}

/* Returns false when the window is not such a canvas (callers continue). */
bool LC32FitRootlessIPadWindow(UIWindow *window) {
    if(!LC32WindowIsRootlessIPadCanvas(window)) return false;
    CALayer *layer = LC32NativeViewLayer(window);
    CALayer *parent = layer.superlayer;
    UIWindowScene *scene = window.windowScene;
    if(!parent || !scene) return true;
    NSValue *applied = objc_getAssociatedObject(
        parent, LC32RootlessIPadTransformKey);
    if(applied) {
        CATransform3D appliedTransform;
        [applied getValue:&appliedTransform size:sizeof(appliedTransform)];
        if(!CATransform3DEqualToTransform(
                parent.sublayerTransform, appliedTransform)) {
            objc_setAssociatedObject(parent, LC32RootlessIPadTransformKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return true;
        }
    } else if(!CATransform3DIsIdentity(parent.sublayerTransform)) {
        return true;
    }

    UIInterfaceOrientation orientation = scene.interfaceOrientation;
    const CGRect parentBounds = parent.bounds;
    const bool parentLandscape =
        parentBounds.size.width > parentBounds.size.height;
    if(UIInterfaceOrientationIsLandscape(orientation)) {
        objc_setAssociatedObject(window, LC32RootlessIPadSideKey,
            @(orientation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if(parentLandscape) {
        /* The scene briefly reads portrait while its layers are already
         * landscape (around the movie's presentation); keep the last side. */
        NSNumber *side = objc_getAssociatedObject(
            window, LC32RootlessIPadSideKey);
        const UIInterfaceOrientation preferred =
            LC32GuestInterfacePolicy().preferredOrientation;
        orientation = side ? (UIInterfaceOrientation)side.integerValue
            : UIInterfaceOrientationIsLandscape(preferred) ? preferred
            : UIInterfaceOrientationLandscapeRight;
    }
    CGFloat angle = 0;
    if(LC32LegacyWindowHasQuarterTurnAncestor(layer)) {
        // UIKit already turns an ancestor for the scene; only scale.
        angle = 0;
    } else if(UIInterfaceOrientationIsLandscape(orientation)) {
        if(!parentLandscape) {
            /* Created while the scene was portrait: UIKit leaves a rootless
             * window's transform layers portrait until it is asked again. */
            if(!objc_getAssociatedObject(window, LC32RootlessIPadResyncKey)) {
                objc_setAssociatedObject(window, LC32RootlessIPadResyncKey,
                    @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                SEL update = sel_registerName("_updateTransformLayer");
                if([window respondsToSelector:update]) {
                    ((void (*)(id, SEL))objc_msgSend)(window, update);
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    LC32FitRootlessIPadWindow(window);
                });
                return true;
            }
        } else {
            angle = orientation == UIInterfaceOrientationLandscapeLeft
                ? M_PI_2 : -M_PI_2;
        }
    }
    if(parentLandscape == UIInterfaceOrientationIsLandscape(orientation)) {
        objc_setAssociatedObject(window, LC32RootlessIPadResyncKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    const CGSize windowSize = layer.bounds.size;
    const CGSize shownSize = angle != 0
        ? CGSizeMake(windowSize.height, windowSize.width) : windowSize;
    const CGFloat scale = MIN(parentBounds.size.width / shownSize.width,
                              parentBounds.size.height / shownSize.height);
    if(!(scale > 0) || !isfinite(scale)) return true;
    /* sublayerTransform applies about the parent's anchor point: map the
     * window's center there, then move it onto the parent's center. */
    const CGPoint anchor = {
        parentBounds.origin.x +
            parent.anchorPoint.x * parentBounds.size.width,
        parentBounds.origin.y +
            parent.anchorPoint.y * parentBounds.size.height,
    };
    CGAffineTransform turn = CGAffineTransformScale(
        CGAffineTransformMakeRotation(angle), scale, scale);
    const CGPoint offset = CGPointApplyAffineTransform(CGPointMake(
        layer.position.x - anchor.x, layer.position.y - anchor.y), turn);
    turn.tx = CGRectGetMidX(parentBounds) - anchor.x - offset.x;
    turn.ty = CGRectGetMidY(parentBounds) - anchor.y - offset.y;
    const CATransform3D target = CATransform3DMakeAffineTransform(turn);
    if(!CATransform3DEqualToTransform(parent.sublayerTransform, target)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        parent.sublayerTransform = target;
        [CATransaction commit];
        static int remaining = 40;
        if(remaining > 0) {
            remaining--;
            fprintf(stderr, "LC32: rootless iPad window fitted io=%ld "
                "parent=(%.0fx%.0f) angle=%.0f scale=%.3f\n", (long)orientation,
                parentBounds.size.width, parentBounds.size.height,
                angle * 180 / M_PI, scale);
        }
    }
    objc_setAssociatedObject(parent, LC32RootlessIPadTransformKey,
        [NSValue valueWithBytes:&target objCType:@encode(CATransform3D)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LC32FitPresentedViewsInRootlessIPadWindow(window, 0);
    if(!objc_getAssociatedObject(scene, LC32FullScreenRootlessObserverKey)) {
        LC32FullScreenRootlessGeometryObserver *observer =
            [LC32FullScreenRootlessGeometryObserver new];
        observer.window = window;
        [scene addObserver:observer forKeyPath:@"effectiveGeometry"
                   options:0 context:nullptr];
        objc_setAssociatedObject(scene, LC32FullScreenRootlessObserverKey,
            observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#if !__has_feature(objc_arc)
        [observer release];
#endif
    }
    return true;
}

extern "C" bool LC32UIKitGuestStatusBarOrientationIsCosmetic(
        UIWindow *guestKeyWindow);

/* A pre-iOS-6, portrait-only game window without a root controller never
 * rotated on iPhone OS (H.A.W.X. draws its landscape picture into the
 * portrait drawable and flips it from UIDevice.orientation itself). Without
 * a controller, current UIKit gives the scene LiveContainer's all-orientations
 * mask, so it turned with the phone under the portrait canvas. Neither the
 * application mask nor window autorotation queries change that; only the
 * top visible window's root controller does. Keep a transparent host window
 * that ignores touches above the game, whose controller allows portrait. */
extern "C" bool LC32WindowKeepsLegacyPortrait(UIWindow *window) {
    /* A fixed phone canvas turns with a landscape scene instead (see
     * LC32UIKitGuestFixedCanvasDeviceOrientation). */
    return [window isKindOfClass:UIWindow.class] && window.guest_selfOrNull &&
        !LC32GuestUsesFixedLandscapePhoneCanvas() &&
        LC32UIKitGuestStatusBarOrientationIsCosmetic(window);
}

}  // namespace

@interface LC32LegacyPortraitAnchorController : UIViewController
@end

@implementation LC32LegacyPortraitAnchorController
- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    view.userInteractionEnabled = NO;
    self.view = view;
#if !__has_feature(objc_arc)
    [view release];
#endif
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationPortrait;
}
- (BOOL)shouldAutorotate { return NO; }
- (BOOL)prefersStatusBarHidden {
    return LC32GuestInterfacePolicy().statusBarHidden;
}
@end

namespace {

/* The scene's orientation follows the key window. A rootless key window has
 * no controller, so UIKit derives its mask from the application (the guest
 * Info.plist), and a guest declaring portrait and landscape (Modern Combat 4)
 * let FrontBoard turn the scene with the phone before the anchor could pull
 * it back. Report portrait for that window itself; the application mask is
 * left alone so presented landscape controllers still find a common side. */
static void LC32RetireStaleLegacyPortraitAnchor(UIWindowScene *scene);

static IMP LC32OriginalWindowSupportedOrientationsConsultingApp;

/* Modern Combat 4's logo movie leaves AVKit's AVFullScreenViewController
 * presented on the synthetic root of its fixed-canvas window for the rest of
 * the run. It names no orientations, so UIKit falls back to the guest plist
 * (portrait and both landscape sides) and turned the scene with the phone:
 * portrait after a sideways launch (picture cropped), landscape under a
 * portrait-hosted window (picture sideways in a strip). Let the synthetic
 * root's policy decide for that window. */
static bool LC32WindowFollowsFixedCanvasRootPolicy(
        UIWindow *window, UIViewController *&root) {
    if(![window isKindOfClass:UIWindow.class] || !window.guest_selfOrNull ||
            !LC32UIKitGuestFixedCanvasDeviceOrientation(nullptr)) return false;
    root = LC32NativeWindowRootViewController(window);
    return [root isKindOfClass:LC32LegacyWindowRootController.class];
}

static UIInterfaceOrientationMask LC32WindowSupportedOrientationsConsultingApp(
        UIWindow *self, SEL cmd, BOOL consultApp) {
    const UIInterfaceOrientationMask mask =
        ((UIInterfaceOrientationMask (*)(id, SEL, BOOL))
            LC32OriginalWindowSupportedOrientationsConsultingApp)(
                self, cmd, consultApp);
    UIViewController *fixedCanvasRoot = nil;
    if(LC32WindowFollowsFixedCanvasRootPolicy(self, fixedCanvasRoot)) {
        const UIInterfaceOrientationMask policy =
            [fixedCanvasRoot supportedInterfaceOrientations];
        if(!policy) return mask;
        /* While hosted the root alone decides: a presented landscape-only
         * controller must not turn the scene under an upright phone. */
        if(LC32WindowIsPortraitHosted(self)) return policy;
        const UIInterfaceOrientationMask common = mask & policy;
        return common ? common : policy;
    }
    if(!(mask & UIInterfaceOrientationMaskPortrait) ||
            !LC32WindowKeepsLegacyPortrait(self)) return mask;
    return UIInterfaceOrientationMaskPortrait;
}

static void LC32InstallLegacyPortraitWindowMask(void) {
    static bool installed;
    if(installed) return;
    installed = true;
    Method method = class_getInstanceMethod(UIWindow.class,
        sel_registerName("_supportedInterfaceOrientationsConsultingApp:"));
    if(!method) {
        fprintf(stderr, "LC32: no UIWindow orientation-mask method; the "
            "portrait anchor alone keeps the legacy scene portrait\n");
        return;
    }
    LC32OriginalWindowSupportedOrientationsConsultingApp =
        method_setImplementation(method,
            (IMP)LC32WindowSupportedOrientationsConsultingApp);
}

/* One anchor per scene (UIKit.mm is non-ARC: the tables are retained once),
 * and the guest window it currently stands in for. */
static NSMapTable<UIWindowScene *, UIWindow *> *LC32LegacyPortraitAnchors(void) {
    static NSMapTable<UIWindowScene *, UIWindow *> *anchors;
    if(!anchors) {
        anchors = [NSMapTable weakToStrongObjectsMapTable];
#if !__has_feature(objc_arc)
        [anchors retain];
#endif
    }
    return anchors;
}

static NSMapTable<UIWindowScene *, UIWindow *> *
LC32LegacyPortraitAnchorOwners(void) {
    static NSMapTable<UIWindowScene *, UIWindow *> *owners;
    if(!owners) {
        owners = [NSMapTable weakToWeakObjectsMapTable];
#if !__has_feature(objc_arc)
        [owners retain];
#endif
    }
    return owners;
}

static void LC32InstallLegacyPortraitAnchor(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    if(!scene) return;
    LC32InstallLegacyPortraitWindowMask();
    NSMapTable<UIWindowScene *, UIWindow *> *anchors =
        LC32LegacyPortraitAnchors();
    [LC32LegacyPortraitAnchorOwners() setObject:window forKey:scene];
    UIWindow *existing = [anchors objectForKey:scene];
    if(existing) {
        if(existing.hidden) {
            existing.hidden = NO;
            if(@available(iOS 16.0, *))
                [existing.rootViewController
                    setNeedsUpdateOfSupportedInterfaceOrientations];
            fprintf(stderr, "LC32: portrait anchor window restored\n");
        }
        return;
    }
    UIWindow *anchor = [[UIWindow alloc] initWithWindowScene:scene];
    anchor.windowLevel = UIWindowLevelNormal + 5;
    anchor.backgroundColor = UIColor.clearColor;
    anchor.opaque = NO;
    anchor.userInteractionEnabled = NO;
    UIViewController *controller =
        [[LC32LegacyPortraitAnchorController alloc] initWithNibName:nil
                                                             bundle:nil];
    anchor.rootViewController = controller;
    anchor.hidden = NO;
    [anchors setObject:anchor forKey:scene];
    if(@available(iOS 16.0, *))
        [controller setNeedsUpdateOfSupportedInterfaceOrientations];
    fprintf(stderr, "LC32: portrait anchor window installed for a "
        "portrait-only rootless legacy window\n");
#if !__has_feature(objc_arc)
    [controller release];
    [anchor release];
#endif
}

/* Install the anchor, and if the scene is already landscape (the phone was
 * held sideways at launch), ask for portrait back. */
static void LC32RestoreLegacyPortraitScene(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    if(!LC32WindowKeepsLegacyPortrait(window)) {
        // The window the anchor stands in for may have gained a root.
        if(scene && [LC32LegacyPortraitAnchorOwners() objectForKey:scene] ==
                window)
            LC32RetireStaleLegacyPortraitAnchor(scene);
        return;
    }
    LC32InstallLegacyPortraitAnchor(window);
    if(!scene || !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation))
        return;
    if(@available(iOS 16.0, *)) {
        fprintf(stderr, "LC32: portrait-only legacy window in a landscape "
            "scene (%ld); requesting portrait\n",
            (long)scene.interfaceOrientation);
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc]
                initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait];
        [scene requestGeometryUpdateWithPreferences:preferences
            errorHandler:^(NSError *error) {
                fprintf(stderr, "LC32: portrait request failed: %s\n",
                    error.localizedDescription.UTF8String ?: "?");
            }];
#if !__has_feature(objc_arc)
        [preferences release];
#endif
    }
}

void LC32ScheduleRootlessWindowLayerLayout(UIWindow *window);

void LC32FitFullScreenRootlessWindow(UIWindow *window) {
    LC32RestoreLegacyPortraitScene(window);
    if(LC32FitRootlessIPadWindow(window)) return;
    if(LC32WindowUsesRootlessPhoneCanvas(window)) {
        LC32FitPresentedViewsInTurnedRootlessWindow(window, 0);
        /* A device turn can make UIKit rebuild the window's transform
         * layers without laying out anything of ours (9mm). */
        LC32ScheduleRootlessWindowLayerLayout(window);
    }
    if(window.guest_selfOrNull) LC32WatchDeviceRotationForDiagnostics(window);
    LC32LogFullScreenRootlessState(window,
        LC32WindowIsFullScreenRootlessHosted(window) ? "fit(hosted)" : "fit");
    CALayer *layer = LC32NativeViewLayer(window);
    CALayer *parent = layer.superlayer;
    if(!parent) return;
    NSValue *applied = objc_getAssociatedObject(
        parent, LC32FullScreenRootlessTurnKey);
    if(applied) {
        CATransform3D appliedTransform;
        [applied getValue:&appliedTransform size:sizeof(appliedTransform)];
        if(!CATransform3DEqualToTransform(
                parent.sublayerTransform, appliedTransform)) {
            // Another owner replaced it; leave theirs alone from now on.
            objc_setAssociatedObject(parent, LC32FullScreenRootlessTurnKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
    } else if(!CATransform3DIsIdentity(parent.sublayerTransform)) {
        return;
    }
    UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
    const LC32FullScreenRootlessShape shape =
}  // namespace

/* The anchor stands in for a guest window that iPhone OS never rotated. When
 * that window later gets a rotating root controller of its own (installed
 * after the anchor went up) or goes away, the guest's controller decides the
 * scene again: hide the anchor rather than pin the scene to portrait. */
static void LC32RetireStaleLegacyPortraitAnchor(UIWindowScene *scene) {
    UIWindow *anchor = scene ? [LC32LegacyPortraitAnchors() objectForKey:scene]
                             : nil;
    if(!anchor || anchor.hidden) return;
    UIWindow *owner = [LC32LegacyPortraitAnchorOwners() objectForKey:scene];
    if(owner && owner.windowScene == scene &&
            LC32WindowKeepsLegacyPortrait(owner)) return;
    anchor.hidden = YES;
    fprintf(stderr, "LC32: portrait anchor window retired (%s)\n",
        owner ? "guest window is no longer a portrait-only rootless window"
              : "guest window is gone");
    UIViewController *root =
        owner ? LC32NativeWindowRootViewController(owner) : nil;
    if(@available(iOS 16.0, *))
        [root setNeedsUpdateOfSupportedInterfaceOrientations];
}

/* LegacyRotation.mm's -[UIWindow setRootViewController:] hook: a root
 * installed after the anchor went up decides the scene from now on. */
extern "C" void LC32UIKitWindowRootControllerChanged(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    if(!scene ||
            [LC32LegacyPortraitAnchorOwners() objectForKey:scene] != window)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        LC32RetireStaleLegacyPortraitAnchor(scene);
    });
}

namespace {

        LC32ClassifyFullScreenRootlessWindow(window, orientation);
    {
        static int remaining = 100;
        if(remaining > 0 && shape != LC32FullScreenRootlessShape::None) {
            remaining--;
            fprintf(stderr, "LC32GEO shape=%d orientation=%ld\n",
                (int)shape, (long)orientation);
        }
    }
    if(shape != LC32FullScreenRootlessShape::Turned) {
        if(applied) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            parent.sublayerTransform = CATransform3DIdentity;
            [CATransaction commit];
            objc_setAssociatedObject(parent, LC32FullScreenRootlessTurnKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if(shape == LC32FullScreenRootlessShape::Hosted) {
            objc_setAssociatedObject(window, LC32FullScreenRootlessHostedKey,
                @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LC32FullScreenRootlessHosting.store(true, std::memory_order_release);
            objc_setAssociatedObject(window, LC32FullScreenRootlessResyncKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(window, LC32FullScreenRootlessNativeResyncKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LC32RotateFullScreenRootlessController(window, orientation);
            return;
        }
        if(LC32WindowIsFullScreenRootlessHosted(window)) {
            objc_setAssociatedObject(window, LC32FullScreenRootlessHostedKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LC32FullScreenRootlessHosting.store(false, std::memory_order_release);
        }
        if(shape == LC32FullScreenRootlessShape::NativeTurned) {
            /* UIKit sometimes lays this window out portrait-sized under a
             * quarter-turned root layer while the scene is landscape (iOS 27
             * device: launched upright, the intro movie turned the scene).
             * Shown that way the game and its movies land sideways in a
             * square at one end of the screen. Asking UIKit to rebuild the
             * window's transform layers returns it to the landscape shape
             * we turn ourselves (Turned). Once per episode; a Turned or
             * Hosted fit re-arms it. */
            NSNumber *tries = objc_getAssociatedObject(window,
                LC32FullScreenRootlessNativeResyncKey);
            SEL update = sel_registerName("_updateTransformLayer");
            /* Only a presented movie (or its transition) needs it: the game's
             * own controller view is turned correctly below that root. */
            UIResponder *firstNext =
                LC32NativeViewSubviews(window).firstObject.nextResponder;
            static Class movieController =
                NSClassFromString(@"MPMoviePlayerViewController");
            const bool presenting =
                ![firstNext isKindOfClass:UIViewController.class] ||
                (movieController && [firstNext isKindOfClass:movieController]);
            if(presenting && tries.intValue < 6 &&
                    [window respondsToSelector:update]) {
                objc_setAssociatedObject(window,
                    LC32FullScreenRootlessNativeResyncKey,
                    @(tries.intValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                fprintf(stderr, "LC32: natively turned full-screen window; "
                    "rebuilding its transform layers (try %d)\n",
                    tries.intValue + 1);
                ((void (*)(id, SEL))objc_msgSend)(window, update);
                // UIKit may turn it again while a presentation settles.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                        400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    LC32FitFullScreenRootlessWindow(window);
                });
            }
            LC32RotateFullScreenRootlessController(window, orientation);
            return;
        }
        if(shape == LC32FullScreenRootlessShape::Resync) {
            // One attempt per stale episode; a later good fit re-arms it.
            if(objc_getAssociatedObject(window, LC32FullScreenRootlessResyncKey))
                return;
            objc_setAssociatedObject(window, LC32FullScreenRootlessResyncKey,
                @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SEL update = sel_registerName("_updateTransformLayer");
            if([window respondsToSelector:update]) {
                ((void (*)(id, SEL))objc_msgSend)(window, update);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                LC32FitFullScreenRootlessWindow(window);
            });
        }
        return;
    }
    /* sublayerTransform applies about the parent's anchor point: turn the
     * window's center there, then move it back onto the parent's center. */
    const CGRect parentBounds = parent.bounds;
    const CGPoint anchor = {
        parentBounds.origin.x +
            parent.anchorPoint.x * parentBounds.size.width,
        parentBounds.origin.y +
            parent.anchorPoint.y * parentBounds.size.height,
    };
    CGAffineTransform turn = CGAffineTransformMakeRotation(
        orientation == UIInterfaceOrientationLandscapeLeft ? M_PI_2 : -M_PI_2);
    const CGPoint offset = CGPointApplyAffineTransform(CGPointMake(
        layer.position.x - anchor.x, layer.position.y - anchor.y), turn);
    turn.tx = CGRectGetMidX(parentBounds) - anchor.x - offset.x;
    turn.ty = CGRectGetMidY(parentBounds) - anchor.y - offset.y;
    const CATransform3D target = CATransform3DMakeAffineTransform(turn);
    if(!CATransform3DEqualToTransform(parent.sublayerTransform, target)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        parent.sublayerTransform = target;
        [CATransaction commit];
    }
    objc_setAssociatedObject(parent, LC32FullScreenRootlessTurnKey,
        [NSValue valueWithBytes:&target objCType:@encode(CATransform3D)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, LC32FullScreenRootlessResyncKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, LC32FullScreenRootlessNativeResyncKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LC32RotateFullScreenRootlessController(window, orientation);
}

/* Before iOS 6, UIKit autorotated the controller owning a window's first
 * subview even without a root controller; Unity 3.x relies on that (it never
 * sets one) and switches its renderer to landscape from those callbacks. Do
 * the same in the turned window: turn that view to the landscape side with
 * landscape bounds and send the deprecated rotation callbacks. */
const void *LC32FullScreenRootlessControllerOrientationKey =
    &LC32FullScreenRootlessControllerOrientationKey;

void LC32RotateFullScreenRootlessController(
        UIWindow *window, UIInterfaceOrientation orientation) {
    /* iPhone OS delivered the launch rotation after startup; Unity resizes
     * its surface on didRotate only once rendering has begun. */
    if(!LC32CanQueryGuestOrientation()) return;
    UIView *view = LC32NativeViewSubviews(window).firstObject;
    UIResponder *next = view.nextResponder;
    if(!view || ![next isKindOfClass:UIViewController.class] ||
            !LC32ObjectUsesGuestClass(next)) return;
    UIViewController *controller = (UIViewController *)next;
    const CGAffineTransform target = CGAffineTransformMakeRotation(
        orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 : M_PI_2);
    const CGAffineTransform current = LC32NativeViewTransform(view);
    if(LC32TransformNearlyEquals(current, target)) return;
    // Only from the untouched portrait view or the other landscape side.
    if(!LC32TransformNearlyEquals(current, CGAffineTransformIdentity) &&
            !LC32TransformNearlyEquals(current, CGAffineTransformInvert(target)))
        return;
    SEL should = @selector(shouldAutorotateToInterfaceOrientation:);
    if([controller respondsToSelector:should] &&
            !((BOOL (*)(id, SEL, UIInterfaceOrientation))objc_msgSend)(
                controller, should, orientation)) return;
    NSNumber *previous = objc_getAssociatedObject(
        controller, LC32FullScreenRootlessControllerOrientationKey);
    const UIInterfaceOrientation from = previous
        ? (UIInterfaceOrientation)previous.integerValue
        : UIInterfaceOrientationPortrait;
    objc_setAssociatedObject(controller,
        LC32FullScreenRootlessControllerOrientationKey, @(orientation),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [controller willRotateToInterfaceOrientation:orientation duration:0];
    const CGRect windowBounds = LC32NativeViewBounds(window);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LC32NativeSetViewTransform(view, target);
    LC32NativeSetViewBounds(view, CGRectMake(0, 0,
        windowBounds.size.height, windowBounds.size.width));
    LC32NativeSetViewCenter(view, CGPointMake(
        CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds)));
    [CATransaction commit];
    [controller didRotateFromInterfaceOrientation:from];
}

/* From makeKeyAndVisible: the scene may still be portrait (or settle on the
 * other landscape side) afterwards, so keep refitting on geometry changes. */
void LC32WatchFullScreenRootlessWindow(UIWindow *window) {
    const UIInterfaceOrientationMask declared =
        LC32GuestInterfacePolicy().declaredOrientations;
    if(!window || !window.guest_selfOrNull ||
            LC32GetGuestExecutableSDKVersion() >= 0x80000 ||
            LC32GuestUsesFixedLandscapePhoneCanvas() ||
            !(declared & UIInterfaceOrientationMaskLandscape) ||
            (declared & (UIInterfaceOrientationMaskPortrait |
                         UIInterfaceOrientationMaskPortraitUpsideDown)))
        return;
    LC32FitFullScreenRootlessWindow(window);
    UIWindowScene *scene = window.windowScene;
    if(scene && !objc_getAssociatedObject(
            scene, LC32FullScreenRootlessObserverKey)) {
        LC32FullScreenRootlessGeometryObserver *observer =
            [LC32FullScreenRootlessGeometryObserver new];
        observer.window = window;
        [scene addObserver:observer forKeyPath:@"effectiveGeometry"
                   options:0 context:nullptr];
        objc_setAssociatedObject(scene, LC32FullScreenRootlessObserverKey,
            observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#if !__has_feature(objc_arc)
        [observer release];
#endif
    }
}

/* UIKit's legacy window-controller transition centers a full-window
 * presented movie (and, on dismissal, the restored renderer) from scene
 * geometry, which no longer matches the turned portrait window. */
void LC32FitViewInFullScreenRootlessWindow(UIView *view) {
    UIWindow *window = LC32NativeViewWindow(view);
    if(!window || LC32NativeViewSuperview(view) != window) return;
    LC32FitFullScreenRootlessWindow(window);
    CALayer *parent = LC32NativeViewLayer(window).superlayer;
    if(!LC32WindowIsFullScreenRootlessHosted(window) && (!parent ||
            !objc_getAssociatedObject(parent, LC32FullScreenRootlessTurnKey)))
        return;
    const CGRect windowBounds = LC32NativeViewBounds(window);
    const CGRect bounds = LC32NativeViewBounds(view);
    const CGSize size = CGRectApplyAffineTransform(
        bounds, LC32NativeViewTransform(view)).size;
    constexpr CGFloat epsilon = 0.5;
    if(fabs(size.width - windowBounds.size.width) > epsilon ||
            fabs(size.height - windowBounds.size.height) > epsilon) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LC32NativeSetViewCenter(view, CGPointMake(
        CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds)));
    // The movie's AVPlayerView keeps the transition's offset (see above).
    constexpr UIViewAutoresizing fill =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    for(UIView *child in LC32NativeViewSubviews(view)) {
        if(LC32ObjectUsesGuestClass(child) ||
                (LC32NativeViewAutoresizingMask(child) & fill) != fill ||
                !LC32TransformNearlyEquals(LC32NativeViewTransform(child),
                    CGAffineTransformIdentity)) continue;
        LC32NativeSetViewBounds(child, bounds);
        LC32NativeSetViewCenter(child,
            CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)));
    }
    [CATransaction commit];
}

bool LC32FitLegacyDirectWindowLayers(UIWindow *window) {
    if(!window) return false;

    NSNumber *directRootState = objc_getAssociatedObject(
        window, LC32HideLegacyDirectGuestWindowRootKey);
    NSValue *savedTransform = objc_getAssociatedObject(
        window, LC32LegacyDirectWindowSublayerTransformKey);
    CALayer *windowLayer = LC32NativeViewLayer(window);
    UIViewController *nativeRoot = LC32NativeWindowRootViewController(window);
    const bool rootlessPhoneCanvas = LC32WindowUsesRootlessPhoneCanvas(window);
    if(rootlessPhoneCanvas) LC32PreserveRootlessRendererAutoresizing(window);
    else LC32RestoreRootlessRendererAutoresizing(window);
    const bool ownsWindowPlacement = LC32ReconcileRootlessWindowPlacement(
        window, windowLayer, !rootlessPhoneCanvas);
    if(!directRootState.boolValue && !rootlessPhoneCanvas) {
        LC32RestoreLegacyDirectWindowSublayerTransform(
            window, windowLayer, savedTransform);
        return false;
    }

    /* This path emulates the pre-scene UIWindow compositor for main-nib
     * games whose renderer and hidden bookkeeping root are direct siblings,
     * or rootless engines with a nested, fixed portrait drawable.
     * Changing UIView geometry or reparenting either object synchronously
     * invokes the guest EAGLView's layoutSubviews before engine-owned state
     * is initialized. A parent-layer transform changes presentation and
     * coordinate conversion without invalidating that 320x480 drawable. */
    if(!windowLayer) return true;
    if(rootlessPhoneCanvas && LC32ObjectUsesGuestClass(windowLayer))
        return true;
    static const bool isCoreSimulator =
        getenv("SIMULATOR_UDID") != nullptr ||
        getenv("SIMULATOR_DEVICE_NAME") != nullptr;
    if(!isCoreSimulator && !rootlessPhoneCanvas) {
        LC32RestoreLegacyDirectWindowSublayerTransform(
            window, windowLayer, savedTransform);
        return true;
    }

    NSValue *appliedValue = objc_getAssociatedObject(
        window, LC32LegacyDirectWindowAppliedSublayerTransformKey);
    if(savedTransform && appliedValue) {
        CATransform3D originalTransform;
        CATransform3D appliedTransform;
        [savedTransform getValue:&originalTransform
                            size:sizeof(originalTransform)];
        [appliedValue getValue:&appliedTransform
                          size:sizeof(appliedTransform)];
        const CATransform3D currentTransform = windowLayer.sublayerTransform;
        if(!CATransform3DEqualToTransform(
                currentTransform, originalTransform) &&
                !CATransform3DEqualToTransform(
                    currentTransform, appliedTransform)) {
            /* UIKit or another owner replaced our compositor transform.
             * Preserve it and discard the stale restore point instead of
             * overwriting it on this pass or during later cleanup. */
            objc_setAssociatedObject(
                window, LC32LegacyDirectWindowSublayerTransformKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(
                window,
                LC32LegacyDirectWindowAppliedSublayerTransformKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            savedTransform = nil;
        }
    }
    const CGRect windowBounds = windowLayer.bounds;
    /* With native legacy rotation (the host reports the guest's pre-iOS-8
     * SDK) UIKit keeps the window portrait and turns only root views, as
     * iOS 7 did. A rootless renderer then rotates inside its own portrait
     * surface, so the old compositor only scaled and centered it. */
    const bool portraitRootlessWindow = rootlessPhoneCanvas &&
        LC32NativeLegacyRotationEnabled() &&
        windowBounds.size.height > windowBounds.size.width;
    const CATransform3D allowedWindowTransform = ownsWindowPlacement
        ? windowLayer.transform : CATransform3DIdentity;
    const bool alreadyHasNativeCompositor =
        (!ownsWindowPlacement && !LC32TransformNearlyEquals(
            LC32NativeViewTransform(window), CGAffineTransformIdentity)) ||
        (rootlessPhoneCanvas &&
         LC32LegacyWindowHasAncestorCompositor(
             windowLayer, allowedWindowTransform,
             portraitRootlessWindow)) ||
        (!savedTransform &&
         !CATransform3DIsIdentity(windowLayer.sublayerTransform));
    if(alreadyHasNativeCompositor ||
            (!(windowBounds.size.width > windowBounds.size.height) &&
             !portraitRootlessWindow)) {
        LC32ReconcileRootlessWindowPlacement(window, windowLayer, true);
        LC32RestoreLegacyDirectWindowSublayerTransform(
            window, windowLayer, savedTransform);
        return true;
    }

    Class eaglLayerClass = NSClassFromString(@"CAEAGLLayer");
    CALayer *portraitRenderer = nil;
    if(rootlessPhoneCanvas && eaglLayerClass) {
        unsigned remainingLayers = 1024;
        for(CALayer *layer in windowLayer.sublayers) {
            if(!LC32FindLegacyNestedPortraitRenderer(layer, eaglLayerClass,
                    true, 0, remainingLayers, portraitRenderer)) {
                LC32ReconcileRootlessWindowPlacement(window, windowLayer, true);
                LC32RestoreLegacyDirectWindowSublayerTransform(
                    window, windowLayer, savedTransform);
                return true;
            }
        }
    } else {
        for(CALayer *layer in windowLayer.sublayers) {
            if(eaglLayerClass && [layer isKindOfClass:eaglLayerClass]) {
                const CGRect bounds = layer.bounds;
                if(fabs(bounds.size.width - 320) < 0.5 &&
                        fabs(bounds.size.height -
                            LC32GuestPhoneCanvasLongEdge()) < 0.5) {
                    if(portraitRenderer) {
                        LC32RestoreLegacyDirectWindowSublayerTransform(
                            window, windowLayer, savedTransform);
                        return true;
                    }
                    portraitRenderer = layer;
                }
            }
        }
    }
    if(!portraitRenderer || !LC32TransformNearlyEquals(
            portraitRenderer.affineTransform,
            CGAffineTransformIdentity)) {
        LC32ReconcileRootlessWindowPlacement(window, windowLayer, true);
        LC32RestoreLegacyDirectWindowSublayerTransform(
            window, windowLayer, savedTransform);
        return true;
    }

    const UIInterfaceOrientation orientation =
        rootlessPhoneCanvas ? LC32LegacyTargetOrientation(nativeRoot)
                            : LC32GuestInterfacePolicy().preferredOrientation;
    CGFloat angle;
    if(portraitRootlessWindow) {
        angle = 0;
    } else if(orientation == UIInterfaceOrientationLandscapeLeft) {
        angle = M_PI_2;
    } else if(orientation == UIInterfaceOrientationLandscapeRight) {
        angle = -M_PI_2;
    } else {
        LC32ReconcileRootlessWindowPlacement(window, windowLayer, true);
        LC32RestoreLegacyDirectWindowSublayerTransform(
            window, windowLayer, savedTransform);
        return true;
    }

    if(!savedTransform) {
        const CATransform3D originalTransform =
            windowLayer.sublayerTransform;
        savedTransform = [NSValue value:&originalTransform
                           withObjCType:@encode(CATransform3D)];
        objc_setAssociatedObject(
            window, LC32LegacyDirectWindowSublayerTransformKey,
            savedTransform, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    const CGSize logicalSize = {320, LC32GuestPhoneCanvasLongEdge()};
    const CGSize turnedSize = portraitRootlessWindow ? logicalSize
        : CGSizeMake(logicalSize.height, logicalSize.width);
    const CGFloat scale = MIN(
        windowBounds.size.width / turnedSize.width,
        windowBounds.size.height / turnedSize.height);
    if(!(scale > 0) || !isfinite(scale)) return true;

    CGAffineTransform transform = CGAffineTransformScale(
        CGAffineTransformMakeRotation(angle), scale, scale);
    const CGPoint layerAnchor = windowLayer.anchorPoint;
    const CGPoint anchor = {
        windowBounds.origin.x +
            layerAnchor.x * windowBounds.size.width,
        windowBounds.origin.y +
            layerAnchor.y * windowBounds.size.height,
    };
    const CGPoint viewportCenter = {
        CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds),
    };
    const CGPoint canvasCenter = {
        logicalSize.width * 0.5, logicalSize.height * 0.5,
    };
    const CGFloat anchorDeltaX = anchor.x - canvasCenter.x;
    const CGFloat anchorDeltaY = anchor.y - canvasCenter.y;
    transform.tx = viewportCenter.x - anchor.x +
        transform.a * anchorDeltaX + transform.c * anchorDeltaY;
    transform.ty = viewportCenter.y - anchor.y +
        transform.b * anchorDeltaX + transform.d * anchorDeltaY;

    const CATransform3D desiredTransform =
        CATransform3DMakeAffineTransform(transform);
    if(!CATransform3DEqualToTransform(
            windowLayer.sublayerTransform, desiredTransform)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        windowLayer.sublayerTransform = desiredTransform;
        [CATransaction commit];
    }
    NSValue *desiredValue = [NSValue value:&desiredTransform
                               withObjCType:@encode(CATransform3D)];
    objc_setAssociatedObject(
        window, LC32LegacyDirectWindowAppliedSublayerTransformKey,
        desiredValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* A scene-sized window stands in for the turned portrait panel of iOS 7:
     * it follows the scene's side, and the game flips its own picture for
     * the other side (9mm). A game pinned to its launch side
     * (LC32UIKitGuestFixedCanvasDeviceOrientation) keeps that side. */
    const bool sceneSized = portraitRootlessWindow &&
        LC32WindowHasScenePortraitSize(window, windowLayer);
    const UIInterfaceOrientation sceneSide =
        window.windowScene.interfaceOrientation;
    const bool followsScene = sceneSized &&
        !LC32ObjectUsesGuestClass(window) &&
        UIInterfaceOrientationIsLandscape(sceneSide) &&
        !LC32UIKitGuestFixedCanvasDeviceOrientation(nullptr);
    const bool ancestorsTurned = portraitRootlessWindow &&
        LC32LegacyWindowAncestorsSwapAxes(windowLayer);
    if(rootlessPhoneCanvas && !portraitRootlessWindow) {
        LC32FitRootlessWindowPlacement(window, windowLayer);
    } else if(portraitRootlessWindow && ((followsScene && ancestorsTurned) ||
            LC32RootlessWindowNeedsTurnedPlacement(window, windowLayer))) {
        /* With UIKit's layers still turned for another side, the fit adds
         * the half turn they lack, or removes ours when they match. */
        const CGAffineTransform before = LC32NativeViewTransform(window);
        LC32FitTurnedRootlessWindowPlacement(window, windowLayer,
            followsScene ? sceneSide : orientation);
        /* A presentation counter-turned against our previous turn would now
         * show upside down; fit it against the new one. */
        if(sceneSized && !LC32TransformNearlyEquals(
                before, LC32NativeViewTransform(window)))
            LC32FitPresentedViewsInTurnedRootlessWindow(window, 0);
    } else if(ownsWindowPlacement && ancestorsTurned) {
        /* UIKit turned the window's layers for the scene again (or the
         * window left the scene size inside them): our own turn would now
         * be applied twice. */
        LC32ReconcileRootlessWindowPlacement(window, windowLayer, true);
    }
    return true;
}

/* A landscape game inside the portrait canvas whose controller accepts only
 * one landscape side (NOM5: RootController takes LandscapeRight only) was
 * fixed to that side on iPhone OS, so it showed upside down whenever the
 * phone was held the other way. When the phone is held on the refused side,
 * turn the whole canvas a half turn instead; the guest keeps its own side and
 * touch conversion follows the native window transform. */
static std::atomic<int> LC32PortraitCanvasGuestSide{0};    // turned side or 0
static std::atomic<bool> LC32PortraitCanvasSingleSide{false};
static std::atomic<int> LC32PortraitCanvasHeldSide{0};     // held side or 0
static std::atomic<bool> LC32PortraitCanvasHalfTurnApplied{false};

void LC32FitPortraitPhoneCanvasWindow(UIWindow *window);

static void LC32UpdatePortraitCanvasHalfTurn(void) {
    const int guest = LC32PortraitCanvasGuestSide.load(std::memory_order_acquire);
    const int held = LC32PortraitCanvasHeldSide.load(std::memory_order_acquire);
    const bool wanted = LC32PortraitCanvasSingleSide.load(
        std::memory_order_acquire) && guest != 0 && held != 0 && held != guest;
    if(LC32PortraitCanvasHalfTurnApplied.exchange(
            wanted, std::memory_order_acq_rel) == wanted) return;
    fprintf(stderr, "LC32: portrait canvas %s (phone held at %d, game at %d)\n",
        wanted ? "turned a half turn" : "upright again", held, guest);
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows)
            LC32FitPortraitPhoneCanvasWindow(window);
    }
}

/* Only definite landscape readings move the held side: a phone laid flat or
 * raised upright keeps the side it was turned to. */
static void LC32NotePortraitCanvasDeviceSide(void) {
    const UIDeviceOrientation device = UIDevice.currentDevice.orientation;
    if(device != UIDeviceOrientationLandscapeLeft &&
            device != UIDeviceOrientationLandscapeRight) return;
    LC32PortraitCanvasHeldSide.store(device == UIDeviceOrientationLandscapeLeft
        ? UIInterfaceOrientationLandscapeRight
        : UIInterfaceOrientationLandscapeLeft, std::memory_order_release);
}

/* Fixed portrait phone canvas: iOS letterboxed these apps into a 320x480
 * screen. Keep each guest window exactly that size (a main-nib window marked
 * full-screen is otherwise sized to the scene by native UIKit) and scale the
 * native window to aspect-fit the scene, so drawing and hit-testing stay in
 * the guest's 320x480 coordinates. */
void LC32FitPortraitPhoneCanvasWindow(UIWindow *window) {
    if(!window || !window.guest_selfOrNull || !window.windowScene ||
            LC32ObjectUsesGuestClass(window) ||
            !LC32GuestUsesFixedPortraitPhoneCanvas()) return;
    const CGSize canvas = {320, LC32GuestPhoneCanvasLongEdge()};
    const CGRect scene = LC32WindowSceneBounds(window);
    if(!(scene.size.width > 0) || !(scene.size.height > 0)) return;
    const CGFloat scale = MIN(scene.size.width / canvas.width,
                              scene.size.height / canvas.height);
    if(!(scale > 0) || !isfinite(scale)) return;
    CGAffineTransform target = CGAffineTransformMakeScale(scale, scale);
    if(LC32PortraitCanvasHalfTurnApplied.load(std::memory_order_acquire))
        target = CGAffineTransformMakeScale(-scale, -scale);
    const CGPoint center = {CGRectGetMidX(scene), CGRectGetMidY(scene)};
    const CGRect bounds = LC32NativeViewBounds(window);
    if(CGSizeEqualToSize(bounds.size, canvas) &&
            CGAffineTransformEqualToTransform(
                LC32NativeViewTransform(window), target) &&
            CGPointEqualToPoint(LC32NativeViewCenter(window), center)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if(!CGSizeEqualToSize(bounds.size, canvas)) {
        LC32NativeSetViewBounds(window,
            CGRectMake(bounds.origin.x, bounds.origin.y,
                       canvas.width, canvas.height));
    }
    LC32NativeSetViewTransform(window, target);
    LC32NativeSetViewCenter(window, center);
    [CATransaction commit];
}

/* UIKit's legacy backing setup (_updateTransformLayer ->
 * _configureRootLayer:) re-frames the window to the scene in its own,
 * already scaled coordinates: 320x695 instead of 320x480. Launch-time native
 * rotation runs once the guest's launch work finishes, which can be after the
 * timed re-fits above (Dungeon Raid: several seconds of OpenFeint/PlayHaven
 * set-up), leaving a 320x480 GL picture at the bottom of a taller drawable.
 * Re-fit after UIKit is done with the window. */
extern "C" void LC32RefitPortraitPhoneCanvasWindowLater(UIWindow *window) {
    if(!window || !window.guest_selfOrNull ||
            !LC32GuestUsesFixedPortraitPhoneCanvas()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        LC32FitPortraitPhoneCanvasWindow(window);
    });
}

/* iPhone OS turned a portrait app's first window subview whenever its
 * controller accepted the device's landscape side. Landscape-only games
 * without a plist orientation (Zenonia 3) rely on that while their scene
 * here stays portrait, so turn the controller inside the canvas: to the side
 * the phone was last held at, else landscape right. A flat or upright phone
 * keeps the side (iPhone OS did not turn for face up either). */
static void LC32NotePortraitCanvasGuestSide(UIView *view, bool singleSide) {
    const CGAffineTransform t = view ? LC32NativeViewTransform(view)
                                     : CGAffineTransformIdentity;
    const int side =
        LC32TransformNearlyEquals(t, CGAffineTransformMakeRotation(M_PI_2))
        ? UIInterfaceOrientationLandscapeRight
        : LC32TransformNearlyEquals(t, CGAffineTransformMakeRotation(-M_PI_2))
        ? UIInterfaceOrientationLandscapeLeft : 0;
    LC32PortraitCanvasGuestSide.store(side, std::memory_order_release);
    LC32PortraitCanvasSingleSide.store(singleSide && side != 0,
        std::memory_order_release);
    LC32UpdatePortraitCanvasHalfTurn();
}

void LC32RotatePortraitPhoneCanvasController(UIWindow *window) {
    if(!LC32GuestUsesFixedPortraitPhoneCanvas() ||
            !LC32CanQueryGuestOrientation()) return;
    UIView *view = LC32NativeViewSubviews(window).firstObject;
    UIResponder *next = view.nextResponder;
    if(![next isKindOfClass:UIViewController.class] ||
            !LC32ObjectUsesGuestClass(next)) return;
    SEL should = @selector(shouldAutorotateToInterfaceOrientation:);
    auto accepts = [&](UIInterfaceOrientation orientation) {
        return ((BOOL (*)(id, SEL, UIInterfaceOrientation))objc_msgSend)(
            next, should, orientation) != NO;
    };
    LC32NotePortraitCanvasDeviceSide();
    if(![next respondsToSelector:should] ||
            accepts(UIInterfaceOrientationPortrait)) {
        LC32NotePortraitCanvasGuestSide(view, false);
        return;
    }
    const bool right = accepts(UIInterfaceOrientationLandscapeRight);
    const bool left = accepts(UIInterfaceOrientationLandscapeLeft);
    if(!right && !left) {
        LC32NotePortraitCanvasGuestSide(view, false);
        return;
    }
    UIInterfaceOrientation side =
        LC32PortraitCanvasHeldSide.load(std::memory_order_acquire) ==
            UIInterfaceOrientationLandscapeLeft
        ? UIInterfaceOrientationLandscapeLeft
        : UIInterfaceOrientationLandscapeRight;
    if(!(side == UIInterfaceOrientationLandscapeRight ? right : left)) {
        side = side == UIInterfaceOrientationLandscapeRight
            ? UIInterfaceOrientationLandscapeLeft
            : UIInterfaceOrientationLandscapeRight;
    }
    // The last question iPhone OS asked was about the side it turned to.
    (void)accepts(side);
    LC32RotateFullScreenRootlessController(window, side);
    LC32NotePortraitCanvasGuestSide(view, !(right && left));
}

/* Startup holds guest orientation queries back until the launch work is done,
 * which can outlast the timed attempts from makeKeyAndVisible (NOM5 blocks
 * in network set-up), so the root stayed unturned until the phone turned. */
static void LC32RotatePortraitPhoneCanvasControllersAfterStartup(void) {
    if(!LC32GuestUsesFixedPortraitPhoneCanvas()) return;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            if(!window.guest_selfOrNull) continue;
            LC32FitPortraitPhoneCanvasWindow(window);
            LC32RotatePortraitPhoneCanvasController(window);
        }
    }
}

void LC32WatchPortraitPhoneCanvasWindow(UIWindow *window) {
    if(!LC32GuestUsesFixedPortraitPhoneCanvas()) return;
    static NSHashTable<UIWindow *> *windows;
    if(!windows) {
        windows = [NSHashTable weakObjectsHashTable];
#if !__has_feature(objc_arc)
        [windows retain];
#endif
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIDeviceOrientationDidChangeNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *) {
                for(UIWindow *watched in windows.allObjects) {
                    LC32RotatePortraitPhoneCanvasController(watched);
                }
            }];
    }
    [windows addObject:window];
}

void LC32ScheduleRootlessWindowLayerLayout(UIWindow *window) {
    if(!LC32WindowUsesRootlessPhoneCanvas(window) ||
            objc_getAssociatedObject(
                window, LC32LegacyWindowLayersLayoutPendingKey)) return;
    objc_setAssociatedObject(window, LC32LegacyWindowLayersLayoutPendingKey,
        @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* Early engines add their renderer to an existing nested canvas after
     * the initial makeKeyAndVisible/orientation calls. Coalesce insertions
     * and inspect the settled native layer hierarchy without forcing guest
     * layout or scanning on display frames/global UIView layout callbacks. */
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(window, LC32LegacyWindowLayersLayoutPendingKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LC32FitLegacyDirectWindowLayers(window);
    });
}

static char LC32PhoneCanvasGeometryGuessKey;

/* Controls laid out past the portrait width of a 320-wide root (Zenonia 5's
 * cocos2d buttons at x=448) show it expects UIKit to turn it to landscape,
 * even when the root is the GL view itself. */
bool LC32PhoneCanvasContentHasLandscapeLayout(UIView *contentView) {
    const CGRect bounds = LC32NativeViewBounds(contentView);
    const CGFloat canvasLong = LC32GuestPhoneCanvasLongEdge();
    constexpr CGFloat epsilon = 0.5;
    if(fabs(bounds.size.width - 320) >= epsilon) return false;
    for(UIView *child in LC32NativeViewSubviews(contentView)) {
        const CGSize size = LC32NativeViewBounds(child).size;
        const CGPoint center = LC32NativeViewCenter(child);
        const CGRect frame = CGRectMake(center.x - size.width * 0.5,
            center.y - size.height * 0.5, size.width, size.height);
        if(CGRectGetMaxX(frame) > 320 + epsilon &&
                CGRectGetMinX(frame) < canvasLong &&
                CGRectGetMaxY(frame) <= 320 + epsilon) {
            return true;
        }
    }
    return false;
}

/* A full-size, unturned portrait GL child (Star Battalion's EAGLView under
 * a plain controller view) fixes the drawable contract: the engine rotates
 * in its projection. Landscape overlays added later (Game Center, movies,
 * Gameloft online views) must not turn that canvas into a landscape one. */
bool LC32PhoneCanvasHasPortraitGLChild(UIView *contentView) {
    static Class eaglLayerClass = NSClassFromString(@"CAEAGLLayer");
    const CGSize size = LC32NativeViewBounds(contentView).size;
    if(!(size.width < size.height)) return false;
    for(UIView *child in LC32NativeViewSubviews(contentView)) {
        if([LC32NativeViewLayer(child) isKindOfClass:eaglLayerClass] &&
                CGSizeEqualToSize(LC32NativeViewBounds(child).size, size) &&
                LC32TransformNearlyEquals(LC32NativeViewTransform(child),
                                          CGAffineTransformIdentity)) {
            return true;
        }
    }
    return false;
}

bool LC32PhoneCanvasGeometryModeWasGuessed(UIViewController *controller) {
    return controller && objc_getAssociatedObject(
        controller, &LC32PhoneCanvasGeometryGuessKey) != nil;
}

/* The container's canvas mode from before a movie root replaced its content
 * (see LC32_UIKit_SetWindowRootViewController). */
static char LC32PreMovieGeometryModeKey;

/* A full-screen movie controller (or a guest subclass of one) that the game
 * makes its window root. */
bool LC32ControllerIsMoviePlayer(UIViewController *controller) {
    static Class movieController;
    if(!movieController)
        movieController = NSClassFromString(@"MPMoviePlayerViewController");
    return controller && movieController &&
        [controller isKindOfClass:movieController];
}

LC32LegacyIPadGeometryMode LC32LegacyPhoneCanvasGeometryMode(
        UIViewController *controller) {
    if(LC32ControllerIsMoviePlayer(controller)) {
        /* 9mm plays its Gameloft logo by making its MPMoviePlayerViewController
         * subclass the window root. iOS 7 turned that root to landscape like
         * any other; it has no portrait drawable of its own, so the portrait
         * GL canvas would show the landscape movie letterboxed and sideways. */
        objc_setAssociatedObject(controller, &LC32PhoneCanvasGeometryGuessKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas;
    }
    UIView *contentView = nil;
    const bool loaded =
        LC32NativeViewIfLoaded(controller, &contentView) && contentView;
    objc_setAssociatedObject(controller, &LC32PhoneCanvasGeometryGuessKey,
        loaded ? nil : @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(loaded && LC32GameProfileLandscapeGLRoot()) {
        /* iOS 4 turned and resized a landscape-only root controller's view
         * even when it was the GL view itself (as iOS 6+ does below). RAGE
         * HD draws a 480x320 picture unturned and relies on that; most
         * older GL roots rotate in their projection instead, so this is a
         * per-game opt-in rather than a rule for every pre-iOS-6 root. */
        static Class eaglLayerClass = NSClassFromString(@"CAEAGLLayer");
        if([LC32NativeViewLayer(contentView) isKindOfClass:eaglLayerClass] &&
                !(LC32GuestInterfacePolicy().declaredOrientations &
                  (UIInterfaceOrientationMaskPortrait |
                   UIInterfaceOrientationMaskPortraitUpsideDown))) {
            return LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas;
        }
    }
    if(loaded) {
        const CGRect bounds = LC32NativeViewBounds(contentView);
        const CGFloat shortEdge = MIN(
            bounds.size.width, bounds.size.height);
        const CGFloat longEdge = MAX(
            bounds.size.width, bounds.size.height);
        constexpr CGFloat epsilon = 0.5;
        if(fabs(shortEdge - 320) < epsilon &&
                fabs(longEdge - LC32GuestPhoneCanvasLongEdge()) < epsilon) {
            static Class eaglLayerClass = NSClassFromString(@"CAEAGLLayer");
            /* The GL surface may be the controller's view itself or an
             * unturned child covering it (Star Battalion's nib wraps its
             * EAGLView in a plain controller view). */
            const bool portraitGLChild =
                LC32PhoneCanvasHasPortraitGLChild(contentView);
            const bool portraitGLSurface = portraitGLChild ||
                [LC32NativeViewLayer(contentView) isKindOfClass:eaglLayerClass];
            /* iOS 6 turned and resized a landscape-only root even when it
             * is the GL view itself (Zenonia 5's cocos2d EAGLView), before
             * the engine sized its framebuffer at makeKeyAndVisible. */
            const bool rotatedGLRoot =
                [LC32NativeViewLayer(contentView) isKindOfClass:eaglLayerClass] &&
                LC32GetGuestExecutableSDKVersion() >= 0x60000 &&
                !(LC32GuestInterfacePolicy().declaredOrientations &
                  (UIInterfaceOrientationMaskPortrait |
                   UIInterfaceOrientationMaskPortraitUpsideDown));
            const bool landscapeLayout = rotatedGLRoot || (!portraitGLChild &&
                LC32PhoneCanvasContentHasLandscapeLayout(contentView));
            if(LC32GuestUsesFixedLandscapePhoneCanvas() &&
                    bounds.size.width < bounds.size.height &&
                    LC32TransformNearlyEquals(
                        LC32NativeViewTransform(contentView),
                        CGAffineTransformIdentity) &&
                    portraitGLSurface && !landscapeLayout) {
                /* An unturned portrait GL surface can rotate in the engine's
                 * projection matrix. Preserve it before the first drawable
                 * allocation; some old renderers never reallocate storage.
                 * Matching only the short/long edges loses this contract. */
                return LC32LegacyIPadGeometryModePreservePhonePortraitCanvas;
            }
            /* Old applications often follow setRootViewController: with a
             * redundant addSubview:. Modern controller containment makes
             * that reparent invalid, so normalize either archived ordering
             * to the landscape canvas which that second call established. */
            return LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas;
        }
        if(LC32GuestUsesFixedLandscapePhoneCanvas()) {
            /* UIKit may already have sized the root to the scene. Its
             * children still show which drawable the game built: a
             * landscape 480x320 view (Zenonia 2's title UI) expects iOS 4
             * to have turned the root, a portrait 320x480 GL child
             * (Grabatron) rotates in its own projection. */
            constexpr CGFloat epsilon = 0.5;
            const CGFloat canvasLong = LC32GuestPhoneCanvasLongEdge();
            for(UIView *child in LC32NativeViewSubviews(contentView)) {
                const CGSize size = LC32NativeViewBounds(child).size;
                if(fabs(size.width - canvasLong) < epsilon &&
                        fabs(size.height - 320) < epsilon) {
                    return LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas;
                }
                if(fabs(size.width - 320) < epsilon &&
                        fabs(size.height - canvasLong) < epsilon) {
                    return LC32LegacyIPadGeometryModePreservePhonePortraitCanvas;
                }
            }
        }
    }
    return LC32GuestUsesFixedLandscapePhoneCanvas()
        ? LC32LegacyIPadGeometryModePreservePhonePortraitCanvas
        : LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas;
}

bool LC32UsesClassicFullScreenViewport(UIWindow *window) {
    UIScreen *screen = window.screen ?: UIScreen.mainScreen;
    const CGRect screenBounds = screen.bounds;
    const CGFloat screenShortEdge = MIN(
        screenBounds.size.width, screenBounds.size.height);
    return (LC32GuestNeedsLegacyIPadCanvas() ||
            LC32GuestUsesFixedLandscapePhoneCanvas()) &&
           LC32GuestInterfacePolicy().statusBarHidden &&
           screenShortEdge > 0 && screenShortEdge < 600;
}

CGRect LC32LegacyViewportInView(UIWindow *window, UIView *view) {
    const CGRect fallback = LC32NativeViewBounds(view);
    if(!window || !view || !window.windowScene) return fallback;
    CGRect classicBounds, classicScene;
    if(LC32GetClassicWindowGeometry(window, &classicBounds, &classicScene))
        return [view convertRect:classicBounds fromView:window];

    id<UICoordinateSpace> sourceSpace = nil;
    CGRect sourceBounds = CGRectZero;
    UIScreen *screen = window.screen ?: UIScreen.mainScreen;
    const CGRect screenBounds = screen.bounds;
    if(LC32UsesClassicFullScreenViewport(window)) {
        /* Full-screen legacy games draw behind modern safe-area insets. The
         * compatibility root is translated relative to UIScreen, so convert
         * the complete display rect instead of copying its origin and size. */
        sourceSpace = screen.coordinateSpace;
        sourceBounds = screenBounds;
    } else {
        UIWindowScene *scene = window.windowScene;
        if(@available(iOS 26.0, *)) {
            sourceSpace = (id<UICoordinateSpace>)LC32ObjectProperty(
                scene.effectiveGeometry, "coordinateSpace");
        }
        if(!sourceSpace) sourceSpace = scene.coordinateSpace;
        sourceBounds = sourceSpace.bounds;
    }
    if(!sourceSpace || !(sourceBounds.size.width > 0) ||
            !(sourceBounds.size.height > 0)) {
        return fallback;
    }

    const CGRect viewport = [view convertRect:sourceBounds
                           fromCoordinateSpace:sourceSpace];
    return isfinite(viewport.origin.x) && isfinite(viewport.origin.y) &&
           isfinite(viewport.size.width) &&
           isfinite(viewport.size.height) &&
           viewport.size.width > 0 && viewport.size.height > 0
        ? viewport : fallback;
}

UIInterfaceOrientation LC32WindowSceneOrientation(
        UIWindow *window, CGRect sceneBounds) {
    UIWindowScene *scene = window.windowScene;
    UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
    if(@available(iOS 26.0, *)) {
        orientation = scene.effectiveGeometry.interfaceOrientation;
    }
    if(orientation == UIInterfaceOrientationUnknown) {
        orientation = scene.interfaceOrientation;
    }
    if(LC32MaskForInterfaceOrientation(orientation)) {
        if([window isKeyWindow]) {
            LC32CacheSettledLegacyOrientation(window, orientation);
        }
    } else {
        orientation = LC32SettledLegacyOrientation(
            window, UIInterfaceOrientationMaskAll);
    }
    (void)sceneBounds;
    return orientation;
}

/* A main-nib window is still 320x480 when the container is installed. UIKit
 * sizes the root view to the scene first, so growing the window afterwards
 * adds the same delta again through the root view's flexible autoresizing
 * (Star Battalion: 1268x484), and the canvas is centered off-screen. Under
 * legacy rotation the (possibly quarter-turned) root view must exactly cover
 * the window. */
static void LC32CoverLegacyWindowWithRootView(UIWindow *window,
                                              UIView *rootView) {
    if(!LC32NativeLegacyRotationEnabled() || !rootView) return;
    const CGRect windowBounds = LC32NativeViewBounds(window);
    CGSize rootSize = windowBounds.size;
    if(fabs(LC32NativeViewTransform(rootView).b) > 0.5) {
        rootSize = CGSizeMake(rootSize.height, rootSize.width);
    }
    if(CGSizeEqualToSize(LC32NativeViewBounds(rootView).size, rootSize))
        return;
    LC32NativeSetViewBounds(rootView,
        CGRectMake(0, 0, rootSize.width, rootSize.height));
    LC32NativeSetViewCenter(rootView, CGPointMake(
        CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds)));
}

/* The canvas container's black view covers the whole window, so the guest
 * window's own background (white from RAGE HD's MainWindow.nib) never shows
 * until a full-screen presentation takes the container off screen: then it
 * fills the letterbox around the 480x320 presented view (RAGE HD's intro
 * movie controller). On iPhone OS the presentation covered the whole screen.
 * Refits run during presentations, so a later guest change is undone too.
 * A container cleared for sibling renderers (see above) lets the window
 * colour show inside the canvas, so that layout keeps the guest's colour. */
static void LC32BlackenPhoneCanvasWindowBackdrop(
        UIWindow *window, LC32LegacyIPadContainerController *container) {
    using Getter = UIColor *(*)(id, SEL);
    using Setter = void (*)(id, SEL, UIColor *);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIWindow.class,
                                      @selector(backgroundColor)));
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIWindow.class,
                                      @selector(setBackgroundColor:)));
    UIColor *black = UIColor.blackColor;
    if(!window || !container.isViewLoaded ||
            ![container.view.backgroundColor isEqual:black] ||
            [getter(window, @selector(backgroundColor)) isEqual:black])
        return;
    setter(window, @selector(setBackgroundColor:), black);
}

/* UIKit's legacy presentation path (UIWindowController, guest SDK < 8) turns
 * a full-screen presented view a quarter and centres it from its own idea of
 * the window. When the scene is already landscape as the presentation starts
 * (the phone held sideways at launch), that centre comes out mirrored,
 * (673,437) instead of (201,437) in an 874x402 scene, and RAGE HD's intro
 * movie played entirely off screen. Centre such views on the scene's centre
 * converted into the window, which is (201,437) for both launch sides (the
 * screen space and LC32LegacyViewportInView give (-35,201) here). Native
 * getters keep this refit path out of guest code. */
static void LC32CenterPresentedViewsOnPhoneCanvas(UIWindow *window) {
    LC32LegacyIPadContainerController *container =
        LC32LegacyContainerForWindow(window);
    UIWindowScene *scene = window.windowScene;
    if(!container || !scene ||
            !LC32GeometryModePreservesPhoneCanvas(container.geometryMode))
        return;
    const CGRect sceneBounds = scene.coordinateSpace.bounds;
    if(!(sceneBounds.size.width > 0) || !(sceneBounds.size.height > 0)) return;
    const CGPoint target = [window convertPoint:CGPointMake(
            CGRectGetMidX(sceneBounds), CGRectGetMidY(sceneBounds))
        fromCoordinateSpace:scene.coordinateSpace];
    if(!isfinite(target.x) || !isfinite(target.y)) return;

    using ObjectGetter = id (*)(id, SEL);
    using FlagGetter = BOOL (*)(id, SEL);
    using StyleGetter = UIModalPresentationStyle (*)(id, SEL);
    static ObjectGetter nextResponder = reinterpret_cast<ObjectGetter>(
        class_getMethodImplementation(UIView.class, @selector(nextResponder)));
    static ObjectGetter presenting = reinterpret_cast<ObjectGetter>(
        class_getMethodImplementation(UIViewController.class,
            @selector(presentingViewController)));
    static FlagGetter beingPresented = reinterpret_cast<FlagGetter>(
        class_getMethodImplementation(UIViewController.class,
            @selector(isBeingPresented)));
    static FlagGetter beingDismissed = reinterpret_cast<FlagGetter>(
        class_getMethodImplementation(UIViewController.class,
            @selector(isBeingDismissed)));
    static StyleGetter presentationStyle = reinterpret_cast<StyleGetter>(
        class_getMethodImplementation(UIViewController.class,
            @selector(modalPresentationStyle)));
    const CGAffineTransform quarterTurns[] = {
        CGAffineTransformMake(0, 1, -1, 0, 0, 0),
        CGAffineTransformMake(0, -1, 1, 0, 0, 0),
    };
    UIView *containerView = container.isViewLoaded ? container.view : nil;
    for(UIView *child in LC32NativeViewSubviews(window)) {
        if(child == containerView) continue;
        const CGAffineTransform transform = LC32NativeViewTransform(child);
        if(!LC32TransformNearlyEquals(transform, quarterTurns[0]) &&
                !LC32TransformNearlyEquals(transform, quarterTurns[1]))
            continue;
        id next = nextResponder(child, @selector(nextResponder));
        if(!next || !LC32ClassIsUIViewController(object_getClass(next)) ||
                !presenting(next, @selector(presentingViewController)) ||
                beingPresented(next, @selector(isBeingPresented)) ||
                beingDismissed(next, @selector(isBeingDismissed)) ||
                presentationStyle(next, @selector(modalPresentationStyle)) !=
                    UIModalPresentationFullScreen)
            continue;
        const CGPoint center = LC32NativeViewCenter(child);
        if(fabs(center.x - target.x) < 0.5 && fabs(center.y - target.y) < 0.5)
            continue;
        LC32NativeSetViewCenter(child, target);
        fprintf(stderr, "LC32: presented %s centred on the phone canvas "
            "(%.0f,%.0f -> %.0f,%.0f)\n", object_getClassName(next),
            center.x, center.y, target.x, target.y);
    }
}

void LC32ScaleLegacyIPadWindow(UIWindow *window) {
    /* UIKit owns keyboard, alert, and text-effects windows in the same
     * process. Virtualize only a UIWindow paired with a guest object. */
    if(!window || !window.guest_selfOrNull) return;
    if(LC32FitLegacyDirectWindowLayers(window)) return;
    if(LC32FitRootlessIPadWindow(window)) return;
    LC32LegacyIPadContainerController *container =
        LC32LegacyContainerForWindow(window);
    if(container && container.geometryMode ==
            LC32LegacyIPadGeometryModeReflowRootController &&
            LC32GuestUsesFixedLandscapeIPadCanvas() &&
            LC32WindowNeedsLegacyIPadContainer(window)) {
        const UIInterfaceOrientation orientation =
            LC32LegacyTargetOrientation(container.guestContentController);
        if(UIInterfaceOrientationIsLandscape(orientation)) {
            /* The host otherwise retains the archived 768x1024 UIWindow and
             * exposes only its bottom scene-height strip.  This inferred-iPad
             * class uses a fixed landscape GL drawable, so give UIKit the
             * native legacy frame before the renderer locks its surface. */
            CGRect canvasFrame = CGRectMake(0, 0, 1024, 768);
            const CGRect sceneBounds = LC32WindowSceneBounds(window);
            if(sceneBounds.size.width > 0 && sceneBounds.size.height > 0) {
                canvasFrame.origin.y =
                    (MIN(sceneBounds.size.width, sceneBounds.size.height) -
                     canvasFrame.size.height) * 0.5;
            }
            LC32NativeSetWindowFrame(window, canvasFrame);
            const CGRect viewportBounds = {
                CGPointZero,
                canvasFrame.size,
            };
            [container fitGuestContentForViewport:viewportBounds
                hostOrientation:orientation];
            return;
        }
    }
    if(container && container.geometryMode ==
            LC32LegacyIPadGeometryModePreservePhonePortraitCanvas) {
        UIScreen *screen = window.screen ?: UIScreen.mainScreen;
        CGRect viewportBounds = screen.bounds;
        LC32ClassicScreenGeometry savedScreen;
        if(LC32GetClassicScreenGeometry(screen, &savedScreen)) viewportBounds = savedScreen.bounds;
        if(!(viewportBounds.size.width > 0) ||
                !(viewportBounds.size.height > 0)) {
            viewportBounds = LC32WindowSceneBounds(window);
        }
        const UIInterfaceOrientation orientation =
            LC32WindowSceneOrientation(window, viewportBounds);
        if(UIInterfaceOrientationIsLandscape(orientation) &&
                viewportBounds.size.width < viewportBounds.size.height) {
            viewportBounds.size = CGSizeMake(
                viewportBounds.size.height, viewportBounds.size.width);
        }
        LC32NativeSetWindowFrame(window, viewportBounds);
        LC32CoverLegacyWindowWithRootView(window, container.view);
        const CGRect viewport = LC32LegacyViewportInView(
            window, container.view);
        [container fitGuestContentForViewport:viewport
            hostOrientation:orientation];
        LC32BlackenPhoneCanvasWindowBackdrop(window, container);
        LC32CenterPresentedViewsOnPhoneCanvas(window);
        return;
    }
    if(container && container.geometryMode ==
            LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas) {
        CGRect sceneBounds = LC32WindowSceneBounds(window);
        const UIInterfaceOrientation orientation =
            LC32WindowSceneOrientation(window, sceneBounds);
        if(UIInterfaceOrientationIsLandscape(orientation) &&
                sceneBounds.size.width < sceneBounds.size.height) {
            sceneBounds.size = CGSizeMake(
                sceneBounds.size.height, sceneBounds.size.width);
        }
        LC32NativeSetWindowFrame(window, sceneBounds);
        LC32CoverLegacyWindowWithRootView(window, container.view);
        const CGRect viewport = LC32LegacyViewportInView(
            window, container.view);
        [container fitGuestContentForViewport:viewport
            hostOrientation:orientation];
        LC32BlackenPhoneCanvasWindowBackdrop(window, container);
        LC32CenterPresentedViewsOnPhoneCanvas(window);
        return;
    }
    if(!LC32GuestNeedsLegacyIPadCanvas()) return;

    if(container && !LC32WindowNeedsLegacyIPadContainer(window)) {
        /* Scene resizing can leave classic mode at runtime. Unwrap promptly
         * instead of retaining a scaled compatibility hierarchy in a native
         * iPad viewport. The mode is irrelevant once no container is needed. */
        LC32InstallGuestWindowRootViewController(window,
            container.guestContentController,
            LC32LegacyIPadGeometryModeReflowRootController);
        return;
    }
    if(!container && LC32WindowNeedsLegacyIPadContainer(window)) {
        UIViewController *guestRoot =
            LC32GuestWindowRootViewController(window);
        if(LC32ObjectUsesGuestClass(guestRoot)) {
            /* Reaching this path means the guest never used the bridged
             * rootViewController setter. Preserve its pre-iOS-4 portrait
             * canvas and reproduce the legacy compositor rotation. */
            LC32InstallGuestWindowRootViewController(window, guestRoot,
                LC32LegacyIPadGeometryModePreservePortraitCanvas);
            return;
        }
    }
    if(!container) return;

    /* A pre-controller guest can construct its UIWindow and root view from
     * the virtual 768x1024 UIScreen bounds before a scene is attached. Keep
     * those guest-visible bounds intact, but fit the native child canvas to
     * the settled scene instead of the oversized archived root. */
    const CGRect sceneBounds = LC32WindowSceneBounds(window);
    const CGRect viewport = LC32LegacyViewportInView(
        window, container.view);
    [container fitGuestContentForViewport:viewport
        hostOrientation:LC32WindowSceneOrientation(
            window, sceneBounds)];
}

bool LC32ObjectUsesGuestClass(id object) {
    return object && [(id)object_getClass(object) isGuestClass];
}

bool LC32TransformNearlyEquals(
        CGAffineTransform left, CGAffineTransform right) {
    constexpr CGFloat epsilon = 0.0001;
    return fabs(left.a - right.a) < epsilon &&
           fabs(left.b - right.b) < epsilon &&
           fabs(left.c - right.c) < epsilon &&
           fabs(left.d - right.d) < epsilon &&
           fabs(left.tx - right.tx) < epsilon &&
           fabs(left.ty - right.ty) < epsilon;
}

bool LC32LayerContainsRenderer(CALayer *layer) {
    static Class eaglLayer = NSClassFromString(@"CAEAGLLayer");
    static Class metalLayer = NSClassFromString(@"CAMetalLayer");
    if((eaglLayer && [layer isKindOfClass:eaglLayer]) ||
            (metalLayer && [layer isKindOfClass:metalLayer])) return true;
    for(CALayer *child in layer.sublayers) {
        if(LC32LayerContainsRenderer(child)) return true;
    }
    return false;
}

UIInterfaceOrientation LC32LegacyRootWindowGeometry(
        UIView *view, bool requireGuestLandscapeBounds,
        UIWindow *installingWindow, UIViewController *installingRoot) {
    const u32 sdk = LC32GetGuestExecutableSDKVersion();
    if(!sdk || sdk >= 0x80000) return UIInterfaceOrientationUnknown;
    UIView *superview = LC32NativeViewSuperview(view);
    UIWindow *window = installingWindow;
    if(window) {
        if(superview && superview != window) return UIInterfaceOrientationUnknown;
    } else {
        if(![superview isKindOfClass:UIWindow.class])
            return UIInterfaceOrientationUnknown;
        window = (UIWindow *)superview;
    }
    if(!view.guest_selfOrNull || !window.guest_selfOrNull ||
            LC32GuestUsesFixedLandscapePhoneCanvas() ||
            LC32GuestNeedsLegacyIPadCanvas()) return UIInterfaceOrientationUnknown;
    if(LC32LegacyContainerForWindow(window)) return UIInterfaceOrientationUnknown;
    UIViewController *root = installingRoot ?: LC32NativeWindowRootViewController(window);
    UIView *rootView = nil;
    if(!LC32ObjectUsesGuestClass(root) ||
            !LC32NativeViewIfLoaded(root, &rootView) || rootView != view)
        return UIInterfaceOrientationUnknown;
    /* This contract belongs to renderer-backed roots which size their own
     * drawable. Ordinary UIKit roots and overlays retain their existing
     * geometry behavior, even when they contain a transformed subview. */
    CALayer *layer = LC32NativeViewLayer(view);
    static Class eaglLayer = NSClassFromString(@"CAEAGLLayer");
    static Class metalLayer = NSClassFromString(@"CAMetalLayer");
    if(!((eaglLayer && [layer isKindOfClass:eaglLayer]) ||
            (metalLayer && [layer isKindOfClass:metalLayer])))
        return UIInterfaceOrientationUnknown;
    if(!LC32TransformNearlyEquals(LC32NativeViewTransform(window),
            CGAffineTransformIdentity) || !CATransform3DIsIdentity(
                LC32NativeViewLayer(window).sublayerTransform))
        return UIInterfaceOrientationUnknown;

    const CGRect viewport = LC32NativeViewBounds(window);
    const CGRect bounds = LC32NativeViewBounds(view);
    UIInterfaceOrientation orientation =
        LC32WindowSceneOrientation(window, viewport);
    if(!UIInterfaceOrientationIsLandscape(orientation) &&
            viewport.size.width > viewport.size.height && [window isKeyWindow]) {
        /* UIWindow can already have its final landscape geometry while
         * UIWindowScene still reports the launch-time portrait orientation.
         * Its identity transform was checked above; use the app's accepted
         * landscape side only for this already-turned primary window. */
        const UIInterfaceOrientation current =
            UIApplication.sharedApplication.statusBarOrientation;
        NSNumber *cached = objc_getAssociatedObject(root, LC32LegacyOrientationMaskKey);
        const UIInterfaceOrientationMask mask = cached
            ? (UIInterfaceOrientationMask)cached.unsignedLongLongValue
            : LC32GuestInterfacePolicy().declaredOrientations;
        if(UIInterfaceOrientationIsLandscape(current) &&
                (LC32MaskForInterfaceOrientation(current) & mask))
            orientation = current;
    }
    if(!UIInterfaceOrientationIsLandscape(orientation) ||
            !(viewport.size.width > viewport.size.height) ||
            !(viewport.size.height > 0)) return UIInterfaceOrientationUnknown;
    const CGAffineTransform oldWindowTurn =
        orientation == UIInterfaceOrientationLandscapeRight
            ? CGAffineTransformMake(0, 1, -1, 0, 0, 0)
            : CGAffineTransformMake(0, -1, 1, 0, 0, 0);
    if(!LC32TransformNearlyEquals(LC32NativeViewTransform(view), oldWindowTurn))
        return UIInterfaceOrientationUnknown;
    constexpr CGFloat epsilon = 0.5;
    const bool landscapeBounds =
        fabs(bounds.size.width - viewport.size.width) < epsilon &&
        fabs(bounds.size.height - viewport.size.height) < epsilon;
    const bool resizedByUIKit = !requireGuestLandscapeBounds &&
        fabs(bounds.size.width - viewport.size.height) < epsilon &&
        fabs(bounds.size.height - viewport.size.width) < epsilon;
    using GetCenter = CGPoint (*)(id, SEL);
    static GetCenter getCenter = reinterpret_cast<GetCenter>(
        class_getMethodImplementation(UIView.class, @selector(center)));
    const CGPoint center = getCenter(view, @selector(center));
    const bool windowCenter =
        fabs(center.x - viewport.size.width * 0.5) < epsilon &&
        fabs(center.y - viewport.size.height * 0.5) < epsilon;
    const bool portraitCenter =
        fabs(center.x - viewport.size.height * 0.5) < epsilon &&
        fabs(center.y - viewport.size.width * 0.5) < epsilon;
    if(!isfinite(viewport.size.width) || !isfinite(viewport.size.height) ||
            !(fabs(viewport.origin.x) < epsilon) ||
            !(fabs(viewport.origin.y) < epsilon) ||
            !(fabs(bounds.origin.x) < epsilon) ||
            !(fabs(bounds.origin.y) < epsilon) ||
            !(landscapeBounds || resizedByUIKit) ||
            !(windowCenter || portraitCenter)) return UIInterfaceOrientationUnknown;
    return orientation;
}

void LC32FitLegacyControllerRoot(UIView *view) {
    NSNumber *recorded = objc_getAssociatedObject(
        view, LC32LegacyRootWindowGeometryKey);
    objc_setAssociatedObject(view, LC32LegacyRootWindowGeometryKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(!recorded || LC32LegacyRootWindowGeometry(view, false) !=
            recorded.integerValue) return;
    /* A pre-iOS-8 controller can explicitly rotate a landscape bounds rect
     * into the old portrait window. Modern UIWindow has already rotated;
     * its next root layout would transpose those bounds a second time.
     * Only act after observing that exact guest-authored landscape shape,
     * never infer it from an intentionally portrait rendering surface. */
    const CGRect viewport = LC32NativeViewBounds(LC32NativeViewSuperview(view));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LC32NativeSetViewTransform(view, CGAffineTransformIdentity);
    LC32NativeSetViewBounds(view, viewport);
    LC32NativeSetViewCenter(view, CGPointMake(
        CGRectGetMidX(viewport), CGRectGetMidY(viewport)));
    [CATransaction commit];
}

void LC32FitLegacyControllerOverlay(UIView *view) {
    UIView *superview = LC32NativeViewSuperview(view);
    if(![superview isKindOfClass:UIWindow.class]) return;
    UIWindow *window = (UIWindow *)superview;
    if(!view.guest_selfOrNull || !window.guest_selfOrNull ||
            LC32LegacyContainerForWindow(window)) return;

    /* Only an independently added controller root uses this old window
     * contract. Ordinary rotated views, contained controllers, and the game
     * root/drawable must retain their application-authored transforms. */
    using NextResponder = UIResponder *(*)(id, SEL);
    static NextResponder nextResponder = reinterpret_cast<NextResponder>(
        class_getMethodImplementation(UIView.class, @selector(nextResponder)));
    UIResponder *owner = nextResponder(view, @selector(nextResponder));
    if(![owner isKindOfClass:UIViewController.class] ||
            !LC32ObjectUsesGuestClass(owner)) return;
    UIViewController *controller = (UIViewController *)owner;
    UIView *controllerView = nil;
    using GetController = UIViewController *(*)(id, SEL);
    static GetController getParent = reinterpret_cast<GetController>(
        class_getMethodImplementation(UIViewController.class,
            @selector(parentViewController)));
    static GetController getPresenter = reinterpret_cast<GetController>(
        class_getMethodImplementation(UIViewController.class,
            @selector(presentingViewController)));
    if(controller == LC32NativeWindowRootViewController(window) ||
            getParent(controller, @selector(parentViewController)) ||
            getPresenter(controller, @selector(presentingViewController)) ||
            !LC32NativeViewIfLoaded(controller, &controllerView) ||
            controllerView != view) return;

    CALayer *windowLayer = LC32NativeViewLayer(window);
    if(!LC32TransformNearlyEquals(LC32NativeViewTransform(window),
                CGAffineTransformIdentity) ||
            !CATransform3DIsIdentity(windowLayer.sublayerTransform)) return;

    const CGRect windowBounds = LC32NativeViewBounds(window);
    const CGRect bounds = LC32NativeViewBounds(view);
    const UIInterfaceOrientation orientation =
        LC32WindowSceneOrientation(window, windowBounds);
    if(!UIInterfaceOrientationIsLandscape(orientation) ||
            !(windowBounds.size.width > windowBounds.size.height) ||
            !(windowBounds.size.height > 0)) return;

    const CGAffineTransform oldWindowTurn =
        /* This is the view's old portrait-to-window transform, not the
         * inverse compositor transform used by the fixed-canvas adapters. */
        orientation == UIInterfaceOrientationLandscapeRight
            ? CGAffineTransformMake(0, 1, -1, 0, 0, 0)
            : CGAffineTransformMake(0, -1, 1, 0, 0, 0);
    if(!LC32TransformNearlyEquals(
            LC32NativeViewTransform(view), oldWindowTurn)) return;

    using GetCenter = CGPoint (*)(id, SEL);
    static GetCenter getCenter = reinterpret_cast<GetCenter>(
        class_getMethodImplementation(UIView.class, @selector(center)));
    const CGPoint center = getCenter(view, @selector(center));
    constexpr CGFloat epsilon = 0.5;
    /* Pre-iOS-8 helpers rotate an already-landscape bounds rect and place it
     * at the portrait screen midpoint. This exact full-screen shape rules
     * out partial overlays, deliberate scaling, and transition offsets. */
    if(!isfinite(windowBounds.origin.x) || !isfinite(windowBounds.origin.y) ||
            !isfinite(windowBounds.size.width) ||
            !isfinite(windowBounds.size.height) ||
            !isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
            !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
            !isfinite(center.x) || !isfinite(center.y) ||
            fabs(windowBounds.origin.x) >= epsilon ||
            fabs(windowBounds.origin.y) >= epsilon ||
            fabs(bounds.origin.x) >= epsilon ||
            fabs(bounds.origin.y) >= epsilon ||
            fabs(bounds.size.width - windowBounds.size.width) >= epsilon ||
            fabs(bounds.size.height - windowBounds.size.height) >= epsilon ||
            fabs(center.x - windowBounds.size.height * 0.5) >= epsilon ||
            fabs(center.y - windowBounds.size.width * 0.5) >= epsilon ||
            LC32LayerContainsRenderer(LC32NativeViewLayer(view))) return;

    /* The scene has already performed this turn. Preserve the controller's
     * bounds and every descendant transform; only remove the duplicate
     * window-space turn/translation. Native setters cannot enter guest
     * geometry overrides from this deferred native main-thread callback. */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LC32NativeSetViewTransform(view, CGAffineTransformIdentity);
    LC32NativeSetViewCenter(view, CGPointMake(
        CGRectGetMidX(windowBounds), CGRectGetMidY(windowBounds)));
    [CATransaction commit];
}

UIViewController *LC32ActiveOrientationController(
        UIViewController *controller) {
    while(controller) {
        if(controller.presentedViewController) {
            controller = controller.presentedViewController;
            continue;
        }
        /* A guest root controller implements the legacy rotation policy
         * itself. Only descend through native UIKit containers. */
        if(LC32ObjectUsesGuestClass(controller)) return controller;
        if([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *visible =
                ((UINavigationController *)controller).visibleViewController;
            if(visible) {
                controller = visible;
                continue;
            }
        }
        if([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *selected =
                ((UITabBarController *)controller).selectedViewController;
            if(selected) {
                controller = selected;
                continue;
            }
        }
        return controller;
    }
    return nil;
}

UIInterfaceOrientationMask LC32SupportedOrientationsForController(
        UIViewController *controller) {
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    if(!controller || !LC32ObjectUsesGuestClass(controller)) {
        return policy.declaredOrientations;
    }
    if(LC32GuestUsesFixedLandscapePhoneCanvas()) {
        const UIInterfaceOrientation requested = (UIInterfaceOrientation)
            LC32LegacyRequestedOrientation.load(std::memory_order_relaxed);
        const UIInterfaceOrientationMask requestedMask =
            LC32MaskForInterfaceOrientation(requested);
        if(LC32LegacyLandscapeSidesWidened.load(std::memory_order_relaxed)) {
            return policy.declaredOrientations;
        }
        if(requestedMask & UIInterfaceOrientationMaskLandscape) {
            /* The bundle side is only a safe launch-time fallback. Once the
             * initialized renderer explicitly requests a landscape side,
             * keep the native wrapper and scene on that exact side. */
            return requestedMask;
        }
        /* Renderer-era shouldAutorotate implementations can consult GL state
         * which is not initialized while UIKit installs the root. */
        return policy.declaredOrientations;
    }

    NSNumber *cached = objc_getAssociatedObject(
        controller, LC32LegacyOrientationMaskKey);
    if(!LC32CanQueryGuestOrientation()) {
        return cached ? (UIInterfaceOrientationMask)cached.unsignedLongLongValue
                      : policy.declaredOrientations;
    }

    const Class cls = object_getClass(controller);
    if(!LC32GuestClassHierarchyDefinesSelector(
            cls, @selector(supportedInterfaceOrientations))) {
        return policy.declaredOrientations;
    }
    using SupportedOrientations =
        UIInterfaceOrientationMask (*)(id, SEL);
    LC32GuestOrientationQueryScope queryScope;
    UIInterfaceOrientationMask mask =
        reinterpret_cast<SupportedOrientations>(objc_msgSend)(
            controller, @selector(supportedInterfaceOrientations));
    if(!mask) mask = policy.declaredOrientations;
    objc_setAssociatedObject(controller, LC32LegacyOrientationMaskKey,
        @(mask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return mask;
}

void LC32ApplyLegacyWindowPolicy(UIWindow *window) {
    if(!window || !window.guest_selfOrNull) return;
    if(!pthread_main_np()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            const bool previous = LC32SuppressGuestOrientationQuery;
            LC32SuppressGuestOrientationQuery = true;
            LC32ApplyLegacyWindowPolicy(window);
            LC32SuppressGuestOrientationQuery = previous;
        });
        return;
    }

    UIViewController *rootController =
        LC32NativeWindowRootViewController(window);
    UIViewController *guestRootController =
        LC32GuestWindowRootViewController(window);
    UIViewController *orientationController =
        LC32ActiveOrientationController(guestRootController);

    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    UIWindowScene *scene = window.windowScene;
    const CGRect sceneBounds = scene
        ? LC32WindowSceneBounds(window) : CGRectZero;
    const UIInterfaceOrientation current = scene
        ? LC32WindowSceneOrientation(window, sceneBounds)
        : UIInterfaceOrientationUnknown;
    const UIInterfaceOrientationMask currentMask =
        LC32MaskForInterfaceOrientation(current);
    UIInterfaceOrientation requested = (UIInterfaceOrientation)
        LC32LegacyRequestedOrientation.load(std::memory_order_relaxed);
    UIInterfaceOrientationMask requestedMask =
        LC32MaskForInterfaceOrientation(requested);
    const UIInterfaceOrientationMask legacyAxis =
        UIInterfaceOrientationIsLandscape(policy.preferredOrientation)
            ? UIInterfaceOrientationMaskLandscape
            : UIInterfaceOrientationMaskPortrait |
              UIInterfaceOrientationMaskPortraitUpsideDown;
    const bool observesLegacyLaunchAxis =
        policy.usesLegacyInitialOrientation && !requestedMask &&
        (currentMask & legacyAxis);

    LC32DecidePortraitHostedLandscape(window, current);
    if(LC32WindowIsPortraitHosted(window)) {
        [rootController setNeedsStatusBarAppearanceUpdate];
        if(@available(iOS 16.0, *)) {
            [rootController setNeedsUpdateOfSupportedInterfaceOrientations];
            static const void *observerKey = &observerKey;
            if(scene && !objc_getAssociatedObject(scene, observerKey)) {
                LC32PortraitHostGeometryObserver *observer =
                    [LC32PortraitHostGeometryObserver new];
                observer.window = window;
                [scene addObserver:observer forKeyPath:@"effectiveGeometry"
                           options:0 context:nullptr];
                objc_setAssociatedObject(scene, observerKey, observer,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                LC32WatchPortraitHostDeviceTurns(window);
#if !__has_feature(objc_arc)
                [observer release];
#endif
            }
            if(scene && !(currentMask & UIInterfaceOrientationMaskPortrait)) {
                /* Ask after UIKit has picked up the portrait-only mask. */
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIWindowSceneGeometryPreferencesIOS *preferences =
                        [[UIWindowSceneGeometryPreferencesIOS alloc]
                            initWithInterfaceOrientations:
                                UIInterfaceOrientationMaskPortrait];
                    [scene requestGeometryUpdateWithPreferences:preferences
                        errorHandler:^(NSError *error) {
                            fprintf(stderr, "LC32: portrait-hosted scene "
                                "orientation update failed: %s\n",
                                error.localizedDescription.UTF8String ?:
                                    "unknown error");
                        }];
#if !__has_feature(objc_arc)
                    [preferences release];
#endif
                });
            }
        }
        return;
    }

    UIInterfaceOrientationMask orientations =
        LC32SupportedOrientationsForController(orientationController);
    if(!orientations) {
        orientations = policy.declaredOrientations;
    }
    /* CoreSimulator can expose the opposite provisional landscape side while
     * the key window is being attached. A fixed phone canvas has one exact
     * selected side, so widening that mask would let the native wrapper choose
     * the simulator side and display the guest output upside down. */
    const bool fixedPhoneOrientationConflictsWithCurrent =
        LC32GuestUsesFixedLandscapePhoneCanvas() && currentMask &&
        (orientations == UIInterfaceOrientationMaskLandscapeLeft ||
         orientations == UIInterfaceOrientationMaskLandscapeRight) &&
        !(orientations & currentMask);
    if(observesLegacyLaunchAxis && (orientations & legacyAxis) &&
            !fixedPhoneOrientationConflictsWithCurrent) {
        /* UIInterfaceOrientation selected an initial side, not a permanent
         * supported-orientation mask. If this active controller still uses
         * the same axis, retain the scene's settled side alongside its raw
         * policy. This prevents a late 180-degree flip without affecting a
         * later controller which deliberately switches axes. */
        LC32CacheSettledLegacyOrientation(window, current);
        LC32CacheSettledLegacyOrientation(rootController, current);
        LC32CacheSettledLegacyOrientation(guestRootController, current);
        LC32CacheSettledLegacyOrientation(orientationController, current);
        orientations |= currentMask;
    }
    if(orientationController) {
        objc_setAssociatedObject(orientationController,
            LC32LegacyOrientationMaskKey, @(orientations),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if(@available(iOS 16.0, *)) {
        [orientationController setNeedsUpdateOfSupportedInterfaceOrientations];
    }
    [rootController setNeedsStatusBarAppearanceUpdate];

    if(!scene) return;
    /* Before makeKeyAndVisible, a scene can report a provisional landscape
     * side. Let UIKit settle it before applying a legacy initial-orientation
     * hint; an explicit guest status-bar request remains authoritative. */
    if(policy.usesLegacyInitialOrientation && ![window isKeyWindow] &&
            !requestedMask) {
        return;
    }
    UIInterfaceOrientationMask geometryOrientations =
        requestedMask & orientations ? requestedMask : orientations;
    /* A legacy controller which accepts exactly one orientation is a more
     * precise local policy than a permissive Info.plist. Do not publish this
     * inference into the process-wide explicit-request state. */
    if(!requestedMask && geometryOrientations &&
            !(geometryOrientations & (geometryOrientations - 1))) {
        requested = LC32FirstOrientationInMask(geometryOrientations);
        requestedMask = LC32MaskForInterfaceOrientation(requested);
        geometryOrientations = requestedMask;
    }
    if(LC32MaskForInterfaceOrientation(current) & geometryOrientations) {
        return;
    }

    if(@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc]
                initWithInterfaceOrientations:geometryOrientations];
        [scene requestGeometryUpdateWithPreferences:preferences
            errorHandler:^(NSError *error) {
                fprintf(stderr,
                    "LC32: legacy scene orientation update failed: %s\n",
                    error.localizedDescription.UTF8String ?: "unknown error");
            }];
#if !__has_feature(objc_arc)
        [preferences release];
#endif
    } else {
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

UIViewController *LC32OwningViewController(UIView *view) {
    for(UIResponder *responder = view; responder;
            responder = responder.nextResponder) {
        if([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        if([responder isKindOfClass:UIWindow.class]) break;
    }
    for(UIView *subview in [view.subviews reverseObjectEnumerator]) {
        UIViewController *controller = LC32OwningViewController(subview);
        if(controller) return controller;
    }
    return nil;
}

id LC32ObjectProperty(id object, const char *name) {
    SEL selector = sel_registerName(name);
    if(!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch(NSException *exception) {
        if(LC32IsGuestCrashException(exception)) @throw;
        return nil;
    }
}

bool LC32InstallLegacyDirectSubviewRoot(UIWindow *window) {
    if(!window || LC32NativeWindowRootViewController(window)) return false;

    const NSUInteger existingSubviewCount = window.subviews.count;
    if(!existingSubviewCount) return false;

    LC32PreserveRootlessRendererAutoresizing(window, true);

    UIViewController *controller =
        [[LC32LegacyWindowRootController alloc] initWithNibName:nil
                                                         bundle:nil];
    (void)controller.view;
    LC32NativeSetWindowRootViewController(window, controller);
    const bool installed =
        LC32NativeWindowRootViewController(window) == controller;
    if(installed) {
        /* Assigning a native root normally places its view above existing
         * direct children.  Move only that new implementation detail behind
         * the archived hierarchy so every preexisting child keeps its exact
         * relative order, including any private UIKit overlay. */
        LC32NativeSendSubviewToBack(window, controller.view);
        fprintf(stderr,
            "LC32: installed legacy direct-view window root (%lu subviews)\n",
            (unsigned long)existingSubviewCount);
    } else {
        LC32RestoreRootlessRendererAutoresizing(window);
    }
#if !__has_feature(objc_arc)
    [controller release];
#endif
    return installed;
}

void LC32AdoptLegacyRootViewController(UIWindow *window) {
    if(!window || !window.guest_selfOrNull) return;
    UIViewController *existing =
        LC32NativeWindowRootViewController(window);
    if(existing) {
        if(![existing isKindOfClass:
                LC32LegacyIPadContainerController.class] &&
                LC32ObjectUsesGuestClass(existing)) {
            const bool needsPhoneCanvas =
                LC32WindowNeedsImmediateLegacyPhoneCanvas(window, existing);
            if(LC32WindowNeedsLegacyIPadContainer(window) ||
                    needsPhoneCanvas) {
                LC32InstallGuestWindowRootViewController(window, existing,
                    needsPhoneCanvas
                        ? LC32LegacyPhoneCanvasGeometryMode(existing)
                        : LC32LegacyIPadGeometryModePreservePortraitCanvas);
            }
        }
        LC32ApplyLegacyWindowPolicy(window);
        LC32ScaleLegacyIPadWindow(window);
        return;
    }

    UIViewController *controller = nil;
    for(UIView *subview in [window.subviews reverseObjectEnumerator]) {
        controller = LC32OwningViewController(subview);
        if(controller) break;
    }

    id delegate = UIApplication.sharedApplication.delegate;
    UIWindow *delegateWindow = LC32ObjectProperty(delegate, "window");
    if(!controller && (!delegateWindow || delegateWindow == window)) {
        static const char *const candidateProperties[] = {
            "rootViewController", "viewController", "mainViewController",
            "navigationController",
        };
        for(const char *property : candidateProperties) {
            id candidate = LC32ObjectProperty(delegate, property);
            if([candidate isKindOfClass:UIViewController.class]) {
                controller = candidate;
                break;
            }
        }
    }

    if(!controller && LC32InstallLegacyDirectSubviewRoot(window)) {
        LC32ApplyLegacyWindowPolicy(window);
        LC32ScaleLegacyIPadWindow(window);
        return;
    }

    if(controller) {
        const bool needsPhoneCanvas =
            LC32WindowNeedsImmediateLegacyPhoneCanvas(window, controller);
        LC32InstallGuestWindowRootViewController(window, controller,
            needsPhoneCanvas
                ? LC32LegacyPhoneCanvasGeometryMode(controller)
                : LC32LegacyIPadGeometryModePreservePortraitCanvas);
        fprintf(stderr, "LC32: adopted legacy root view controller %s\n",
                object_getClassName(controller));
    }
    LC32ApplyLegacyWindowPolicy(window);
}

void LC32AdoptLegacyRootViewControllers(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *delegateWindow = LC32ObjectProperty(application.delegate,
                                                   "window");
    if(delegateWindow) {
        LC32AdoptLegacyRootViewController(delegateWindow);
        LC32ScaleLegacyIPadWindow(delegateWindow);
        return;
    }
    for(UIScene *scene in application.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            LC32AdoptLegacyRootViewController(window);
            LC32ScaleLegacyIPadWindow(window);
        }
    }
}

/* Before iOS 6 a plist with only UIInterfaceOrientation named the launch
 * side; the controller's shouldAutorotateToInterfaceOrientation: decided the
 * rest. Alien Space Retro accepts both landscape sides and flips its GL view
 * from willRotateToInterfaceOrientation:. Ask the controller after startup,
 * once the phone is held landscape (on either side), then allow both sides
 * and let UIKit rotate (which delivers that callback). */
void LC32WidenLegacyLandscapeSides(UIInterfaceOrientation side) {
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    const UIInterfaceOrientationMask declared = policy.declaredOrientations;
    const UIInterfaceOrientationMask sideMask =
        LC32MaskForInterfaceOrientation(side);
    if(LC32LegacyLandscapeSidesWidened.load(std::memory_order_relaxed) ||
            !policy.usesLegacyInitialOrientation ||
            !(sideMask & UIInterfaceOrientationMaskLandscape) ||
            (declared & sideMask) ||
            (declared != UIInterfaceOrientationMaskLandscapeLeft &&
             declared != UIInterfaceOrientationMaskLandscapeRight) ||
            LC32GetGuestExecutableSDKVersion() >= 0x60000 ||
            LC32PortraitHostedLandscape == LC32PortraitHostState::Hosted ||
            !LC32CanQueryGuestOrientation()) return;
    UIApplication *application = UIApplication.sharedApplication;
    for(UIScene *scene in application.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            if(!window.guest_selfOrNull) continue;
            LC32LegacyIPadContainerController *container =
                LC32LegacyContainerForWindow(window);
            UIViewController *root = container ?: (UIViewController *)
                LC32NativeWindowRootViewController(window);
            UIViewController *controller = container
                ? container.guestContentController : root;
            if(!controller || !LC32ObjectUsesGuestClass(controller) ||
                    !LC32GuestClassHierarchyDefinesSelector(
                        object_getClass(controller),
                        @selector(shouldAutorotateToInterfaceOrientation:)))
                continue;
            BOOL accepted;
            {
                LC32GuestOrientationQueryScope queryScope;
                accepted = ((BOOL (*)(id, SEL, UIInterfaceOrientation))
                    objc_msgSend)(controller,
                        @selector(shouldAutorotateToInterfaceOrientation:),
                        side);
            }
            if(!accepted) continue;
            const_cast<LC32GuestUIKitPolicy &>(policy).declaredOrientations =
                declared | sideMask;
            LC32LegacyLandscapeSidesWidened.store(
                true, std::memory_order_relaxed);
            objc_setAssociatedObject(controller, LC32LegacyOrientationMaskKey,
                @(declared | sideMask), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            fprintf(stderr, "LC32: %s accepts landscape side %ld; "
                "allowing both landscape sides\n",
                object_getClassName(controller), (long)side);
            /* The launch-side request (LC32ApplyLegacyWindowPolicy, or the
             * game's own status-bar side) still pins the scene; replace it. */
            NSInteger expected = LC32FirstOrientationInMask(declared);
            LC32LegacyRequestedOrientation.compare_exchange_strong(
                expected, UIInterfaceOrientationUnknown);
            if(@available(iOS 16.0, *)) {
                [root setNeedsUpdateOfSupportedInterfaceOrientations];
                UIWindowSceneGeometryPreferencesIOS *preferences =
                    [[UIWindowSceneGeometryPreferencesIOS alloc]
                        initWithInterfaceOrientations:declared | sideMask];
                [(UIWindowScene *)scene
                    requestGeometryUpdateWithPreferences:preferences
                    errorHandler:^(NSError *error) {
                        fprintf(stderr, "LC32: landscape side update "
                            "failed: %s\n",
                            error.localizedDescription.UTF8String ?:
                                "unknown error");
                    }];
#if !__has_feature(objc_arc)
                [preferences release];
#endif
            }
            [UIViewController attemptRotationToDeviceOrientation];
            /* The legacy window rotation for this device turn was refused
             * before the side was allowed; run it now. */
            dispatch_async(dispatch_get_main_queue(), ^{
                LC32NativeLegacyRotationFollowDevice();
            });
            return;
        }
    }
}

void LC32WatchLegacyLandscapeSides(void) {
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    static bool watching = false;
    if(watching || !policy.usesLegacyInitialOrientation ||
            !(policy.declaredOrientations &
              UIInterfaceOrientationMaskLandscape) ||
            LC32GetGuestExecutableSDKVersion() >= 0x60000) return;
    watching = true;
    [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    void (^check)(void) = ^{
        // Landscape device and interface sides share their raw values.
        const UIDeviceOrientation device = UIDevice.currentDevice.orientation;
        if(UIDeviceOrientationIsLandscape(device)) {
            LC32WidenLegacyLandscapeSides((UIInterfaceOrientation)device);
        }
    };
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIDeviceOrientationDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *) { check(); }];
    // Already held on the other side when startup finished.
    check();
    /* Held on the launch side: allow the other side now, while scene and
     * window agree, not in the middle of the first flip. There, the legacy
     * window has already followed the device ahead of the still-pinned
     * scene; the geometry request's interim scene update turns it back,
     * and UIKit drops the scene's own turn during that animation. */
    const UIDeviceOrientation device = UIDevice.currentDevice.orientation;
    if(UIDeviceOrientationIsLandscape(device) &&
            (policy.declaredOrientations & LC32MaskForInterfaceOrientation(
                (UIInterfaceOrientation)device))) {
        LC32WidenLegacyLandscapeSides(
            (UIInterfaceOrientation)device ==
                UIInterfaceOrientationLandscapeLeft
            ? UIInterfaceOrientationLandscapeRight
            : UIInterfaceOrientationLandscapeLeft);
    }
}

void LC32FinishGuestOrientationStartupAfterLaunch(void) {
    // FinishLaunching is posted after the launch delegate returns, but that
    // delegate may have queued the renderer's initialization on a zero-delay
    // timer. The first idle boundary lets that startup work run before any
    // compatibility-induced orientation callback. A dispatch_async from
    // makeKeyAndVisible could instead run inside a nested launch run loop.
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, LONG_MAX,
        ^(CFRunLoopObserverRef observer, CFRunLoopActivity) {
            // Deferred initialization can pump a nested run loop too. Only
            // the original UIApplicationMain callback depth is a safe idle.
            if(LC32GuestCallbackDepth() > LC32GuestOrientationStartupCallbackDepth)
                return;
            // BeforeWaiting can precede delivery of an already-signaled
            // timer port. Do not overtake a due zero-delay startup selector.
            CFRunLoopRef runLoop = CFRunLoopGetMain();
            CFStringRef mode = CFRunLoopCopyCurrentMode(runLoop);
            const CFAbsoluteTime nextTimer = mode
                ? CFRunLoopGetNextTimerFireDate(runLoop, mode) : 0;
            if(mode) CFRelease(mode);
            if(nextTimer > 0 && nextTimer <= CFAbsoluteTimeGetCurrent()) return;
            if(!LC32NativeLegacyRotationStartupSceneReady()) return;
            CFRunLoopObserverInvalidate(observer);
            LC32GuestOrientationStartupComplete.store(
                true, std::memory_order_release);
            LC32WatchLegacyLandscapeSides();
            // Recompute rather than permanently caching the Info.plist
            // fallback: initialized controllers can have narrower policies.
            if(LC32NativeLegacyRotationEnabled()) {
                LC32FinishNativeLegacyRotationStartup();
                // Rotation was held back until the renderer is up.
                for(UIScene *scene in
                        UIApplication.sharedApplication.connectedScenes) {
                    if(![scene isKindOfClass:UIWindowScene.class]) continue;
                    for(UIWindow *window in ((UIWindowScene *)scene).windows)
                        LC32FitFullScreenRootlessWindow(window);
                }
            } else {
                LC32AdoptLegacyRootViewControllers();
            }
            LC32RotatePortraitPhoneCanvasControllersAfterStartup();
        });
    if(observer) {
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        CFRelease(observer);
    }
}

void LC32AdoptLegacyPhoneCanvases(UIApplication *application) {
    if(!application) return;
    for(UIScene *scene in application.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            if(!window.guest_selfOrNull || ![window isKeyWindow]) {
                continue;
            }
            if(objc_getAssociatedObject(
                    window, LC32HideLegacyDirectGuestWindowRootKey)) {
                /* The controller's hidden view is only bookkeeping; the
                 * renderer is a direct UIWindow sibling. Containerizing the
                 * controller would leave that renderer outside the canvas
                 * and let the scene resize its fixed 320x480 surface. */
                LC32ScaleLegacyIPadWindow(window);
                continue;
            }
            LC32LegacyIPadContainerController *container =
                LC32LegacyContainerForWindow(window);
            if(container) {
                if(LC32GeometryModePreservesPhoneCanvas(
                        container.geometryMode)) {
                    LC32ScaleLegacyIPadWindow(window);
                }
                continue;
            }
            UIViewController *guestController =
                LC32GuestWindowRootViewController(window);
            if(!LC32WindowNeedsLegacyPhoneCanvas(
                    window, guestController)) {
                continue;
            }

            /* UIKit asserts if a controller is reparented while it is still
             * completing the application's initial appearance transition.
             * This function runs one turn after didBecomeActive, when that
             * transition is complete. The native container then owns future
             * scene layout while the guest retains its legacy drawable. */
            LC32InstallGuestWindowRootViewController(
                window, guestController,
                LC32LegacyPhoneCanvasGeometryMode(guestController));
            LC32ApplyLegacyWindowPolicy(window);
            dispatch_async(dispatch_get_main_queue(), ^{
                LC32ScaleLegacyIPadWindow(window);
                /* Replacing a live root controller can enqueue one more
                 * UIWindow layout pass after this block. Reassert only the
                 * native scene frame once more; the child canvas is managed
                 * by the compatibility container itself. */
                dispatch_async(dispatch_get_main_queue(), ^{
                    LC32ScaleLegacyIPadWindow(window);
                });
            });
            fprintf(stderr,
                "LC32: isolated legacy phone canvas in landscape scene\n");
        }
    }
}

} // namespace

/* LegacyRotation.mm: legacy controllers (the game's movie player) must keep a
 * hosted full-screen game's scene portrait. */
extern "C" bool LC32FullScreenRootlessHostingActive(void) {
    return LC32FullScreenRootlessHosting.load(std::memory_order_acquire);
}

/* LegacyRotation.mm: its startup gate waits for the scene to reach one of the
 * guest's declared orientations. A portrait-hosted landscape game (Starfront,
 * 9mm, Grabatron, Air Mail) or a fixed portrait phone canvas keeps the scene
 * portrait on purpose, so a portrait scene is already settled for them. */
extern "C" bool LC32UIKitKeepsLegacyScenePortrait(void) {
    return LC32FullScreenRootlessHosting.load(std::memory_order_acquire) ||
        LC32PortraitHostedLandscape == LC32PortraitHostState::Hosted ||
        LC32GuestUsesFixedPortraitPhoneCanvas();
}

/* LegacyMoviePlayer.mm: fit the game window again after a movie closed. */
extern "C" void LC32RefitFullScreenRootlessWindowAfterMovie(UIWindow *window) {
    LC32RefitFullScreenRootlessWindowLater(window, "movie");
}

/* LegacyMoviePlayer.mm: a rootless guest window that is the fixed portrait
 * phone canvas a landscape game draws its picture into sideways (N.O.V.A. 2),
 * whether UIKit turns the window for a landscape scene or it is hosted
 * upright in a portrait one. */
extern "C" bool LC32WindowIsLandscapeGamePortraitCanvas(UIWindow *window) {
    return LC32WindowUsesRootlessPhoneCanvas(window) &&
        LC32WindowHasGuestPortraitCanvasSize(LC32NativeViewLayer(window));
}

/* LegacyMoviePlayer.mm restores a movie presenter's view placed straight in
 * such a window, as it does for views embedded in a renderer. */
extern "C" bool LC32ViewIsInTurnedFullScreenRootlessWindow(UIView *view) {
    UIWindow *window = view ? LC32NativeViewWindow(view) : nil;
    CALayer *parent = window ? LC32NativeViewLayer(window).superlayer : nil;
    return parent && LC32NativeViewSuperview(view) == window &&
        (objc_getAssociatedObject(parent, LC32FullScreenRootlessTurnKey) ||
         LC32WindowIsFullScreenRootlessHosted(window));
}

@implementation LC32FullScreenRootlessGeometryObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    UIWindow *window = self.window;
    dispatch_async(dispatch_get_main_queue(), ^{
        LC32FitFullScreenRootlessWindow(window);
    });
}
@end

@implementation LC32PortraitHostGeometryObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    UIWindow *window = self.window;
    dispatch_async(dispatch_get_main_queue(), ^{
        LC32LeavePortraitHostForLandscapeDevice(window);
        if(LC32WindowUsesRootlessPhoneCanvas(window)) {
            LC32ScheduleRootlessWindowLayerLayout(window);
        } else {
            LC32ScaleLegacyIPadWindow(window);
        }
    });
}
@end

extern "C" u32 LC32UIKitLegacyIPadCanvasEnabled(void) {
#if LC32_UIKIT_COMPATIBILITY
    // A narrow iPadOS scene is not an iPhone. Leave native iPad geometry and
    // input alone even in Split View; only virtualize iPad guests on a phone.
    return (LC32UIKitLegacyCompatibilityEnabled() ||
            LC32NativeLegacyRotationEnabled()) &&
        UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
        LC32GuestNeedsLegacyIPadCanvas();
#else
    return 0;
#endif
}

/* Like the iPad canvas, the fixed phone canvas must also be composited when
 * the host reports the guest's pre-iOS-8 SDK: native UIKit then owns legacy
 * rotation, but the scene can still be the physical full screen even with
 * Classic Mode requested. */
extern "C" u32 LC32UIKitNativeFixedPhoneCanvasEnabled(void) {
#if LC32_UIKIT_COMPATIBILITY
    return !LC32UIKitLegacyCompatibilityEnabled() &&
        LC32NativeLegacyRotationEnabled() &&
        LC32GuestLegacyCanvasPolicy().phoneCanvasHost &&
        LC32GuestUsesFixedLandscapePhoneCanvas();
#else
    return 0;
#endif
}

/* Guest-visible UIScreen geometry of the fixed 320x480 (or 320x568) phone
 * canvas. The
 * guest UIKit derives it itself only for phone-only bundles on SDK-clamped
 * hosts; answering at the bridge also covers universal bundles and hosts
 * that report the guest's pre-iOS-8 SDK, whose scene can still be the
 * physical full screen. */
/* Long edge of the fixed phone canvas (480, or 568 for tall bundles), for
 * code outside UIKit such as the JIT's per-game code fixes. */
extern "C" double LC32UIKitPhoneCanvasLongEdge(void) {
    return LC32GuestPhoneCanvasLongEdge();
}

extern "C" bool LC32UIKitFixedLandscapePhoneScreen(
        CGRect *bounds, CGRect *applicationFrame) {
#if LC32_UIKIT_COMPATIBILITY
    if(!(LC32UIKitLegacyCompatibilityEnabled() ||
            LC32NativeLegacyRotationEnabled()) ||
            !(LC32GuestUsesFixedLandscapePhoneCanvas() ||
              LC32GuestUsesFixedPortraitPhoneCanvas())) {
        return false;
    }
    const CGFloat longEdge = LC32GuestPhoneCanvasLongEdge();
    if(bounds) *bounds = CGRectMake(0, 0, 320, longEdge);
    if(applicationFrame) {
        *applicationFrame = LC32GuestInterfacePolicy().statusBarHidden
            ? CGRectMake(0, 0, 320, longEdge)
            : CGRectMake(0, 20, 320, longEdge - 20);
    }
    return true;
#else
    return false;
#endif
}

/* iOS 8 made UIScreen bounds interface-oriented and launches a
 * landscape-only app straight into landscape, so its bounds are already
 * landscape in application:didFinishLaunching:. Our scene starts in the
 * launcher's portrait and turns only once the guest's root controller exists,
 * so an SDK 8+ engine that sizes its GL view and drawable from the launch
 * bounds and never reallocates them (Galaxy on Fire 2 HD: empty
 * layoutSubviews) keeps a portrait drawable squeezed into the turned view.
 * True when such a guest must see a portrait screen's landscape extent.
 * Pre-iOS-8 guests expect portrait bounds in every orientation.
 * LC32_LANDSCAPE_LAUNCH_BOUNDS=0 turns this off. */
extern "C" bool LC32UIKitGuestScreenIsLandscapeOnly(void) {
#if LC32_UIKIT_COMPATIBILITY
    static const bool disabled = [] {
        const char *value = getenv("LC32_LANDSCAPE_LAUNCH_BOUNDS");
        return value && value[0] == '0';
    }();
    if(disabled || LC32GetGuestExecutableSDKVersion() < 0x80000 ||
            LC32NativeLegacyRotationEnabled() ||
            LC32GuestUsesFixedLandscapePhoneCanvas() ||
            LC32GuestUsesFixedPortraitPhoneCanvas() ||
            LC32GuestNeedsLegacyIPadCanvas()) {
        return false;
    }
    const UIInterfaceOrientationMask declared =
        LC32GuestInterfacePolicy().declaredOrientations;
    return (declared & UIInterfaceOrientationMaskLandscape) &&
        !(declared & (UIInterfaceOrientationMaskPortrait |
                      UIInterfaceOrientationMaskPortraitUpsideDown));
#else
    return false;
#endif
}

extern "C" BOOL LC32NativeLegacyRotationCanCallGuest(void) {
    return LC32CanQueryGuestOrientation();
}

extern "C" UIViewController *LC32NativeLegacyRotationContentController(
        UIViewController *controller) {
    if([controller isKindOfClass:LC32LegacyIPadContainerController.class])
        return ((LC32LegacyIPadContainerController *)controller).guestContentController;
    return controller;
}

extern "C" void LC32UIKitDidSetGuestAutoresizingMask(id object) {
    if(!LC32UIKitLegacyCompatibilityEnabled()) return;
    if(!pthread_main_np() || LC32GetGuestExecutableSDKVersion() >= 0x80000 ||
            ![object isKindOfClass:UIView.class]) return;
    LC32LegacyRendererAutoresizingState *state = objc_getAssociatedObject(
        object, LC32LegacyRootlessRendererAutoresizingStateKey);
    if(state) {
        /* This runs only after a guest setter, not our typed native setters.
         * Even an explicit None after detachment relinquishes ownership of
         * the frozen mask. The record retains neither its view nor window. */
        state.yielded = YES;
    }
}

extern "C" void LC32UIKitScheduleLegacyOverlayLayout(
        id object, id addedSubview) {
    if(!LC32UIKitLegacyCompatibilityEnabled()) return;
    if(!pthread_main_np() || LC32GetGuestExecutableSDKVersion() >= 0x80000) {
        return;
    }
    if(addedSubview) {
        /* A selector with this name on an unrelated class need not take an
         * object argument. Inspect only the known-valid receiver first. */
        if(![object isKindOfClass:UIView.class]) return;
        if([object isKindOfClass:UIWindow.class]) {
            LC32PreserveRootlessRendererAutoresizing((UIWindow *)object);
        }
        LC32ScheduleRootlessWindowLayerLayout(
            LC32NativeViewWindow((UIView *)object));
        if(![object isKindOfClass:UIWindow.class]) return;
        object = addedSubview;
    }
    if(![object isKindOfClass:UIView.class]) return;
    UIView *view = (UIView *)object;
    if([view isKindOfClass:UIWindow.class]) {
        LC32ScheduleRootlessWindowLayerLayout((UIWindow *)view);
        return;
    }
    if(![LC32NativeViewSuperview(view) isKindOfClass:UIWindow.class]) return;
    const UIInterfaceOrientation rootOrientation =
        LC32LegacyRootWindowGeometry(view, true);
    objc_setAssociatedObject(view, LC32LegacyRootWindowGeometryKey,
        rootOrientation ? @(rootOrientation) : nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(objc_getAssociatedObject(view, LC32LegacyOverlayLayoutPendingKey)) {
        return;
    }
    objc_setAssociatedObject(view, LC32LegacyOverlayLayoutPendingKey,
        @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(view, LC32LegacyOverlayLayoutPendingKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LC32FitLegacyControllerRoot(view);
        LC32FitLegacyControllerOverlay(view);
    });
}

extern "C" bool LC32UIKitGetViewDuringGuestLoad(
        id object, id *view) {
    if(![object isKindOfClass:UIViewController.class] ||
            !LC32GuestLoadViewIsActive((UIViewController *)object)) {
        return false;
    }

    UIView *loadedView = nil;
    if(!LC32NativeViewIfLoaded((UIViewController *)object, &loadedView)) {
        return false;
    }
    if(view) *view = loadedView;
    return true;
}

@implementation LC32LegacyWindowRootController

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    /* Scene-driven window resizing can settle after makeKeyAndVisible.
     * Refit presentation from this inert native root without laying out the
     * guest renderer or intercepting ordinary guest view layout. */
    LC32ScheduleRootlessWindowLayerLayout(LC32NativeViewWindow(self.view));
}

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    view.userInteractionEnabled = NO;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    self.view = view;
#if !__has_feature(objc_arc)
    [view release];
#endif
    // See LC32WindowFollowsFixedCanvasRootPolicy.
    if(LC32UIKitGuestFixedCanvasDeviceOrientation(nullptr))
        LC32InstallLegacyPortraitWindowMask();
}

/* A full-screen presentation (Modern Combat 4's movies) takes this view out
 * of its window, but the orientation answers below are still about it. */
- (UIWindow *)lc32_hostWindow {
    UIWindow *window = LC32NativeViewWindow(self.viewIfLoaded);
    if(window) return window;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if(LC32NativeWindowRootViewController(candidate) == self)
                return candidate;
        }
    }
    return nil;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIWindow *window = [self lc32_hostWindow];
    if(LC32WindowIsPortraitHosted(window)) {
        /* Upright or flat, the scene stays portrait whatever is presented;
         * held sideways, it may turn and leave hosting
         * (LC32LeavePortraitHostForLandscapeDevice). */
        return LC32PortraitHostFollowsLandscapeDevice(window) &&
                LC32PortraitHostDeviceIsSideways(window)
            ? UIInterfaceOrientationMaskPortrait |
                UIInterfaceOrientationMaskLandscape
            : UIInterfaceOrientationMaskPortrait;
    }
    const UIInterfaceOrientationMask declared =
        LC32GuestInterfacePolicy().declaredOrientations;
    /* The canvas is a landscape screen; a Portrait entry beside both
     * landscape sides (Modern Combat 4) would turn it sideways. */
    if(LC32GuestUsesFixedLandscapePhoneCanvas() &&
            (declared & UIInterfaceOrientationMaskLandscape) ==
                UIInterfaceOrientationMaskLandscape)
        return UIInterfaceOrientationMaskLandscape;
    return declared;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    if(LC32WindowIsPortraitHosted([self lc32_hostWindow]))
        return UIInterfaceOrientationPortrait;
    const UIInterfaceOrientationMask mask =
        [self supportedInterfaceOrientations];
    const UIInterfaceOrientation target = LC32LegacyTargetOrientation(self);
    return LC32MaskForInterfaceOrientation(target) & mask
        ? target : LC32FirstOrientationInMask(mask);
}

- (BOOL)prefersStatusBarHidden {
    return LC32GuestInterfacePolicy().statusBarHidden;
}

- (BOOL)shouldAutomaticallyForwardRotationMethods {
    return NO;
}

@end

/* iOS 4 composited a landscape root controller's view over sibling views the
 * game added straight to the 320x480 window (Zenonia 2: a portrait EAGLView
 * that rotates in its projection, under the turned RootController UI). Keep
 * those siblings visible and laid over the same scaled canvas area. */
/* The container's own wrappers must not take touches that iOS 4 delivered to
 * those siblings once the root view stops accepting them. */
@interface LC32LegacyCanvasWrapperView : UIView
@property(nonatomic) BOOL passesTouchesThrough;
@end

@implementation LC32LegacyCanvasWrapperView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return self.passesTouchesThrough && hit == self ? nil : hit;
}
@end

static void LC32FitLegacyCanvasSiblingViews(UIView *containerView,
                                            UIView *canvasView) {
    UIWindow *window = containerView.window;
    if(!window || !window.guest_selfOrNull ||
            !LC32GuestUsesFixedLandscapePhoneCanvas()) return;
    const CGRect area = [canvasView convertRect:canvasView.bounds
                                         toView:window];
    const CGFloat canvasLong = LC32GuestPhoneCanvasLongEdge();
    constexpr CGFloat epsilon = 0.5;
    bool hasSiblings = false;
    for(UIView *view in LC32NativeViewSubviews(window)) {
        if(view == containerView || !view.guest_selfOrNull) continue;
        const CGSize size = LC32NativeViewBounds(view).size;
        if(fabs(size.width - 320) >= epsilon ||
                fabs(size.height - canvasLong) >= epsilon) continue;
        const CGFloat scale = area.size.width / size.width;
        if(!(scale > 0) || !isfinite(scale)) continue;
        hasSiblings = true;
        LC32NativeSetViewTransform(view,
            CGAffineTransformMakeScale(scale, scale));
        LC32NativeSetViewCenter(view,
            CGPointMake(CGRectGetMidX(area), CGRectGetMidY(area)));
    }
    if(!hasSiblings) return;
    containerView.backgroundColor = UIColor.clearColor;
    for(UIView *wrapper in @[containerView, canvasView]) {
        if([wrapper isKindOfClass:LC32LegacyCanvasWrapperView.class])
            ((LC32LegacyCanvasWrapperView *)wrapper).passesTouchesThrough = YES;
    }
}

@implementation LC32LegacyIPadContainerController

@synthesize guestContentController = _guestContentController;
@synthesize geometryMode = _geometryMode;

- (instancetype)initWithGuestContentController:
        (UIViewController *)controller
                                  geometryMode:
        (LC32LegacyIPadGeometryMode)mode {
    self = [super initWithNibName:nil bundle:nil];
    if(self) {
        _geometryMode = mode;
        if(controller) {
            [self setGuestContentController:controller geometryMode:mode];
        }
    }
    return self;
}

- (void)loadView {
    UIView *view = [[LC32LegacyCanvasWrapperView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = UIColor.blackColor;
    view.clipsToBounds = YES;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    self.view = view;

    /* The wrapper is always a native UIView. Transforming a mirrored guest
     * subclass directly can invoke a guest setter from a host scene callback,
     * and also lets UIKit rewrite the guest EAGL view transform during modern
     * rotation. UIView hit testing automatically applies the inverse wrapper
     * transform before delivering touches to the guest hierarchy. */
    UIView *canvas = [[LC32LegacyCanvasWrapperView alloc]
        initWithFrame:CGRectZero];
    canvas.backgroundColor = UIColor.clearColor;
    canvas.clipsToBounds = YES;
    canvas.autoresizingMask = UIViewAutoresizingNone;
    [view addSubview:canvas];
    _canvasView = canvas;
#if !__has_feature(objc_arc)
    [canvas release];
    [view release];
#endif
}

- (void)setGuestContentController:(UIViewController *)controller
                      geometryMode:(LC32LegacyIPadGeometryMode)mode {
    if(controller == _guestContentController) {
        if(_geometryMode != mode) {
            _geometryMode = mode;
            [self fitGuestContentForViewport:self.view.bounds
                hostOrientation:UIInterfaceOrientationUnknown];
        }
        return;
    }

    ++_guestContentGeneration;
    _guestLayoutPending = NO;
    UIViewController *oldController = _guestContentController;
    UIView *oldView = _guestContentView;
    if(oldController) [oldController willMoveToParentViewController:nil];
    [oldView removeFromSuperview];
    [oldController removeFromParentViewController];
    _guestContentController = nil;
    _guestContentView = nil;
    _canonicalGuestBounds = CGRectZero;
    _guestRootLayout = CGRectZero;
    _geometryMode = mode;

    if(!controller) return;

    /* Loading is deliberately done while the guest assigns or exposes its
     * root on a registered guest thread. Later refits use only retained views
     * and native UIView IMPs; they never ask the controller to load. */
    (void)self.view;
    /* The guest rootViewController accessor unwraps this native container.
     * Publish the controller before forcing -view so loadView/viewDidLoad can
     * observe the root that the guest just assigned. */
    const NSUInteger generation = _guestContentGeneration;
    _guestContentController = controller;
    UIView *contentView = controller.view;
    if(generation != _guestContentGeneration ||
            controller != _guestContentController) {
        /* Loading the guest view can synchronously replace the window root.
         * Let that nested install own the container instead of resuming this
         * stale generation and overwriting its controller/view pair. */
        return;
    }
    if(_geometryMode ==
            LC32LegacyIPadGeometryModePreservePhonePortraitCanvas &&
            LC32GuestUsesFixedLandscapePhoneCanvas() &&
            LC32PhoneCanvasGeometryModeWasGuessed(controller)) {
        /* The root was installed before its view existed (Zenonia 4), so
         * the portrait canvas was only a default. Classify the loaded view. */
        _geometryMode = LC32LegacyPhoneCanvasGeometryMode(controller);
    }
    CGRect canonicalBounds = LC32NativeViewBounds(contentView);
    const CGFloat shortEdge = MIN(canonicalBounds.size.width,
                                  canonicalBounds.size.height);
    const CGFloat longEdge = MAX(canonicalBounds.size.width,
                                 canonicalBounds.size.height);
    if(_geometryMode ==
            LC32LegacyIPadGeometryModePreservePhonePortraitCanvas) {
        const CGAffineTransform transform =
            LC32NativeViewTransform(contentView);
        const CGAffineTransform landscapeLeftTransform =
            CGAffineTransformMake(0, 1, -1, 0, 0, 0);
        const CGAffineTransform landscapeRightTransform =
            CGAffineTransformMake(0, -1, 1, 0, 0, 0);
        if(LC32TransformNearlyEquals(
                transform, landscapeLeftTransform) ||
                LC32TransformNearlyEquals(
                    transform, landscapeRightTransform)) {
            /* UIKit can already have applied the obsolete root-window turn
             * if this is the post-key fallback. It is redundant once the
             * portrait canvas is a child of the native scene container. */
            LC32NativeSetViewTransform(
                contentView, CGAffineTransformIdentity);
        }
        /* Old phone GL engines commonly allocate a portrait surface from
         * UIScreen.bounds and apply the selected landscape orientation in
         * their projection matrix. Preserve the full surface and reproduce
         * UIKit's old compositor turn on the native wrapper below. */
        canonicalBounds = CGRectMake(
            canonicalBounds.origin.x, canonicalBounds.origin.y,
            320, LC32GuestPhoneCanvasLongEdge());
    } else if(_geometryMode ==
            LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas) {
        const CGAffineTransform transform =
            LC32NativeViewTransform(contentView);
        const CGAffineTransform landscapeLeftTransform =
            CGAffineTransformMake(0, 1, -1, 0, 0, 0);
        const CGAffineTransform landscapeRightTransform =
            CGAffineTransformMake(0, -1, 1, 0, 0, 0);
        if(LC32TransformNearlyEquals(
                transform, landscapeLeftTransform) ||
                LC32TransformNearlyEquals(
                    transform, landscapeRightTransform)) {
            /* UIKit may already have applied an obsolete root-window turn.
             * It is redundant once the landscape canvas is a child of the
             * native scene container. */
            LC32NativeSetViewTransform(
                contentView, CGAffineTransformIdentity);
        }
        if(!isfinite(shortEdge) || !isfinite(longEdge) ||
                shortEdge <= 0 || longEdge <= 0 ||
                LC32GuestUsesFixedLandscapePhoneCanvas()) {
            /* A fixed canvas is the guest's whole screen, even when UIKit
             * already sized the root to the scene (Zenonia 2). */
            canonicalBounds = CGRectMake(
                0, 0, LC32GuestPhoneCanvasLongEdge(), 320);
        } else {
            /* The runtime probe deliberately matches by short/long edge: the
             * archived root may still be portrait-ordered while carrying the
             * obsolete UIKit quarter-turn cleared above. Once isolated in the
             * native wrapper, store its canonical drawable as 480x320. */
            canonicalBounds.size = CGSizeMake(longEdge, shortEdge);
        }
    } else if(!isfinite(shortEdge) || !isfinite(longEdge) ||
            shortEdge < 700 || longEdge < 900) {
        canonicalBounds = CGRectMake(0, 0, 768, 1024);
    }

    _guestContentView = contentView;
    _canonicalGuestBounds = canonicalBounds;
    fprintf(stderr, "LC32: canvas root %s mode %d (%.0fx%.0f)\n",
        object_getClassName(controller), (int)_geometryMode,
        canonicalBounds.size.width, canonicalBounds.size.height);
    [self addChildViewController:controller];
    [_canvasView addSubview:contentView];
    [controller didMoveToParentViewController:self];
    LC32NativeSetViewAutoresizingMask(contentView, UIViewAutoresizingNone);
    [self fitGuestContentForViewport:self.view.bounds
        hostOrientation:UIInterfaceOrientationUnknown];
    [self scheduleGuestLayout];
    if(LC32GeometryModePreservesPhoneCanvas(_geometryMode) &&
            LC32GuestUsesFixedLandscapePhoneCanvas()) {
        /* Adding controls to the root, or views beside it in the window,
         * lays out nothing here. Look again once launch has populated them
         * for a landscape layout and for siblings to fit. */
        for(double delay : {0.5, 2.0, 5.0}) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(delay * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    if(generation != _guestContentGeneration) return;
                    [self fitGuestContentForViewport:self.view.bounds
                        hostOrientation:UIInterfaceOrientationUnknown];
                });
        }
    }
}

- (void)fitGuestContentForViewport:(CGRect)viewport
                   hostOrientation:(UIInterfaceOrientation)orientation {
    UIView *contentView = _guestContentView;
    UIView *canvasView = _canvasView;
    if(!contentView || !canvasView || _fittingGuestContent) return;
    /* Layout callbacks can still report the archived 768x1024 root bounds
     * even after the window is attached to a smaller compatibility scene.
     * For settled refits, always prefer that scene's visible extent. The
     * transition callback supplies a concrete future size and is retained as
     * the pre-settlement fallback until its completion runs. */
    if(LC32NativeLegacyRotationEnabled()) {
        // UIKit already turns this root inside the portrait window backing.
        // Scene-space conversion includes that compositor turn a second time.
        viewport = LC32NativeViewBounds(self.view);
    } else if(orientation == UIInterfaceOrientationUnknown) {
        UIWindow *window = self.view.window;
        const bool preservesInferredIPadCanvas =
            _geometryMode ==
                LC32LegacyIPadGeometryModeReflowRootController &&
            LC32GuestUsesFixedLandscapeIPadCanvas() &&
            LC32WindowNeedsLegacyIPadContainer(window);
        if(preservesInferredIPadCanvas) {
            /* UIKit's scene conversion describes the visible phone viewport,
             * but the classic compositor scales this fixed iPad window again.
             * Preserve its 1x canvas here to avoid applying both scales. */
            viewport = LC32NativeViewBounds(self.view);
        } else if(window.windowScene) {
            viewport = LC32LegacyViewportInView(window, self.view);
        }
    }
    if(!(viewport.size.width > 0) || !(viewport.size.height > 0)) {
        viewport = self.view.bounds;
    }
    const CGSize viewportSize = viewport.size;
    if(!(viewportSize.width > 0) || !(viewportSize.height > 0)) return;

    _fittingGuestContent = YES;
    if(_geometryMode ==
            LC32LegacyIPadGeometryModePreservePhonePortraitCanvas &&
            LC32GuestUsesFixedLandscapePhoneCanvas() &&
            !LC32PhoneCanvasHasPortraitGLChild(contentView) &&
            LC32PhoneCanvasContentHasLandscapeLayout(contentView)) {
        /* Engines that add their controls after the root is installed
         * (Zenonia 5) only now show that the root is a landscape canvas. */
        _geometryMode = LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas;
        _canonicalGuestBounds =
            CGRectMake(0, 0, LC32GuestPhoneCanvasLongEdge(), 320);
    }
    const UIInterfaceOrientation target = LC32NativeLegacyRotationEnabled()
        ? self.interfaceOrientation
        : LC32LegacyTargetOrientation(_guestContentController);
    CGRect canonicalBounds = _canonicalGuestBounds;
    if(!(canonicalBounds.size.width > 0) ||
            !(canonicalBounds.size.height > 0)) {
        canonicalBounds = CGRectMake(0, 0, 768, 1024);
    }

    CGSize logicalSize = canonicalBounds.size;
    CGFloat compositorAngle = 0;
    if(_geometryMode ==
            LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas) {
        /* This drawable is already landscape. Center it without recreating
         * the portrait-canvas compositor turn, unless nothing turned the
         * root for a portrait-hosted scene: the guest never asked for a
         * landscape status bar (cocos2d in Zenonia 5), so turn it here. */
        if(LC32GuestUsesFixedLandscapePhoneCanvas() &&
                viewportSize.width < viewportSize.height) {
            compositorAngle =
                LC32PortraitHostedLandscapeSide() ==
                    UIInterfaceOrientationLandscapeLeft ? -M_PI_2 : M_PI_2;
        }
    } else if(_geometryMode ==
            LC32LegacyIPadGeometryModeReflowRootController) {
        /* The bridged rootViewController setter is the observable lifecycle
         * boundary between old resize-aware apps and pre-controller window
         * composition. In this mode UIKit historically resized the hierarchy
         * to the requested orientation, so resize-aware engines receive a
         * real 1024x768 EAGL drawable in landscape. The already-oriented scene
         * then displays it with an identity compositor. */
        const CGFloat shortEdge = MIN(logicalSize.width, logicalSize.height);
        const CGFloat longEdge = MAX(logicalSize.width, logicalSize.height);
        logicalSize = UIInterfaceOrientationIsLandscape(target)
            ? CGSizeMake(longEdge, shortEdge)
            : CGSizeMake(shortEdge, longEdge);
    } else {
        /* Pre-controller iPad applications and legacy landscape phone games
         * both keep a portrait drawable. Preserve that contract and recreate
         * the old root compositor on this native wrapper only. */
        switch(target) {
            case UIInterfaceOrientationLandscapeLeft:
                compositorAngle = M_PI_2;
                break;
            case UIInterfaceOrientationLandscapeRight:
                compositorAngle = -M_PI_2;
                break;
            case UIInterfaceOrientationPortraitUpsideDown:
                compositorAngle = M_PI;
                break;
            default:
                break;
        }
    }

    const CGAffineTransform rotation =
        CGAffineTransformMakeRotation(compositorAngle);
    const CGRect transformedBounds = CGRectApplyAffineTransform(
        CGRectMake(0, 0, logicalSize.width, logicalSize.height), rotation);
    const CGFloat transformedWidth = fabs(transformedBounds.size.width);
    const CGFloat transformedHeight = fabs(transformedBounds.size.height);
    CGFloat scale = transformedWidth > 0 && transformedHeight > 0
        ? MIN(viewportSize.width / transformedWidth,
              viewportSize.height / transformedHeight)
        : 0;
    if(_geometryMode ==
            LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas &&
            !LC32GuestUsesFixedLandscapePhoneCanvas()) {
        /* Only a 480x320 view inside a taller app stays at 1x; a fixed
         * canvas is the guest's whole screen and fills the scene. */
        scale = MIN((CGFloat)1, scale);
    }
    if(scale > 0 && isfinite(scale)) {
        const CGRect desiredContentBounds = CGRectMake(
            canonicalBounds.origin.x, canonicalBounds.origin.y,
            logicalSize.width, logicalSize.height);
        const bool usesGuestRootLayout =
            _guestRootLayout.size.width > 0 &&
            _geometryMode ==
                LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas;
        const BOOL contentBoundsChanged = !CGSizeEqualToSize(
            LC32NativeViewBounds(contentView).size,
            usesGuestRootLayout ? _guestRootLayout.size
                                : desiredContentBounds.size);

        canvasView.transform = CGAffineTransformIdentity;
        canvasView.bounds = CGRectMake(
            0, 0, logicalSize.width, logicalSize.height);
        canvasView.center = CGPointMake(
            CGRectGetMidX(viewport), CGRectGetMidY(viewport));
        canvasView.transform = CGAffineTransformScale(rotation, scale, scale);

        /* Use UIView's native implementations so a mirrored guest subclass
         * cannot turn a host geometry callback into a nested guest call. Keep
         * any application-authored transform on the content view itself. */
        CGRect contentBounds = desiredContentBounds;
        CGPoint contentCenter = CGPointMake(
            logicalSize.width * 0.5, logicalSize.height * 0.5);
        if(usesGuestRootLayout) {
            contentBounds.size = _guestRootLayout.size;
            contentCenter = _guestRootLayout.origin;
        }
        LC32NativeSetViewBounds(contentView, contentBounds);
        LC32NativeSetViewCenter(contentView, contentCenter);
        LC32NativeSetViewAutoresizingMask(contentView, UIViewAutoresizingNone);
        if(contentBoundsChanged) {
            LC32NativeSetViewNeedsLayout(contentView);
            [self scheduleGuestLayout];
        }
        if(_geometryMode ==
                LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas &&
                !LC32ControllerIsMoviePlayer(_guestContentController)) {
            LC32FitLegacyCanvasSiblingViews(self.view, canvasView);
        }
    }
    _fittingGuestContent = NO;
}

/* Pre-iOS-8 UIKit turned a landscape root controller's view with a
 * transform, so a frame the game assigns to that view is in the portrait
 * window's coordinates. Tapsonic's TapsonicBaseView pillarboxes its 480-wide
 * screens on a 568-point iPhone with self.frame = {0,44,320,480}. The fixed
 * landscape canvas holds the root unturned: convert such a portrait frame to
 * landscape bounds and center (and keep them across refits). */
- (BOOL)applyGuestRootFrame:(CGRect)frame {
    UIView *contentView = _guestContentView;
    if(!contentView || !_canvasView ||
            _geometryMode !=
                LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas ||
            !LC32GuestUsesFixedLandscapePhoneCanvas() ||
            !(frame.size.width > 0) ||
            !(frame.size.height > frame.size.width)) {
        return NO;
    }
    const CGFloat longEdge = LC32GuestPhoneCanvasLongEdge();
    const CGFloat shortEdge = 320;
    if(frame.size.height > longEdge + 0.5 ||
            frame.size.width > shortEdge + 0.5) {
        return NO;
    }
    const CGPoint portraitCenter = CGPointMake(
        CGRectGetMidX(frame), CGRectGetMidY(frame));
    // LandscapeRight turned the root +90 degrees; LandscapeLeft -90.
    const bool landscapeLeft =
        self.interfaceOrientation == UIInterfaceOrientationLandscapeLeft;
    const CGPoint center = landscapeLeft
        ? CGPointMake(longEdge - portraitCenter.y, portraitCenter.x)
        : CGPointMake(portraitCenter.y, shortEdge - portraitCenter.x);
    _guestRootLayout = CGRectMake(center.x, center.y,
                                  frame.size.height, frame.size.width);
    const CGRect bounds = LC32NativeViewBounds(contentView);
    LC32NativeSetViewBounds(contentView, CGRectMake(
        bounds.origin.x, bounds.origin.y,
        _guestRootLayout.size.width, _guestRootLayout.size.height));
    LC32NativeSetViewCenter(contentView, center);
    return YES;
}

- (BOOL)isGuestContentView:(UIView *)view {
    return view && view == _guestContentView;
}

- (void)fitGuestCanvasSiblings {
    /* A movie root covers the game's renderer while it plays; that renderer
     * goes back to the rootless window fit afterwards and must keep its
     * untransformed portrait drawable for it (9mm). */
    if(_geometryMode ==
            LC32LegacyIPadGeometryModePreservePhoneLandscapeCanvas &&
            _canvasView &&
            !LC32ControllerIsMoviePlayer(_guestContentController)) {
        LC32FitLegacyCanvasSiblingViews(self.view, _canvasView);
    }
}

/* Games without a root controller took their controller's view off the
 * window and later added it back (Alien Space Retro, around each level).
 * That view is now this container's child, which UIKit refuses to move to
 * the window: put it back into the canvas instead. */
- (BOOL)restoreGuestContentView:(UIView *)view {
    UIView *canvasView = _canvasView;
    if(!view || view != _guestContentView || !canvasView) return NO;
    if(LC32NativeViewSuperview(view) == canvasView) {
        [canvasView bringSubviewToFront:view];
        return YES;
    }
    [canvasView addSubview:view];
    [self fitGuestContentForViewport:self.view.bounds
        hostOrientation:UIInterfaceOrientationUnknown];
    [self scheduleGuestLayout];
    return YES;
}

- (void)scheduleGuestLayout {
    UIView *contentView = _guestContentView;
    if(!contentView || _guestLayoutPending) return;

    _guestLayoutPending = YES;
    const NSUInteger generation = _guestContentGeneration;
    LC32NativeSetViewNeedsLayout(contentView);
    dispatch_async(dispatch_get_main_queue(), ^{
        if(generation != _guestContentGeneration ||
                contentView != _guestContentView) {
            return;
        }
        _guestLayoutPending = NO;
        LC32NativeSetViewNeedsLayout(contentView);
        /* layoutIfNeeded can reach a guest EAGLView.layoutSubviews. Only force
         * it while the native main pthread owns a registered guest context;
         * otherwise leave the invalidation for UIKit's next safe transaction. */
        if(Dynarmic_guest_thread_is_registered()) {
            LC32NativeLayoutViewIfNeeded(contentView);
        }
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self fitGuestContentForViewport:self.view.bounds
        hostOrientation:UIInterfaceOrientationUnknown];
    [self announceLandscapeSideChange];
}

/* UIKit turns this native root between the landscape sides without any
 * transition callback, and the window-level legacy callbacks that told the
 * guest never run. Games that flip their own GL view from
 * willRotateToInterfaceOrientation: (Alien Space Retro) need to hear it. */
- (void)announceLandscapeSideChange {
    if(!LC32NativeLegacyRotationEnabled()) return;
    UIWindowScene *scene = self.viewIfLoaded.window.windowScene;
    /* A 180-degree turn keeps the root's size, so layout alone does not
     * reliably follow it; the scene geometry does. */
    if(scene && scene != _observedScene) {
        [_observedScene removeObserver:self forKeyPath:@"effectiveGeometry"];
        [scene addObserver:self forKeyPath:@"effectiveGeometry"
                   options:0 context:nullptr];
#if __has_feature(objc_arc)
        _observedScene = scene;
#else
        [_observedScene release];
        _observedScene = [scene retain];
#endif
    }
    const UIInterfaceOrientation side = scene.interfaceOrientation;
    if(!UIInterfaceOrientationIsLandscape(side)) return;
    const UIInterfaceOrientation previous = _layoutLandscapeSide;
    _layoutLandscapeSide = side;
    if(!UIInterfaceOrientationIsLandscape(previous) || previous == side) return;
    LC32NativeLegacyRotationWillRotate(self, side, 0);
    LC32NativeLegacyRotationDidRotate(self, previous);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if(object != _observedScene) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change
                              context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self announceLandscapeSideChange];
    });
}

- (void)dealloc {
    [_observedScene removeObserver:self forKeyPath:@"effectiveGeometry"];
#if !__has_feature(objc_arc)
    [_observedScene release];
    [super dealloc];
#endif
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if(LC32WindowIsPortraitHosted(LC32NativeViewWindow(self.viewIfLoaded))) {
        return UIInterfaceOrientationMaskPortrait;
    }
    /* UIKit can ask during a scene callback with no active guest JIT frame.
     * The root-install path already cached the guest policy when it was safe;
     * never enter guest code from this native container callback. */
    return LC32CachedGuestOrientationMask(_guestContentController);
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    const UIInterfaceOrientationMask mask =
        [self supportedInterfaceOrientations];
    const UIInterfaceOrientation target =
        LC32LegacyTargetOrientation(_guestContentController);
    return LC32MaskForInterfaceOrientation(target) & mask
        ? target : LC32FirstOrientationInMask(mask);
}

- (BOOL)prefersStatusBarHidden {
    return LC32GuestInterfacePolicy().statusBarHidden;
}

- (BOOL)shouldAutomaticallyForwardRotationMethods {
    /* LegacyRotation forwards to the guest through its guarded, FP-aware
     * callback path. Automatic forwarding would deliver the lifecycle twice. */
    return NO;
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:
        (id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size
         withTransitionCoordinator:coordinator];
    UIInterfaceOrientation targetOrientation =
        LC32LegacyTargetOrientation(_guestContentController);
    CGRect targetViewport = self.view.bounds;
    UIWindow *window = self.view.window;
    if(window.windowScene) {
        targetViewport = LC32LegacyViewportInView(window, self.view);
    }
    if(!window.windowScene ||
            !LC32UsesClassicFullScreenViewport(window)) {
        targetViewport.size = size;
    }
    [self fitGuestContentForViewport:targetViewport
        hostOrientation:targetOrientation];
    void (^refitActualBounds)(void) = ^{
        [self fitGuestContentForViewport:self.view.bounds
            hostOrientation:UIInterfaceOrientationUnknown];
    };
    BOOL scheduled = NO;
    if(coordinator) {
        scheduled = [coordinator animateAlongsideTransition:nil completion:
            ^(__unused id<UIViewControllerTransitionCoordinatorContext>
              context) {
                refitActualBounds();
            }];
    }
    if(!scheduled) {
        dispatch_async(dispatch_get_main_queue(), refitActualBounds);
    }
}

@end

extern "C" void LC32UIKitPrepareGuestClass(Class cls) {
    if(!cls || !LC32ClassIsUIViewController(cls)) return;

    /* Preserve native and inherited -loadView implementations. A synthesized
     * class's own void trampoline is the only method which needs the legacy
     * reentrancy guard; method_setImplementation retains its guest encoding.
     * Keep this bridge guard even when legacy UIKit adaptation is disabled:
     * it only intercepts recursive guest -view reads while -loadView is active,
     * without changing geometry, hierarchy, or orientation policy. */
    Method guestLoadView = LC32ClassOwnMethod(cls, @selector(loadView));
    if(guestLoadView && method_getImplementation(guestLoadView) ==
            (IMP)&LC32InvokeGuestSelector) {
        method_setImplementation(
            guestLoadView, (IMP)&LC32GuestLoadView);
    }

    // Duration needs the ARM32 FP ABI even when UIKit policy is fully native.
    if(LC32NativeLegacyRotationEnabled() || !LC32_UIKIT_COMPATIBILITY) {
        Method guestWillRotate = LC32ClassOwnMethod(cls,
            @selector(willRotateToInterfaceOrientation:duration:));
        if(guestWillRotate && method_getImplementation(guestWillRotate) ==
                (IMP)&LC32InvokeGuestSelector) {
            method_setImplementation(guestWillRotate, (IMP)&LC32GuestWillRotate);
        }
    }
#if LC32_UIKIT_COMPATIBILITY
    if(LC32NativeLegacyRotationEnabled()) LC32PrepareNativeLegacyRotationClass(cls);
    if(!LC32UIKitLegacyCompatibilityEnabled()) return;

    auto addNativeAdapter = ^(SEL selector, IMP implementation) {
        Method declaration = class_getInstanceMethod(
            UIViewController.class, selector);
        if(!declaration) return false;
        return class_addMethod(cls, selector, implementation,
                               method_getTypeEncoding(declaration));
    };

    const bool hasLegacyRotation =
        LC32GuestClassHierarchyDefinesSelector(
            cls, @selector(shouldAutorotateToInterfaceOrientation:));

    /* Guest implementations of the modern methods are ordinary JIT-backed
     * trampolines. Wrap class-owned methods so native UIKit callbacks can use
     * a cached result without entering ARM32 code, and so the application-wide
     * Info.plist policy remains the outer constraint. Keep the original IMPs
     * for guest-thread queries made from LC32ApplyLegacyWindowPolicy. */
    Method guestSupportedOrientations = LC32ClassOwnMethod(
        cls, @selector(supportedInterfaceOrientations));
    if(guestSupportedOrientations && method_getImplementation(
            guestSupportedOrientations) !=
            (IMP)&LC32GuestSupportedInterfaceOrientations) {
        objc_setAssociatedObject((id)cls,
            LC32GuestSupportedOrientationsIMPKey,
            @(reinterpret_cast<uintptr_t>(method_getImplementation(
                guestSupportedOrientations))),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        method_setImplementation(guestSupportedOrientations,
            (IMP)&LC32GuestSupportedInterfaceOrientations);
    }

    Method guestPreferredOrientation = LC32ClassOwnMethod(
        cls, @selector(preferredInterfaceOrientationForPresentation));
    if(guestPreferredOrientation && method_getImplementation(
            guestPreferredOrientation) !=
            (IMP)&LC32GuestPreferredInterfaceOrientation) {
        objc_setAssociatedObject((id)cls,
            LC32GuestPreferredOrientationIMPKey,
            @(reinterpret_cast<uintptr_t>(method_getImplementation(
                guestPreferredOrientation))),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        method_setImplementation(guestPreferredOrientation,
            (IMP)&LC32GuestPreferredInterfaceOrientation);
    }

    if(hasLegacyRotation) {
        addNativeAdapter(@selector(supportedInterfaceOrientations),
            (IMP)&LC32LegacySupportedInterfaceOrientations);
        addNativeAdapter(
            @selector(preferredInterfaceOrientationForPresentation),
            (IMP)&LC32LegacyPreferredInterfaceOrientation);
    }

    /* UIStatusBarHidden and pre-iOS-7 UIApplication status-bar calls are no
     * longer consulted by modern UIKit. A guest implementation of the modern
     * method wins because class_addMethod leaves an existing method intact. */
    addNativeAdapter(@selector(prefersStatusBarHidden),
        (IMP)&LC32LegacyPrefersStatusBarHidden);
#endif
}

/* SVC 1002 forwards the first guest argument in r2, followed by r3 and the
 * guest stack pointer. Keep this exported entry point in that three-word
 * shape even though the UIKit adapter only needs the orientation. */
extern "C" u32 LC32UIKitHandleLegacyStatusBarOrientation(
        u32 orientationValue, u32, u32) {
    if(!LC32UIKitLegacyCompatibilityEnabled()) return 0;
    const UIInterfaceOrientation orientation =
        (UIInterfaceOrientation)orientationValue;
    if(!LC32MaskForInterfaceOrientation(orientation)) return 0;
    LC32LegacyRequestedOrientation.store(
        orientation, std::memory_order_relaxed);
    /* Early game engines can keep the native main thread inside their guest
     * loop indefinitely. Refit synchronously while this legacy setter is
     * already executing on that thread; queuing the only refit would leave
     * the old portrait placement in force forever. Scaling itself does not
     * enter guest code. */
    if(pthread_main_np()) {
        UIApplication *application = UIApplication.sharedApplication;
        UIWindow *keyWindow = application.keyWindow;
        if(keyWindow) LC32ScaleLegacyIPadWindow(keyWindow);
        for(UIScene *scene in application.connectedScenes) {
            if(![scene isKindOfClass:UIWindowScene.class]) continue;
            for(UIWindow *window in ((UIWindowScene *)scene).windows) {
                if(window != keyWindow) LC32ScaleLegacyIPadWindow(window);
            }
        }
    }

    /* Avoid entering guest shouldAutorotate... while its outgoing direct
     * UIKit host call is still on the JIT stack. */
    dispatch_async(dispatch_get_main_queue(), ^{
        LC32AdoptLegacyRootViewControllers();
    });
    return 0;
}

extern "C" u32 LC32UIKitGetLegacyControllerOrientation(
        u32 low, u32 high, u32) {
    if(!LC32UIKitLegacyCompatibilityEnabled())
        return UIInterfaceOrientationUnknown;
    if(!pthread_main_np() || LC32GetGuestExecutableSDKVersion() >= 0x80000)
        return UIInterfaceOrientationUnknown;
    /* Those canvases already have a distinct logical orientation contract;
     * leave their existing controller getters unchanged. */
    if(LC32GuestUsesFixedLandscapePhoneCanvas() ||
            LC32GuestNeedsLegacyIPadCanvas())
        return UIInterfaceOrientationUnknown;
    UIViewController *controller = reinterpret_cast<UIViewController *>(
        static_cast<uintptr_t>(low | (static_cast<u64>(high) << 32)));
    if(![controller isKindOfClass:UIViewController.class])
        return UIInterfaceOrientationUnknown;

    using ControllerGetter = UIViewController *(*)(id, SEL);
    static ControllerGetter parentGetter = reinterpret_cast<ControllerGetter>(
        class_getMethodImplementation(UIViewController.class,
            @selector(parentViewController)));
    if(parentGetter(controller, @selector(parentViewController)))
        return UIInterfaceOrientationUnknown;
    static ControllerGetter presentingGetter =
        reinterpret_cast<ControllerGetter>(class_getMethodImplementation(
            UIViewController.class, @selector(presentingViewController)));
    if(presentingGetter(controller, @selector(presentingViewController)))
        return UIInterfaceOrientationUnknown;

    NSNumber *cached = objc_getAssociatedObject(
        controller, LC32LegacyOrientationMaskKey);
    const UIInterfaceOrientationMask mask = cached
        ? (UIInterfaceOrientationMask)cached.unsignedLongLongValue
        : LC32GuestInterfacePolicy().declaredOrientations;
    UIView *view = nil;
    LC32NativeViewIfLoaded(controller, &view);
    using WindowGetter = UIWindow *(*)(id, SEL);
    static WindowGetter windowGetter = reinterpret_cast<WindowGetter>(
        class_getMethodImplementation(UIView.class, @selector(window)));
    UIWindow *window = view ? windowGetter(view, @selector(window)) : nil;
    if(window) {
        if(!window.guest_selfOrNull)
            return UIInterfaceOrientationUnknown;
        if(LC32NativeWindowRootViewController(window) == controller) {
            using OrientationGetter = UIInterfaceOrientation (*)(id, SEL);
            static OrientationGetter orientationGetter =
                reinterpret_cast<OrientationGetter>(class_getMethodImplementation(
                    UIViewController.class, @selector(interfaceOrientation)));
            const UIInterfaceOrientation native = orientationGetter(
                controller, @selector(interfaceOrientation));
            /* Preserve an allowed native orientation, including an ongoing
             * transition. Old UIKit only applied its preferred/mask fallback
             * when the root's cached orientation was no longer supported. */
            if(LC32MaskForInterfaceOrientation(native) & mask)
                return UIInterfaceOrientationUnknown;
        } else {
            using ViewGetter = UIView *(*)(id, SEL);
            static ViewGetter superviewGetter = reinterpret_cast<ViewGetter>(
                class_getMethodImplementation(UIView.class, @selector(superview)));
            if(superviewGetter(view, @selector(superview)) != window)
                return UIInterfaceOrientationUnknown;
        }
    }

    /* iOS 10's _legacyInterfaceOrientation falls back to the application
     * orientation when a controller is not its window's root yet, including
     * when its view has already been added directly to that window. It also
     * corrects an attached root's stale orientation against its allowed mask.
     * Modern UIKit can instead report portrait during a landscape launch.
     * Do not load the view or invoke engine-owned orientation callbacks here. */
    const UIInterfaceOrientation current =
        UIApplication.sharedApplication.statusBarOrientation;
    return (LC32MaskForInterfaceOrientation(current) & mask)
        ? (u32)current : (u32)UIInterfaceOrientationUnknown;
}

/* See LC32DecidePortraitHostedLandscape; read by the guest-only
 * -[UIApplication statusBarOrientation] hook in GuestSelectorHooks.mm. */
extern "C" NSInteger LC32UIKitPortraitHostedStatusBarOrientation(void) {
    return LC32PortraitHostedLandscape == LC32PortraitHostState::Hosted
        ? LC32PortraitHostedLandscapeSide() : 0;
}

/* LegacyRotation.mm: only this window's hosted turns are announced. */
extern "C" bool LC32UIKitWindowIsPortraitHosted(UIWindow *window) {
    return LC32WindowIsPortraitHosted(window);
}

/* Read by the guest-only -[UIApplication setStatusBarOrientation:] hooks in
 * GuestSelectorHooks.mm. Before iOS 6 that setter turned only the status bar
 * (and alerts/keyboard); a window without a root controller never rotated.
 * Under UIKit's native legacy mode the same call asks the scene for that
 * interface orientation, and FrontBoard grants it once the device turns that
 * way: H.A.W.X. (portrait-only, rootless EAGL window, flips its own picture
 * from UIDevice.orientation) requests LandscapeRight at launch, so holding
 * the phone island-left turned the scene under the portrait canvas. Keep the
 * request guest-visible only for portrait-only, rootless pre-iOS-6 guests. */
extern "C" bool LC32UIKitGuestStatusBarOrientationIsCosmetic(
        UIWindow *guestKeyWindow) {
    const uint32_t sdk = LC32GetGuestExecutableSDKVersion();
    if(sdk >= 0x80000) return false;
    const UIInterfaceOrientationMask declared =
        LC32GuestInterfacePolicy().declaredOrientations;
    if(!declared) return false;
    if(LC32PortraitHostedLandscape == LC32PortraitHostState::Hosted)
        return false;
    if(sdk < 0x60000) {
        if(declared & UIInterfaceOrientationMaskLandscape) return false;
        return !guestKeyWindow ||
            !LC32NativeWindowRootViewController(guestKeyWindow);
    }
    /* iOS 6/7 rotated only through a window's root controller; a rootless
     * window stayed portrait whatever the status bar or Info.plist said.
     * Modern Combat 4 (SDK 7.1, declares portrait + both landscape sides,
     * launches LandscapeRight) draws its GL picture and turns its intro
     * movie inside that portrait window itself, so a scene that turned
     * landscape showed it sideways and clipped to one end. Landscape-only
     * declarations keep the turned-window path
     * (LC32ClassifyFullScreenRootlessWindow). */
    if(!(declared & UIInterfaceOrientationMaskPortrait) ||
            UIDevice.currentDevice.userInterfaceIdiom !=
                UIUserInterfaceIdiomPhone ||
            LC32GuestNeedsLegacyIPadCanvas())
        return false;
    /* Our synthetic root (fixed 320x568 canvas) does not make the guest
     * window rotate; the guest still draws in its portrait window. */
    if(!guestKeyWindow) return false;
    UIViewController *root = LC32NativeWindowRootViewController(guestKeyWindow);
    return !root || [root isKindOfClass:LC32LegacyWindowRootController.class];
}

/* A rootless landscape game on the fixed phone canvas that supports both
 * landscape sides flips its own picture when the phone turns, and tells
 * UIApplication with setStatusBarOrientation:. iOS 7 then reported that side
 * from statusBarOrientation; a scene app's setter does nothing and the getter
 * kept the launch side here, so 9mm (EAGLView ConvertCoordP: converts touches
 * by statusBarOrientation) drew for the new side but mapped touches for the
 * old one. The status-bar hooks report the side the game set while this
 * holds; the window itself follows the scene (LC32FitLegacyDirectWindowLayers). */
static bool LC32RootlessGuestSetsStatusBarSide(UIWindow *guestKeyWindow) {
    const uint32_t sdk = LC32GetGuestExecutableSDKVersion();
    if(sdk < 0x60000 || sdk >= 0x80000 ||
            !LC32NativeLegacyRotationEnabled()) return false;
    const UIInterfaceOrientationMask declared =
        LC32GuestInterfacePolicy().declaredOrientations;
    if((declared & UIInterfaceOrientationMaskLandscape) !=
            UIInterfaceOrientationMaskLandscape ||
            (declared & (UIInterfaceOrientationMaskPortrait |
                         UIInterfaceOrientationMaskPortraitUpsideDown)))
        return false;
    return LC32WindowUsesRootlessPhoneCanvas(guestKeyWindow);
}

extern "C" bool LC32UIKitRootlessStatusBarOrientationFollowsGuest(
        UIWindow *guestKeyWindow) {
    return LC32PortraitHostedLandscape != LC32PortraitHostState::Hosted &&
        LC32RootlessGuestSetsStatusBarSide(guestKeyWindow);
}

/* The same game launched upright (portrait-hosted): the scene and window stay
 * portrait and the game turns its own sideways picture, so the side it sets
 * becomes the hosted side (status bar, UIDevice readings, hosted movies). */
extern "C" bool LC32UIKitHostedStatusBarOrientationFollowsGuest(
        UIWindow *guestKeyWindow) {
    return LC32PortraitHostedLandscape == LC32PortraitHostState::Hosted &&
        LC32RootlessGuestSetsStatusBarSide(guestKeyWindow);
}

/* Read by the guest -[UIDevice orientation] hook. Modern Combat 4 flips its
 * GL picture and movies by UIDevice.orientation inside a window that iOS 6/7
 * never rotated. On the fixed 568-point canvas the window itself is turned
 * to whichever landscape side the scene takes, so a game that also follows
 * the device would show upside down on one side. Report its launch side. */
extern "C" bool LC32UIKitGuestFixedCanvasDeviceOrientation(
        UIDeviceOrientation *orientation) {
    if(LC32GetGuestExecutableSDKVersion() < 0x60000 ||
            LC32GetGuestExecutableSDKVersion() >= 0x80000 ||
            !LC32GuestUsesFixedLandscapePhoneCanvas() ||
            !LC32NativeLegacyRotationEnabled()) return false;
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    if(!(policy.declaredOrientations & UIInterfaceOrientationMaskPortrait))
        return false;
    // Interface LandscapeRight (3) is device LandscapeLeft (3), and 4 is 4.
    const UIInterfaceOrientation side =
        UIInterfaceOrientationIsLandscape(policy.preferredOrientation)
            ? policy.preferredOrientation
            : UIInterfaceOrientationLandscapeRight;
    if(orientation) *orientation = (UIDeviceOrientation)side;
    return true;
}

extern "C" u32 LC32UIKitGetLegacyStatusBarOrientation(void) {
    if(!LC32UIKitLegacyCompatibilityEnabled())
        return (u32)UIInterfaceOrientationUnknown;
    const LC32GuestUIKitPolicy &policy = LC32GuestInterfacePolicy();
    if(LC32GuestUsesFixedLandscapePhoneCanvas()) {
        /* Keep the guest's projection orientation paired with the native
         * wrapper that turns its fixed portrait canvas into landscape. */
        return (u32)LC32LegacyTargetOrientation(nil);
    }

    if(!LC32GuestNeedsLegacyIPadCanvas()) {
        /* Ordinary phone applications should retain the generated shim's
         * direct UIApplication forwarding behavior. In particular, apps
         * supporting both landscape sides must not observe our pre-scene
         * fallback and then a different settled scene orientation. */
        return (u32)UIInterfaceOrientationUnknown;
    }

    UIApplication *application = UIApplication.sharedApplication;
    UIInterfaceOrientation current = UIInterfaceOrientationUnknown;
    bool foundKeyWindow = false;
    for(UIScene *scene in application.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        const UIInterfaceOrientation candidate =
            windowScene.interfaceOrientation;
        if(!LC32MaskForInterfaceOrientation(candidate)) continue;
        if(!LC32MaskForInterfaceOrientation(current)) current = candidate;
        for(UIWindow *window in windowScene.windows) {
            if(!window.isKeyWindow) continue;
            current = candidate;
            foundKeyWindow = true;
            break;
        }
        if(foundKeyWindow) break;
    }

    const UIInterfaceOrientationMask currentMask =
        LC32MaskForInterfaceOrientation(current);
    if(currentMask & policy.declaredOrientations) return (u32)current;

    const UIInterfaceOrientation requested = (UIInterfaceOrientation)
        LC32LegacyRequestedOrientation.load(std::memory_order_relaxed);
    if(LC32MaskForInterfaceOrientation(requested) &
            policy.declaredOrientations) {
        return (u32)requested;
    }
    if(LC32MaskForInterfaceOrientation(policy.preferredOrientation) &
            policy.declaredOrientations) {
        return (u32)policy.preferredOrientation;
    }
    return (u32)LC32FirstOrientationInMask(policy.declaredOrientations);
}

#if LC32_UIKIT_COMPATIBILITY
/* Non-zero while UIApplication loads NSMainNibFile. A "visible at launch"
 * window in that nib calls makeKeyAndVisible before the delegate's launch
 * method has run. */
static int LC32MainInterfaceLoadDepth;
static void (*LC32OriginalLoadMainInterfaceFile)(id, SEL);

static void LC32LoadMainInterfaceFile(id self, SEL _cmd) {
    LC32MainInterfaceLoadDepth++;
    LC32OriginalLoadMainInterfaceFile(self, _cmd);
    LC32MainInterfaceLoadDepth--;
}

/* -[UIViewController loadView] sizes a nib-archived view through
 * autoresizeArchivedView -> _defaultInitialViewFrame. iOS 3/4 answered with
 * the 320x480 screen's application frame; modern UIKit answers with the
 * native screen. Dungeon Raid's MainViewController EAGLView then came out
 * 393x852 inside the fixed portrait canvas, and its 320x480 GL viewport
 * (bottom-left of that drawable) landed below the screen. Give top-level
 * guest controllers the guest's own screen while that canvas is active. */
static CGRect (*LC32OriginalDefaultInitialViewFrame)(id, SEL);

static CGRect LC32DefaultInitialViewFrame(id self, SEL _cmd) {
    CGRect bounds, applicationFrame;
    if(LC32GuestUsesFixedPortraitPhoneCanvas() &&
            LC32ObjectUsesGuestClass(self) &&
            !((UIViewController *)self).parentViewController &&
            LC32UIKitFixedLandscapePhoneScreen(&bounds, &applicationFrame)) {
        const SEL fullScreen = NSSelectorFromString(@"wantsFullScreenLayout");
        const bool wantsFullScreen = [self respondsToSelector:fullScreen] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(self, fullScreen);
        return wantsFullScreen ? bounds : applicationFrame;
    }
    return LC32OriginalDefaultInitialViewFrame(self, _cmd);
}

@interface UIWindow (LC32LegacyRootViewController)
- (void)lc32_makeKeyAndVisible;
+ (void)lc32_applicationDidBecomeActive:(NSNotification *)notification;
@end

/* Games add loading/overlay views straight to the window at any time
 * (Zenonia 5's LoadingView); fit them to a landscape canvas as they arrive. */
static void LC32WindowDidAddSubview(id self, SEL _cmd, UIView *subview) {
    struct objc_super superInfo = {self, UIView.class};
    ((void (*)(struct objc_super *, SEL, UIView *))objc_msgSendSuper)(
        &superInfo, _cmd, subview);
    UIWindow *window = (UIWindow *)self;
    if(!window.guest_selfOrNull ||
            !LC32GuestUsesFixedLandscapePhoneCanvas()) return;
    LC32LegacyIPadContainerController *container =
        LC32LegacyContainerForWindow(window);
    if(!container || subview == container.viewIfLoaded) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [container fitGuestCanvasSiblings];
    });
}

/* A guest frame on the canvas root is in the old portrait window's
 * coordinates; see -[LC32LegacyIPadContainerController applyGuestRootFrame:]. */
static void (*LC32OriginalViewSetFrame)(id, SEL, CGRect);

static void LC32ViewSetFrame(id self, SEL _cmd, CGRect frame) {
    UIView *view = (UIView *)self;
    if(frame.size.height > frame.size.width &&
            [LC32NativeViewSuperview(view)
                isKindOfClass:LC32LegacyCanvasWrapperView.class]) {
        LC32LegacyIPadContainerController *container =
            LC32LegacyContainerForWindow(LC32NativeViewWindow(view));
        if([container isGuestContentView:view] &&
                [container applyGuestRootFrame:frame]) {
            return;
        }
    }
    LC32OriginalViewSetFrame(self, _cmd, frame);
}

static void (*LC32OriginalWindowAddSubview)(id, SEL, UIView *);

static void LC32WindowAddSubview(id self, SEL _cmd, UIView *subview) {
    UIWindow *window = (UIWindow *)self;
    LC32LegacyIPadContainerController *container =
        window.guest_selfOrNull && LC32GuestUsesFixedLandscapePhoneCanvas()
            ? LC32LegacyContainerForWindow(window) : nil;
    if([container restoreGuestContentView:subview]) return;
    LC32OriginalWindowAddSubview(self, _cmd, subview);
}

/* Tapsonic builds its gameplay EAGLView with -initWithCoder:nil. Old UIKit
 * decoded only the keys present, so a nil coder gave a default view. Modern
 * -[UIView initWithCoder:] applies a "decoded" all-zero transform, which
 * collapses the view to nothing (black screen). Treat a nil coder like
 * -initWithFrame:CGRectZero, using UIView's own initializer so a subclass
 * initWithFrame: override does not run twice. */
static id (*LC32OriginalViewInitWithCoder)(id, SEL, NSCoder *);

static id LC32ViewInitWithCoder(id self, SEL _cmd, NSCoder *coder) {
    if(coder) return LC32OriginalViewInitWithCoder(self, _cmd, coder);
    using InitWithFrame = id (*)(id, SEL, CGRect);
    static InitWithFrame initWithFrame = reinterpret_cast<InitWithFrame>(
        method_getImplementation(class_getInstanceMethod(
            UIView.class, @selector(initWithFrame:))));
    return initWithFrame(self, @selector(initWithFrame:), CGRectZero);
}

@interface UIView (LC32NilCoder)
@end

@implementation UIView (LC32NilCoder)
+ (void)load {
    Method method = class_getInstanceMethod(UIView.class,
                                            @selector(initWithCoder:));
    if(method) {
        LC32OriginalViewInitWithCoder = (id (*)(id, SEL, NSCoder *))
            method_setImplementation(method, (IMP)LC32ViewInitWithCoder);
    }
}
@end

@implementation UIWindow (LC32LegacyRootViewController)

+ (void)load {
    if(!LC32UIKitLegacyCompatibilityEnabled() &&
            !LC32NativeLegacyRotationEnabled()) return;
    class_addMethod(self, @selector(didAddSubview:),
        (IMP)LC32WindowDidAddSubview, "v@:@");
    LC32OriginalWindowAddSubview = (void (*)(id, SEL, UIView *))
        method_getImplementation(class_getInstanceMethod(
            self, @selector(addSubview:)));
    class_replaceMethod(self, @selector(addSubview:),
        (IMP)LC32WindowAddSubview, "v@:@");
    Method viewSetFrame = class_getInstanceMethod(UIView.class,
                                                  @selector(setFrame:));
    if(viewSetFrame) {
        LC32OriginalViewSetFrame = (void (*)(id, SEL, CGRect))
            method_setImplementation(viewSetFrame, (IMP)LC32ViewSetFrame);
    }
    Method original = class_getInstanceMethod(self,
                                               @selector(makeKeyAndVisible));
    Method compatibility = class_getInstanceMethod(
        self, @selector(lc32_makeKeyAndVisible));
    if(original && compatibility) {
        method_exchangeImplementations(original, compatibility);
    }
    Method loadMainInterface = class_getInstanceMethod(UIApplication.class,
        NSSelectorFromString(@"_loadMainInterfaceFile"));
    if(loadMainInterface) {
        LC32OriginalLoadMainInterfaceFile = (void (*)(id, SEL))
            method_setImplementation(loadMainInterface,
                                     (IMP)LC32LoadMainInterfaceFile);
    }
    Method defaultInitialViewFrame = class_getInstanceMethod(
        UIViewController.class,
        NSSelectorFromString(@"_defaultInitialViewFrame"));
    if(defaultInitialViewFrame) {
        LC32OriginalDefaultInitialViewFrame = (CGRect (*)(id, SEL))
            method_setImplementation(defaultInitialViewFrame,
                                     (IMP)LC32DefaultInitialViewFrame);
    }
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(lc32_applicationDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification
        object:nil];
}

+ (void)lc32_applicationDidBecomeActive:(NSNotification *)notification {
    if(!LC32UIKitLegacyCompatibilityEnabled() &&
            !LC32UIKitNativeFixedPhoneCanvasEnabled()) return;
    UIApplication *application =
        [notification.object isKindOfClass:UIApplication.class]
            ? (UIApplication *)notification.object
            : UIApplication.sharedApplication;
    dispatch_async(dispatch_get_main_queue(), ^{
        LC32AdoptLegacyPhoneCanvases(application);
    });
}

- (void)lc32_makeKeyAndVisible {
    LC32LogFullScreenRootlessState(self, "makeKey");
    for(double delay : {1.0, 4.0, 10.0}) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LC32LogFullScreenRootlessState(self, "settled");
        });
    }
    if(!LC32UIKitLegacyCompatibilityEnabled() &&
            !LC32UIKitLegacyIPadCanvasEnabled() &&
            !LC32UIKitNativeFixedPhoneCanvasEnabled()) {
        [self lc32_makeKeyAndVisible];
        if(LC32GuestUsesFixedPortraitPhoneCanvas()) {
            LC32FitPortraitPhoneCanvasWindow(self);
            LC32WatchPortraitPhoneCanvasWindow(self);
            /* The renderer and root view may be added or resized after
             * this call; UIKit can also re-size a rooted window once. */
            for(double delay : {0.0, 0.5, 2.0}) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(delay * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        LC32FitPortraitPhoneCanvasWindow(self);
                        LC32RotatePortraitPhoneCanvasController(self);
                    });
            }
            return;
        }
        LC32WatchFullScreenRootlessWindow(self);
        // The renderer's view may be added right after this call.
        dispatch_async(dispatch_get_main_queue(), ^{
            LC32FitFullScreenRootlessWindow(self);
        });
        return;
    }
    /* Installing a native root lays the window out synchronously
     * (window:setupWithInterfaceOrientation: -> layoutIfNeeded). iOS 3/4
     * laid out a main-nib window only after the launch delegate returned,
     * and games such as Star Battalion render from -layoutSubviews using
     * state created in that delegate. The DidFinishLaunching observer adopts
     * the root instead. */
    if(!LC32MainInterfaceLoadDepth)
        LC32AdoptLegacyRootViewController(self);
    [self lc32_makeKeyAndVisible];
    /* UIWindowScene geometry is authoritative only after makeKeyAndVisible.
     * Refit the virtual child canvas against that settled viewport without
     * changing guest-visible UIWindow bounds. */
    LC32ApplyLegacyWindowPolicy(self);
    LC32ScaleLegacyIPadWindow(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        LC32ScaleLegacyIPadWindow(self);
    });
}

@end

#endif // LC32_UIKIT_COMPATIBILITY

/*
 * Sentinel returned to the guest UIApplicationMain shim when the host run
 * loop was interrupted by a guest-debugger all-stop. The guest shim loops
 * back and re-enters this function, which then drives the run loop directly
 * (the app object and delegate already exist). Keep the value in sync with
 * GuestFrameworks/UIKit/UIKit.m.
 */
static const int LC32UIKITRunLoopDebuggerStop = 0x1C32DEAD;

/*
 * The guest debugger can request an all-stop (worker crash, ^C, breakpoint)
 * while the guest main thread is parked inside the host UIApplicationMain run
 * loop. That blocking mach_msg lives in CoreFoundation and is not tracked by
 * the coordinator's debuggerMachCalls, so it cannot be aborted like a guest
 * SVC wait. GSEventRunModal(0) also loops forever, so CFRunLoopStop alone
 * cannot make UIApplicationMain return. Instead the notifier below wakes the
 * main run loop and its armed block unwinds the run loop via a caught
 * Objective-C exception, returning control to the guest JIT so the stop
 * reply is delivered. Once the debugger resumes, the guest shim re-enters
 * this function and LC32RunDebuggerAwareMainRunLoop drives the run loop
 * directly with a poll, avoiding any further unwinding.
 */
@interface LC32DebuggerStopException : NSException
@end
@implementation LC32DebuggerStopException
@end

/* Non-zero only while UIApplicationMain's own run loop is executing, so the
 * notifier block only unwinds (throws) inside the @try below. */
static bool LC32RunLoopExceptionArmed = false;

static void LC32DebuggerStopRunLoopBlock(void) {
    if((LC32DebuggerAllStopRequested() ||
            LC32DebuggerSessionUnwindRequested()) &&
            LC32RunLoopExceptionArmed) {
        @throw [LC32DebuggerStopException
            exceptionWithName:@"LC32DebuggerStopException"
                       reason:@"Guest debugger requested an all-stop"
                     userInfo:nil];
    }
}

static void LC32DebuggerStopRunLoopNotify(void) {
                        /* A rootless canvas window (Modern Conflict's
                         * OpenKODE EAGL window) draws its landscape picture
                         * into the portrait canvas itself. Keep the scene
                         * portrait here: the startup-complete pass that
                         * installs the anchor for rootless windows never
                         * runs for games whose frame loop pumps a nested run
                         * loop from a timer, so the scene turned with an
                         * unlocked phone and showed the canvas sideways. */
                        if(self.isKeyWindow)
                            LC32RestoreLegacyPortraitScene(self);
    CFRunLoopRef runLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes, ^{
        LC32DebuggerStopRunLoopBlock();
    });
    CFRunLoopWakeUp(runLoop);
}

static int LC32RunDebuggerAwareMainRunLoop(void) {
    /* Re-entry after a debugger stop: the app object and delegate already
     * exist, so drive the run loop directly. The short timeout bounds stop
     * latency even if the wake-up is missed. */
    for(;;) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        if(LC32DebuggerAllStopRequested() ||
                LC32DebuggerSessionUnwindRequested()) {
            return LC32UIKITRunLoopDebuggerStop;
        }
    }
}

__BEGIN_DECLS

void LC32_UIKit_UIAccessibilityPostNotification(
        u32 notificationValue, u32 argumentLow, u32 sp) {
    const u32 argumentHigh =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp);
    id argument = reinterpret_cast<id>(static_cast<uintptr_t>(
        argumentLow | (static_cast<u64>(argumentHigh) << 32)));
    UIAccessibilityPostNotification(
        (UIAccessibilityNotifications)notificationValue, argument);
}

static float LC32UIKitFloatFromBits(u32 bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static id LC32UIKitObjectFromWords(u32 low, u32 high) {
    return reinterpret_cast<id>(static_cast<uintptr_t>(
        low | (static_cast<u64>(high) << 32)));
}

u32 LC32_UIKit_UIAccessibilityConvertFrameToScreenCoordinates(
        u32 guestResult, u32 xBits, u32 sp) {
    if(!guestResult || guestResult > UINT32_MAX - 15) return 0;

    const u32 yBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp);
    const u32 widthBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 4);
    const u32 heightBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 8);
    UIView *view = LC32UIKitObjectFromWords(
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 12),
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 16));
    if(!view) return 0;

    const CGRect result = UIAccessibilityConvertFrameToScreenCoordinates(
        CGRectMake(LC32UIKitFloatFromBits(xBits),
            LC32UIKitFloatFromBits(yBits),
            LC32UIKitFloatFromBits(widthBits),
            LC32UIKitFloatFromBits(heightBits)),
        view);
    const struct {
        float x;
        float y;
        float width;
        float height;
    } guestRect = {
        static_cast<float>(result.origin.x),
        static_cast<float>(result.origin.y),
        static_cast<float>(result.size.width),
        static_cast<float>(result.size.height),
    };
    return Dynarmic_mem_1write(guestResult, sizeof(guestRect),
        const_cast<char *>(reinterpret_cast<const char *>(&guestRect))) == 0;
}

u32 LC32_UIKit_UIAccessibilityConvertPathToScreenCoordinates(
        u32 pathLow, u32 pathHigh, u32 sp) {
    UIBezierPath *path = LC32UIKitObjectFromWords(pathLow, pathHigh);
    UIView *view = LC32UIKitObjectFromWords(
        Dynarmic_current_user_callbacks()->MemoryRead32(sp),
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 4));
    if(!path || !view) return 0;
    UIBezierPath *result =
        UIAccessibilityConvertPathToScreenCoordinates(path, view);
    return result ? result.guest_self : 0;
}

u32 LC32_UIKit_UIAccessibilityFocusedElement(
        u32 identifierLow, u32 identifierHigh, u32) {
    NSString *identifier =
        LC32UIKitObjectFromWords(identifierLow, identifierHigh);
    id element = UIAccessibilityFocusedElement(identifier);
    return element ? [element guest_self] : 0;
}

void LC32_UIKit_UIAccessibilityZoomFocusChanged(
        u32 type, u32 xBits, u32 sp) {
    const u32 yBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp);
    const u32 widthBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 4);
    const u32 heightBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 8);
    UIView *view = LC32UIKitObjectFromWords(
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 12),
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 16));
    if(!view) return;
    UIAccessibilityZoomFocusChanged((UIAccessibilityZoomType)type,
        CGRectMake(LC32UIKitFloatFromBits(xBits),
            LC32UIKitFloatFromBits(yBits),
            LC32UIKitFloatFromBits(widthBits),
            LC32UIKitFloatFromBits(heightBits)),
        view);
}

u32 LC32_UIKit_UIGuidedAccessRestrictionStateForIdentifier(
        u32 identifierLow, u32 identifierHigh, u32) {
    NSString *identifier =
        LC32UIKitObjectFromWords(identifierLow, identifierHigh);
    return identifier
        ? (u32)UIGuidedAccessRestrictionStateForIdentifier(identifier)
        : (u32)UIGuidedAccessRestrictionStateAllow;
}

u32 LC32_UIKit_UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(
        u32 pathLow, u32 pathHigh, u32) {
    NSString *path = LC32UIKitObjectFromWords(pathLow, pathHigh);
    return path && UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path);
}

int LC32_UIKit_UIApplicationMain(u32 r2, u32 r3, u32 sp) {
    static bool firstEntry = true;
    if(!firstEntry) {
        return LC32RunDebuggerAwareMainRunLoop();
    }
    firstEntry = false;
#if LC32_UIKIT_COMPATIBILITY
    if(LC32UIKitLegacyCompatibilityEnabled() || LC32NativeLegacyRotationEnabled()) {
        LC32GuestOrientationStartupCallbackDepth = LC32GuestCallbackDepth();
        LC32GuestOrientationStartupComplete.store(false, std::memory_order_release);
    }
#endif

    int argc = r2;
    u32 guest_argv = r3;
    NSString *principalClassName = (id)Dynarmic_current_user_callbacks()->MemoryRead64(sp);
    NSString *delegateClassName = (id)Dynarmic_current_user_callbacks()->MemoryRead64(sp += 8);

    NSLog(@"UIApplicationMain(%d, 0x%x, %@, %@)\n", argc, guest_argv, principalClassName, delegateClassName);
#if LC32_UIKIT_COMPATIBILITY
    static id launchObserver;
    if(LC32UIKitLegacyCompatibilityEnabled() || LC32NativeLegacyRotationEnabled()) {
        launchObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            if(LC32UIKitLegacyCompatibilityEnabled() ||
                    LC32UIKitLegacyIPadCanvasEnabled() ||
                    LC32UIKitNativeFixedPhoneCanvasEnabled())
                LC32AdoptLegacyRootViewControllers();
            LC32FinishGuestOrientationStartupAfterLaunch();
        }];
    }
    (void)launchObserver;
#endif
    char executableName[] = "exec";
    char *host_argv[] = {executableName, nullptr};

    if(!LC32DebuggerActive()) {
        return UIApplicationMain(
            argc, host_argv, principalClassName, delegateClassName);
    }

    LC32SetDebuggerStopRunLoopNotifier(
        LC32DebuggerStopRunLoopNotify);
    LC32RunLoopExceptionArmed = true;
    int result;
    @try {
        result = UIApplicationMain(
            argc, host_argv, principalClassName, delegateClassName);
    } @catch(LC32DebuggerStopException *exception) {
        LC32RunLoopExceptionArmed = false;
        fprintf(stderr,
            "LC32: host run loop interrupted by guest debugger stop\n");
        fflush(stderr);
        return LC32UIKITRunLoopDebuggerStop;
    }
    LC32RunLoopExceptionArmed = false;
    fprintf(stderr,
        "LC32: host UIApplicationMain returned %d\n", result);
    fflush(stderr);
    return result;
}

u32 LC32_UIKit_NSStringFromCGSize(u32 widthBits, u32 heightBits, u32) {
    float width;
    float height;
    memcpy(&width, &widthBits, sizeof(width));
    memcpy(&height, &heightBits, sizeof(height));
    return NSStringFromCGSize(CGSizeMake(width, height)).guest_self;
}

u32 LC32_UIKit_NSStringFromCGPoint(u32 xBits, u32 yBits, u32) {
    float x;
    float y;
    memcpy(&x, &xBits, sizeof(x));
    memcpy(&y, &yBits, sizeof(y));
    return NSStringFromCGPoint(CGPointMake(x, y)).guest_self;
}

u32 LC32_UIKit_CGSizeFromString(u32 stringLow, u32 stringHigh, u32 sp) {
    NSString *string = reinterpret_cast<NSString *>(
        static_cast<uintptr_t>(stringLow |
            (static_cast<u64>(stringHigh) << 32)));
    const u32 guestResult =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp);
    if(!string || !guestResult || guestResult > UINT32_MAX - 7)
        return 0;

    const CGSize size = CGSizeFromString(string);
    const struct {
        float width;
        float height;
    } guestSize = {
        static_cast<float>(size.width),
        static_cast<float>(size.height),
    };
    return Dynarmic_mem_1write(guestResult, sizeof(guestSize),
        const_cast<char *>(reinterpret_cast<const char *>(&guestSize))) == 0;
}

u32 LC32_UIKit_CGRectFromString(u32 stringLow, u32 stringHigh, u32 sp) {
    NSString *string = reinterpret_cast<NSString *>(
        static_cast<uintptr_t>(stringLow |
            (static_cast<u64>(stringHigh) << 32)));
    const u32 guestResult =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp);
    if(!string || !guestResult || guestResult > UINT32_MAX - 15)
        return 0;

    const CGRect rect = CGRectFromString(string);
    const struct {
        float x;
        float y;
        float width;
        float height;
    } guestRect = {
        static_cast<float>(rect.origin.x),
        static_cast<float>(rect.origin.y),
        static_cast<float>(rect.size.width),
        static_cast<float>(rect.size.height),
    };
    return Dynarmic_mem_1write(guestResult, sizeof(guestRect),
        const_cast<char *>(reinterpret_cast<const char *>(&guestRect))) == 0;
}

void LC32_UIKit_UIGraphicsBeginImageContext(
        u32 widthBits, u32 heightBits, u32) {
    float width;
    float height;
    memcpy(&width, &widthBits, sizeof(width));
    memcpy(&height, &heightBits, sizeof(height));
    UIGraphicsBeginImageContext(CGSizeMake(width, height));
}

void LC32_UIKit_UIGraphicsBeginImageContextWithOptions(
        u32 widthBits, u32 heightBits, u32 sp) {
    float width;
    float height;
    float scale;
    memcpy(&width, &widthBits, sizeof(width));
    memcpy(&height, &heightBits, sizeof(height));
    const BOOL opaque = Dynarmic_current_user_callbacks()->MemoryRead32(sp);
    const u32 scaleBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + sizeof(u32));
    memcpy(&scale, &scaleBits, sizeof(scale));
    UIGraphicsBeginImageContextWithOptions(
        CGSizeMake(width, height), opaque, scale);
}

void LC32_UIKit_UIGraphicsEndImageContext(u32, u32, u32) {
    LC32CoreGraphicsReleaseHostedMirror(UIGraphicsGetCurrentContext());
    UIGraphicsEndImageContext();
}

void LC32_UIKit_UIGraphicsPushContext(
        u32 contextLow, u32 contextHigh, u32) {
    CGContextRef context = reinterpret_cast<CGContextRef>(
        static_cast<uintptr_t>(contextLow |
            (static_cast<u64>(contextHigh) << 32)));
    if(!context) return;
    LC32CoreGraphicsPrepareBitmapBacking(context);
    UIGraphicsPushContext(context);
}

void LC32_UIKit_UIGraphicsPopContext(u32, u32, u32) {
    LC32CoreGraphicsSyncBitmapBacking(UIGraphicsGetCurrentContext());
    UIGraphicsPopContext();
}

u32 LC32_UIKit_UIGraphicsGetCurrentContext(u32, u32, u32) {
    CGContextRef context = UIGraphicsGetCurrentContext();
    return context ? [(id)context guest_self] : 0;
}

u32 LC32_UIKit_UIGraphicsGetImageFromCurrentImageContext(u32, u32, u32) {
    LC32CoreGraphicsPrepareBitmapBacking(UIGraphicsGetCurrentContext());
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    return image ? image.guest_self : 0;
}

u32 LC32_UIKit_UIImageJPEGRepresentation(
        u32 imageLow, u32 imageHigh, u32 sp) {
    UIImage *image = reinterpret_cast<UIImage *>(static_cast<uintptr_t>(
        imageLow | (static_cast<u64>(imageHigh) << 32)));
    const u32 qualityBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp);
    float quality;
    memcpy(&quality, &qualityBits, sizeof(quality));
    NSData *data = image
        ? UIImageJPEGRepresentation(image, static_cast<CGFloat>(quality))
        : nil;
    return data ? data.guest_self : 0;
}

u32 LC32_UIKit_UIImagePNGRepresentation(u32 imageLow, u32 imageHigh, u32) {
    UIImage *image = reinterpret_cast<UIImage *>(static_cast<uintptr_t>(
        imageLow | (static_cast<u64>(imageHigh) << 32)));
    NSData *data = image ? UIImagePNGRepresentation(image) : nil;
    return data ? data.guest_self : 0;
}

void LC32_UIKit_UIImageWriteToSavedPhotosAlbum(
        u32 imageLow, u32 imageHigh, u32 sp) {
    UIImage *image = reinterpret_cast<UIImage *>(static_cast<uintptr_t>(
        imageLow | (static_cast<u64>(imageHigh) << 32)));
    id completionTarget = reinterpret_cast<id>(static_cast<uintptr_t>(
        Dynarmic_current_user_callbacks()->MemoryRead32(sp) |
        (static_cast<u64>(
            Dynarmic_current_user_callbacks()->MemoryRead32(sp + 4))
            << 32)));
    SEL completionSelector = reinterpret_cast<SEL>(static_cast<uintptr_t>(
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 8) |
        (static_cast<u64>(
            Dynarmic_current_user_callbacks()->MemoryRead32(sp + 12))
            << 32)));
    void *contextInfo = reinterpret_cast<void *>(static_cast<uintptr_t>(
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + 16)));
    if(image) UIImageWriteToSavedPhotosAlbum(
        image, completionTarget, completionSelector, contextInfo);
}

u32 LC32_UIKit_NSStringFromCGRect(
        u32 xBits, u32 yBits, u32 sp) {
    float x;
    float y;
    float width;
    float height;
    memcpy(&x, &xBits, sizeof(x));
    memcpy(&y, &yBits, sizeof(y));
    const u32 widthBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp);
    const u32 heightBits =
        Dynarmic_current_user_callbacks()->MemoryRead32(sp + sizeof(u32));
    memcpy(&width, &widthBits, sizeof(width));
    memcpy(&height, &heightBits, sizeof(height));
    return NSStringFromCGRect(CGRectMake(x, y, width, height)).guest_self;
}

u32 LC32_UIKit_GetWindowRootViewController(
        u32 windowLow, u32 windowHigh, u32) {
    UIWindow *window = reinterpret_cast<UIWindow *>(static_cast<uintptr_t>(
        windowLow | (static_cast<u64>(windowHigh) << 32)));
    UIViewController *controller;
#if LC32_UIKIT_COMPATIBILITY
    if(LC32UIKitLegacyCompatibilityEnabled() ||
            LC32LegacyContainerForWindow(window)) {
        NSNumber *legacyDirectRootState = objc_getAssociatedObject(
            window, LC32HideLegacyDirectGuestWindowRootKey);
        if(legacyDirectRootState.boolValue) return 0;
        controller = LC32GuestWindowRootViewController(window);
    } else {
#endif
        controller = LC32NativeWindowRootViewController(window);
#if LC32_UIKIT_COMPATIBILITY
    }
#endif
    if(!controller) return 0;
    u32 guestController = controller.guest_selfOrNull;
    if(!guestController && Dynarmic_guest_thread_is_registered()) {
        guestController = controller.guest_self;
    }
    return guestController;
}

void LC32_UIKit_SetWindowRootViewController(
        u32 windowLow, u32 windowHigh, u32 sp) {
    UIWindow *window = reinterpret_cast<UIWindow *>(static_cast<uintptr_t>(
        windowLow | (static_cast<u64>(windowHigh) << 32)));
    const u64 controllerAddress =
        Dynarmic_current_user_callbacks()->MemoryRead64(sp);
    UIViewController *controller = reinterpret_cast<UIViewController *>(
        static_cast<uintptr_t>(controllerAddress));
    if(!window) return;
#if LC32_UIKIT_COMPATIBILITY
    if(!LC32UIKitLegacyCompatibilityEnabled() &&
            !LC32UIKitLegacyIPadCanvasEnabled() &&
            !LC32UIKitNativeFixedPhoneCanvasEnabled()) {
        LC32NativeSetWindowRootViewController(window, controller);
        return;
    }

    const bool suppressGuestCallbacks = !pthread_main_np();
    dispatch_block_t setRoot = ^{
        const bool previous = LC32SuppressGuestOrientationQuery;
        NSNumber *legacyDirectRootState =
            LC32LegacyDirectGuestRootStateForAssignment(window, controller);
        objc_setAssociatedObject(
            window, LC32HideLegacyDirectGuestWindowRootKey,
            legacyDirectRootState,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        const bool needsImmediatePhoneCanvas =
            LC32WindowNeedsImmediateLegacyPhoneCanvas(
                window, controller);
        if(suppressGuestCallbacks) {
            LC32SuppressGuestOrientationQuery = true;
        }
        LC32LegacyIPadGeometryMode geometryMode =
            LC32LegacyIPadGeometryModeReflowRootController;
        LC32LegacyIPadContainerController *container =
            LC32LegacyContainerForWindow(window);
        /* A movie root gets its own landscape canvas. The root installed
         * after it gets the canvas from before the movie: it is classified
         * afresh when it can be, else it inherits that earlier mode (none if
         * the movie came first). */
        const bool movieRoot = LC32ControllerIsMoviePlayer(controller);
        const bool afterMovie = container &&
            LC32ControllerIsMoviePlayer(container.guestContentController);
        NSNumber *preMovieMode = container ? objc_getAssociatedObject(
            container, &LC32PreMovieGeometryModeKey) : nil;
        const bool hasInheritedMode = container && (afterMovie
            ? preMovieMode != nil && !needsImmediatePhoneCanvas
            : !movieRoot);
        const LC32LegacyIPadGeometryMode inheritedMode = afterMovie
            ? (LC32LegacyIPadGeometryMode)preMovieMode.intValue
            : container ? container.geometryMode : geometryMode;
        if(container && movieRoot && !afterMovie) {
            objc_setAssociatedObject(container, &LC32PreMovieGeometryModeKey,
                @((int)container.geometryMode),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if(container && afterMovie && !movieRoot) {
            objc_setAssociatedObject(container, &LC32PreMovieGeometryModeKey,
                nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if(hasInheritedMode &&
                LC32GeometryModePreservesPhoneCanvas(inheritedMode)) {
            /* Once runtime geometry has identified a legacy drawable, keep
             * that window policy stable if the guest replaces its root. The
             * replacement view may not be loaded yet, so probing it here
             * would otherwise unwrap the container until another activation. */
            geometryMode = inheritedMode;
        } else if(needsImmediatePhoneCanvas) {
            geometryMode = LC32LegacyPhoneCanvasGeometryMode(controller);
        } else if(LC32GuestUsesFixedLandscapeIPadCanvas()) {
            /* This inferred-iPad class creates a 768x1024 EAGL surface and
             * rotates its projection from statusBarOrientation even though
             * it assigns a root controller. Preserve that old surface and
             * let the native wrapper perform UIKit's matching quarter-turn. */
            geometryMode =
                LC32LegacyIPadGeometryModePreservePortraitCanvas;
        }
        LC32InstallGuestWindowRootViewController(
            window, controller, geometryMode);
        LC32ApplyLegacyWindowPolicy(window);
        LC32ScaleLegacyIPadWindow(window);
        LC32SuppressGuestOrientationQuery = previous;
    };
    if(pthread_main_np()) {
        setRoot();
    } else {
        /* Guest callback pthreads can wait on the main guest loop, so a
         * synchronous hop can deadlock. The copied dispatch block retains the
         * window/controller until UIKit performs the assignment. Suppression
         * keeps that foreign native-main callback from entering guest code. */
        dispatch_async(dispatch_get_main_queue(), setRoot);
    }
#else
    LC32NativeSetWindowRootViewController(window, controller);
#endif
}

__END_DECLS

/* See LC32FitPresentedViewInTurnedRootlessWindow. */
static IMP LC32OriginalTransitionViewDidComplete;
extern "C" bool LC32RestoreMoviePresenterAfterTransition(UIView *view);

static void LC32TransitionViewDidComplete(id self, SEL cmd, id transitionView,
        UIView *fromView, UIView *toView, BOOL removeFromView) {
    ((void (*)(id, SEL, id, UIView *, UIView *, BOOL))
        LC32OriginalTransitionViewDidComplete)(
            self, cmd, transitionView, fromView, toView, removeFromView);
    if([toView isKindOfClass:UIView.class] &&
            LC32FitPresentedViewInTurnedRootlessWindow(toView)) {
        /* AVKit's full-screen movie (Modern Combat 4's logo): the same
         * completion block next runs AVKit's animationEnded:, whose
         * -[AVPresentationController dismissalTransitionDidEnd:] puts the
         * presented container's transform back to identity, and the movie
         * played sideways in the turned window. Turn it again after that. */
        UIView *presented = toView;
        dispatch_async(dispatch_get_main_queue(), ^{
            const CGAffineTransform before = LC32NativeViewTransform(presented);
            if(LC32FitPresentedViewInTurnedRootlessWindow(presented) &&
                    !LC32TransformNearlyEquals(before,
                        LC32NativeViewTransform(presented))) {
                fprintf(stderr, "LC32: presented %s turned again after its "
                    "transition reset it\n",
                    object_getClassName(presented.nextResponder));
            }
        });
    }
    if([toView isKindOfClass:UIView.class])
        LC32FitPresentedViewInRootlessIPadWindow(toView);
    if([toView isKindOfClass:UIView.class]) {
        /* The presented controller still reports isBeingPresented here;
         * check again once the presentation has finished. */
        UIWindow *window = LC32NativeViewWindow(toView);
        dispatch_async(dispatch_get_main_queue(), ^{
            LC32CenterPresentedViewsOnPhoneCanvas(window);
        });
    }
    if([toView isKindOfClass:UIView.class]) {
        if(LC32ViewIsInTurnedFullScreenRootlessWindow(toView) &&
                LC32RestoreMoviePresenterAfterTransition(toView)) {
            LC32FitFullScreenRootlessWindow(LC32NativeViewWindow(toView));
        } else {
            LC32FitViewInFullScreenRootlessWindow(toView);
        }
    }
}

/* See LC32DecidePortraitHostedLandscape. Inside LiveContainer the
 * application-level mask comes from the guest's landscape-only Info.plist, and
 * UIKit throws UIApplicationInvalidInterfaceOrientation when the portrait-only
 * root shares no orientation with it. Add portrait for the hosted window. */
static IMP LC32OriginalSupportedOrientationsForWindow;
static IMP LC32OriginalPrivateSupportedOrientationsForWindow;

static UIInterfaceOrientationMask LC32PortraitHostedApplicationMask(
        UIInterfaceOrientationMask mask, UIWindow *window) {
    return [window isKindOfClass:UIWindow.class] &&
            (LC32WindowIsPortraitHosted(window) ||
             LC32WindowIsFullScreenRootlessHosted(window))
        ? mask | UIInterfaceOrientationMaskPortrait : mask;
}

static UIInterfaceOrientationMask LC32SupportedOrientationsForWindow(
        id self, SEL cmd, UIWindow *window) {
    return LC32PortraitHostedApplicationMask(
        ((UIInterfaceOrientationMask (*)(id, SEL, UIWindow *))
            LC32OriginalSupportedOrientationsForWindow)(self, cmd, window),
        window);
}

static UIInterfaceOrientationMask LC32PrivateSupportedOrientationsForWindow(
        id self, SEL cmd, UIWindow *window) {
    return LC32PortraitHostedApplicationMask(
        ((UIInterfaceOrientationMask (*)(id, SEL, UIWindow *))
            LC32OriginalPrivateSupportedOrientationsForWindow)(
                self, cmd, window),
        window);
}

__attribute__((constructor)) static void LC32InstallTurnedPresentationHook(void) {
    Method method = class_getInstanceMethod(
        objc_getClass("UIWindowController"),
        sel_registerName("transitionViewDidComplete:fromView:toView:removeFromView:"));
    if(method) {
        LC32OriginalTransitionViewDidComplete = method_setImplementation(
            method, (IMP)LC32TransitionViewDidComplete);
    }
    Method supported = class_getInstanceMethod(UIApplication.class,
        @selector(supportedInterfaceOrientationsForWindow:));
    if(supported) {
        LC32OriginalSupportedOrientationsForWindow = method_setImplementation(
            supported, (IMP)LC32SupportedOrientationsForWindow);
    }
    Method privateSupported = class_getInstanceMethod(UIApplication.class,
        sel_registerName("_supportedInterfaceOrientationsForWindow:"));
    if(privateSupported) {
        LC32OriginalPrivateSupportedOrientationsForWindow =
            method_setImplementation(privateSupported,
                (IMP)LC32PrivateSupportedOrientationsForWindow);
    }
}

/*
 * iOS 3/4-era games (Gameloft's Starfront) run their whole game loop on a
 * pthread and toggle the idle timer from it. Modern UIKit forwards the
 * setting to FrontBoard, which traps unless it runs on the main queue. The
 * setting is fire-and-forget, so hop asynchronously: the game thread may
 * hold a lock that the main guest loop is waiting for.
 */
@interface UIApplication (LC32OffMainIdleTimer)
- (void)lc32_setIdleTimerDisabled:(BOOL)disabled;
@end

@implementation UIApplication (LC32OffMainIdleTimer)

+ (void)load {
    Method original = class_getInstanceMethod(
        self, @selector(setIdleTimerDisabled:));
    Method compatibility = class_getInstanceMethod(
        self, @selector(lc32_setIdleTimerDisabled:));
    if(original && compatibility) {
        method_exchangeImplementations(original, compatibility);
    }
}

- (void)lc32_setIdleTimerDisabled:(BOOL)disabled {
    if(pthread_main_np()) {
        [self lc32_setIdleTimerDisabled:disabled];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self lc32_setIdleTimerDisabled:disabled];
    });
}

@end

/*
 * iPhone OS 3/4 forwarded every touch that a view did not handle to its next
 * responder. Current UIKit refuses to forward a touch that begins while the
 * window holds more than one touch if the next responder is an exclusiveTouch
 * view. Starfront marks its EAGLView exclusive and leaves its movie
 * controller's empty view on top of it, so the game never saw its two-finger
 * selection box. Exclusive touch only ever kept touches away from other
 * views: when every touch in the window is inside the exclusive view, decide
 * again with its exclusivity lifted, so UIKit keeps its forwarding records.
 */
namespace {
using LC32WantsForwarding = BOOL (*)(id, SEL, id, id, id);
LC32WantsForwarding LC32OriginalTouchWantsForwarding;

BOOL LC32NativeViewIsExclusiveTouch(UIView *view) {
    using Getter = BOOL (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(isExclusiveTouch)));
    return getter(view, @selector(isExclusiveTouch));
}

void LC32NativeSetViewExclusiveTouch(UIView *view, BOOL exclusive) {
    using Setter = void (*)(id, SEL, BOOL);
    static Setter setter = reinterpret_cast<Setter>(
        class_getMethodImplementation(UIView.class,
                                      @selector(setExclusiveTouch:)));
    setter(view, @selector(setExclusiveTouch:), exclusive);
}

bool LC32WindowTouchesStayInsideView(UITouch *touch, UIView *view,
                                     UIEvent *event) {
    UIWindow *window = touch.window;
    if(!window || LC32NativeViewWindow(view) != window) return false;
    NSSet<UITouch *> *touches = [event touchesForWindow:window];
    if(touches.count < 2) return false;
    for(UITouch *other in touches) {
        if(![other.view isDescendantOfView:view]) return false;
    }
    return true;
}

BOOL LC32TouchWantsForwarding(UITouch *self, SEL selector, UIResponder *from,
                              UIResponder *next, UIEvent *event) {
    BOOL wants = LC32OriginalTouchWantsForwarding(
        self, selector, from, next, event);
    if(wants || self.phase != UITouchPhaseBegan ||
            ![next isKindOfClass:UIView.class] ||
            LC32GetGuestExecutableSDKVersion() >= 0x80000) return wants;
    UIView *view = (UIView *)next;
    if(!LC32NativeViewIsExclusiveTouch(view) ||
            !LC32WindowTouchesStayInsideView(self, view, event)) return wants;
    LC32NativeSetViewExclusiveTouch(view, NO);
    wants = LC32OriginalTouchWantsForwarding(self, selector, from, next, event);
    LC32NativeSetViewExclusiveTouch(view, YES);
    return wants;
}
} // namespace

@interface LC32LegacyTouchForwarding : NSObject
@end

@implementation LC32LegacyTouchForwarding

+ (void)load {
    Method method = class_getInstanceMethod(UITouch.class, sel_registerName(
        "_wantsForwardingFromResponder:toNextResponder:withEvent:"));
    char returnType[8] = {};
    if(method) method_getReturnType(method, returnType, sizeof(returnType));
    if(!method || method_getNumberOfArguments(method) != 5 ||
            strcmp(returnType, @encode(BOOL))) return;
    LC32OriginalTouchWantsForwarding = reinterpret_cast<LC32WantsForwarding>(
        method_setImplementation(method, (IMP)LC32TouchWantsForwarding));
}

@end

/* Before iOS 7 a plain table's cells showed the table's background unless the
 * app colored them; iOS 7 made them white. Games that put a clear table over
 * their art and give cells only a border image and white text (Alien Space
 * Retro's level list) then show white boxes. Do what the iOS 7 transition
 * guide asked of apps, from tableView:willDisplayCell:, for older guests. */
namespace {
using LC32NotifyWillDisplayCell = void (*)(id, SEL, id, id);
LC32NotifyWillDisplayCell LC32OriginalNotifyWillDisplayCell;
const void *LC32LegacyCellBackgroundKey = &LC32LegacyCellBackgroundKey;

void LC32ApplyLegacyPlainCellBackground(UITableView *table,
                                        UITableViewCell *cell) {
    if(LC32GetGuestExecutableSDKVersion() >= 0x70000 ||
            ![cell isKindOfClass:UITableViewCell.class] ||
            table.style != UITableViewStylePlain ||
            !LC32ObjectUsesGuestClass(table.dataSource)) return;
    using ColorGetter = UIColor *(*)(id, SEL);
    using ColorSetter = void (*)(id, SEL, UIColor *);
    static ColorGetter getter = reinterpret_cast<ColorGetter>(
        class_getMethodImplementation(UITableViewCell.class,
                                      @selector(backgroundColor)));
    static ColorSetter setter = reinterpret_cast<ColorSetter>(
        class_getMethodImplementation(UITableViewCell.class,
                                      @selector(setBackgroundColor:)));
    /* UIKit's plain-cell fill; setting a backgroundView already counts as
     * customizing the fill, so compare the color itself. */
    SEL plainColor = sel_registerName("tableCellPlainBackgroundColor");
    static UIColor *defaultColor = [UIColor respondsToSelector:plainColor]
        ? ((UIColor *(*)(id, SEL))objc_msgSend)(UIColor.class, plainColor)
        : nil;
    UIColor *applied = objc_getAssociatedObject(cell,
                                                LC32LegacyCellBackgroundKey);
    UIColor *current = getter(cell, @selector(backgroundColor));
    // Only a cell whose fill is still UIKit's, or the one set here before.
    if(!(applied ? [current isEqual:applied]
                 : !current || (defaultColor && [current isEqual:defaultColor])))
        return;
    UIColor *color = table.backgroundColor ?: UIColor.clearColor;
    if(![current isEqual:color]) setter(cell, @selector(setBackgroundColor:), color);
    objc_setAssociatedObject(cell, LC32LegacyCellBackgroundKey,
        getter(cell, @selector(backgroundColor)),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LC32NotifyWillDisplayLegacyCell(UITableView *self, SEL selector,
                                     UITableViewCell *cell,
                                     NSIndexPath *indexPath) {
    LC32ApplyLegacyPlainCellBackground(self, cell);
    LC32OriginalNotifyWillDisplayCell(self, selector, cell, indexPath);
}
} // namespace

@interface LC32LegacyTableCellBackground : NSObject
@end

@implementation LC32LegacyTableCellBackground

+ (void)load {
    Method method = class_getInstanceMethod(UITableView.class,
        sel_registerName("_notifyWillDisplayCell:forIndexPath:"));
    char returnType[8] = {};
    if(method) method_getReturnType(method, returnType, sizeof(returnType));
    if(!method || method_getNumberOfArguments(method) != 4 ||
            strcmp(returnType, @encode(void))) return;
    LC32OriginalNotifyWillDisplayCell =
        reinterpret_cast<LC32NotifyWillDisplayCell>(method_setImplementation(
            method, (IMP)LC32NotifyWillDisplayLegacyCell));
}

@end
