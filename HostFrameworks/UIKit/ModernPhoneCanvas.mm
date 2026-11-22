/*
 * The letterboxed iPhone screen of an SDK 8+ guest (LC32_ASPECT, see
 * LC32BundleModernCanvasForHost in LC32LegacyCanvas.h).
 *
 * On a later iPhone, iOS ran a game that did not declare that phone's screen
 * in a smaller one (375x667, 320x568 or 320x480) and scaled the whole app to
 * fit. SDK 8+ guests run on the modern UIKit path, where iOS 8 geometry
 * applies: the guest's screen follows the interface orientation and its
 * windows are screen-sized. So the guest sees that smaller screen, and each
 * of the game's windows keeps its guest-space size as its native bounds and
 * is scaled and centred into its scene by its own view transform. Everything
 * inside a window (root and presented controllers, touches, GL drawables) is
 * then in the guest's coordinates, and UIKit's own window rotation (its
 * transform layers above the window) is unaffected. A black native window
 * below the game's covers the rest of the scene.
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../LC32/bridge.h"
#import "../LC32/host_selector_hooks.h"
#import "LC32NativeViewGeometry.h"
#include "../../include/LC32UIKitCompatibilityConfig.h"
#if LC32_UIKIT_COMPATIBILITY
#include <atomic>
#include <cmath>

extern "C" CGSize LC32UIKitModernPhoneCanvasSize(void);
extern "C" UIInterfaceOrientationMask LC32UIKitGuestDeclaredOrientations(void);
extern "C" bool LC32UIKitGuestStatusBarHiddenByDefault(void);
extern "C" void LC32UIKitScheduleLegacyOverlayLayout(
    id object, id addedSubview);

namespace {
/* Set once a window is known to be the game's (see IsCanvasWindow). */
const void *GuestWindowKey = &GuestWindowKey;
/* The guest-space frame of a game window that does not fill its screen (an
 * NSValue). Absent: the window fills the guest's screen. */
const void *GuestFrameKey = &GuestFrameKey;
/* A transform the game set on a window itself (an NSValue), applied inside
 * the canvas scale. */
const void *GuestTransformKey = &GuestTransformKey;
const void *FittingKey = &FittingKey;
const void *RefitKey = &RefitKey;
const void *ClippedKey = &ClippedKey;
const void *BackdropKey = &BackdropKey;      // on a scene: its backdrop
const void *IsBackdropKey = &IsBackdropKey;  // on a backdrop window
const void *ObservedSceneKey = &ObservedSceneKey;

/* The status bar state the game last asked for: -1 none (Info.plist). */
std::atomic<int> guestStatusBarHidden{-1};
bool creatingBackdrop;

bool CanvasActive() {
    return LC32UIKitModernPhoneCanvasSize().width > 0;
}

CGSize NativeScreenSize() {
    UIScreen *screen = UIScreen.mainScreen;
    using RectGetter = CGRect (*)(id, SEL);
    return ((RectGetter)LC32NativeHostMethod(screen, @selector(bounds)))(
        screen, @selector(bounds)).size;
}

/* Whether the guest's screen is landscape now: a single-axis game always
 * sees its own axis (even while our scene still has the launcher's
 * portrait, as iOS 8 launched it straight into landscape, unless
 * LC32_LANDSCAPE_LAUNCH_BOUNDS=0); others follow the scene. */
bool CanvasLandscape() {
    static const bool followsScene = [] {
        const char *value = getenv("LC32_LANDSCAPE_LAUNCH_BOUNDS");
        return value && value[0] == '0';
    }();
    const UIInterfaceOrientationMask declared =
        LC32UIKitGuestDeclaredOrientations();
    const bool landscape = declared & UIInterfaceOrientationMaskLandscape;
    const bool portrait = declared & (UIInterfaceOrientationMaskPortrait |
        UIInterfaceOrientationMaskPortraitUpsideDown);
    if(landscape != portrait && !followsScene) return landscape;
    const CGSize screen = NativeScreenSize();
    return screen.width > screen.height;
}

CGSize OrientedCanvas(bool landscape) {
    const CGSize canvas = LC32UIKitModernPhoneCanvasSize();
    return landscape ? CGSizeMake(canvas.height, canvas.width) : canvas;
}

struct Placement {
    CGSize canvas;  // guest screen, oriented
    CGFloat scale;
    CGPoint origin; // canvas origin in the oriented scene
};

/* Where the canvas sits in the window's scene (the whole screen on a phone;
 * smaller in an iPad window). */
bool CanvasPlacement(UIWindow *window, Placement *placement) {
    if(!CanvasActive()) return false;
    const bool landscape = CanvasLandscape();
    const CGSize canvas = OrientedCanvas(landscape);
    CGSize area = NativeScreenSize();
    if(UIWindowScene *scene = window.windowScene) {
        const CGSize sceneSize = scene.coordinateSpace.bounds.size;
        if(sceneSize.width > 0 && sceneSize.height > 0) area = sceneSize;
    }
    const CGFloat longEdge = MAX(area.width, area.height);
    const CGFloat shortEdge = MIN(area.width, area.height);
    const CGSize oriented = landscape ? CGSizeMake(longEdge, shortEdge)
                                      : CGSizeMake(shortEdge, longEdge);
    const CGFloat scale = MIN(oriented.width / canvas.width,
                              oriented.height / canvas.height);
    if(!(scale > 0) || !std::isfinite(scale)) return false;
    placement->canvas = canvas;
    placement->scale = scale;
    placement->origin = CGPointMake(
        (oriented.width - canvas.width * scale) * 0.5,
        (oriented.height - canvas.height * scale) * 0.5);
    return true;
}

bool NearlyEqual(CGFloat left, CGFloat right) {
    return fabs(left - right) < 0.5;
}

bool SizeMatches(CGSize size, CGSize target) {
    return (NearlyEqual(size.width, target.width) &&
            NearlyEqual(size.height, target.height)) ||
        (NearlyEqual(size.width, target.height) &&
         NearlyEqual(size.height, target.width));
}

/* A size the game means as "my whole screen": its canvas or, for a value
 * read before the canvas existed, the screen or the window's scene. */
bool SizeIsGuestScreen(UIWindow *window, CGSize size) {
    if(SizeMatches(size, LC32UIKitModernPhoneCanvasSize()) ||
            SizeMatches(size, NativeScreenSize())) {
        return true;
    }
    UIWindowScene *scene = window.windowScene;
    return scene && SizeMatches(size, scene.coordinateSpace.bounds.size);
}

bool IsBackdrop(id window) {
    return objc_getAssociatedObject(window, IsBackdropKey) != nil;
}

/* A plain UIWindow or one of the game's own subclasses, paired with a guest
 * object. UIKit's keyboard, text-effects and alert windows are private
 * subclasses and keep the scene even once the game has seen them in
 * UIApplication.windows; so do our backdrops. */
bool IsCandidateWindow(id window) {
    if(!CanvasActive() || !window || IsBackdrop(window)) return false;
    Class cls = object_getClass(window);
    return (cls == UIWindow.class ||
            ([(id)cls isGuestClass] && [window isKindOfClass:UIWindow.class])) &&
        [(UIWindow *)window guest_selfOrNull];
}

void SetGuestFrame(UIWindow *window, CGRect frame) {
    objc_setAssociatedObject(window, GuestFrameKey,
        SizeIsGuestScreen(window, frame.size) &&
            NearlyEqual(frame.origin.x, 0) &&
            NearlyEqual(frame.origin.y, 0)
        ? nil : [NSValue valueWithCGRect:frame],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/* Adopt a window as the game's. One we have not fitted yet still has its
 * own geometry: keep a frame that does not fill the screen (a partial
 * window from a nib, say). */
void MarkGuestWindow(UIWindow *window) {
    if(objc_getAssociatedObject(window, GuestWindowKey)) return;
    if(!objc_getAssociatedObject(window, GuestFrameKey) &&
            CGAffineTransformIsIdentity(LC32NativeViewTransform(window))) {
        const CGRect bounds = LC32NativeViewBounds(window);
        const CGPoint center = LC32NativeViewCenter(window);
        SetGuestFrame(window, CGRectMake(
            center.x - bounds.size.width * 0.5,
            center.y - bounds.size.height * 0.5,
            bounds.size.width, bounds.size.height));
    }
    objc_setAssociatedObject(window, GuestWindowKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/* A window the game made: one it created, made key or moved itself, or one
 * holding one of its controllers (UIKit makes a storyboard game's window). */
bool IsCanvasWindow(UIWindow *window) {
    if(!IsCandidateWindow(window)) return false;
    if(objc_getAssociatedObject(window, GuestWindowKey)) return true;
    using RootGetter = UIViewController *(*)(id, SEL);
    UIViewController *root = ((RootGetter)LC32NativeHostMethod(window,
        @selector(rootViewController)))(window, @selector(rootViewController));
    if(!root || ![(id)object_getClass(root) isGuestClass]) return false;
    MarkGuestWindow(window);
    return true;
}

CGRect GuestFrame(UIWindow *window, const Placement &placement) {
    NSValue *stored = objc_getAssociatedObject(window, GuestFrameKey);
    return stored ? stored.CGRectValue
                  : CGRect{CGPointZero, placement.canvas};
}

CGAffineTransform GuestTransform(UIWindow *window) {
    NSValue *stored = objc_getAssociatedObject(window, GuestTransformKey);
    return stored ? stored.CGAffineTransformValue
                  : CGAffineTransformIdentity;
}
} // namespace

@interface LC32ModernCanvasBackdropController : UIViewController
@end

@implementation LC32ModernCanvasBackdropController
- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = UIColor.blackColor;
    view.userInteractionEnabled = NO;
    self.view = view;
}
// Never decide the scene's orientation or status bar for the game.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return LC32UIKitGuestDeclaredOrientations();
}
- (BOOL)prefersStatusBarHidden {
    return LC32UIKitGuestStatusBarHiddenByDefault();
}
@end

@interface LC32ModernCanvasSceneObserver : NSObject
@end

extern "C" void LC32UIKitFitModernCanvasWindow(UIWindow *window);
extern "C" void LC32UIKitModernCanvasNoteStatusBarHidden(bool hidden);

@implementation LC32ModernCanvasSceneObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    UIWindowScene *scene = object;
    dispatch_async(dispatch_get_main_queue(), ^{
        for(UIWindow *window in scene.windows) {
            LC32UIKitFitModernCanvasWindow(window);
        }
    });
}
@end

static void LC32ObserveModernCanvasScene(UIWindowScene *scene) {
    if(!scene || objc_getAssociatedObject(scene, ObservedSceneKey)) return;
    static LC32ModernCanvasSceneObserver *observer =
        [LC32ModernCanvasSceneObserver new];
    objc_setAssociatedObject(scene, ObservedSceneKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [scene addObserver:observer forKeyPath:@"effectiveGeometry" options:0
               context:nullptr];
}

/* One black window per scene, below the game's. Published before it is
 * shown: becoming visible posts a notification the game may observe. */
static void LC32EnsureModernCanvasBackdrop(UIWindowScene *scene) {
    if(!scene || creatingBackdrop ||
            objc_getAssociatedObject(scene, BackdropKey)) {
        return;
    }
    creatingBackdrop = true;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    objc_setAssociatedObject(window, IsBackdropKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scene, BackdropKey, window,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    window.windowLevel = UIWindowLevelNormal - 1;
    window.backgroundColor = UIColor.blackColor;
    window.userInteractionEnabled = NO;
    window.rootViewController = [LC32ModernCanvasBackdropController new];
    window.hidden = NO;
    creatingBackdrop = false;
}

/* Scale and centre a game window into its scene at its guest-space size. */
extern "C" void LC32UIKitFitModernCanvasWindow(UIWindow *window) {
    if(!IsCandidateWindow(window)) return;
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LC32UIKitFitModernCanvasWindow(window);
        });
        return;
    }
    if(!IsCanvasWindow(window)) return;
    if(objc_getAssociatedObject(window, FittingKey)) {
        // A change made while this window was being fitted: fit again after.
        objc_setAssociatedObject(window, RefitKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    Placement placement;
    if(!CanvasPlacement(window, &placement)) return;
    LC32ObserveModernCanvasScene(window.windowScene);
    LC32EnsureModernCanvasBackdrop(window.windowScene);

    const CGRect guest = GuestFrame(window, placement);
    const CGAffineTransform transform = CGAffineTransformConcat(
        GuestTransform(window),
        CGAffineTransformMakeScale(placement.scale, placement.scale));
    const CGPoint center = CGPointMake(
        placement.origin.x + placement.scale * CGRectGetMidX(guest),
        placement.origin.y + placement.scale * CGRectGetMidY(guest));
    // A full-screen window is the guest's screen: nothing of it shows in the
    // bars. Leave a partial window's own clipping alone.
    const bool fullScreen =
        !objc_getAssociatedObject(window, GuestFrameKey);
    CALayer *layer = LC32NativeViewLayer(window);
    if(fullScreen && !layer.masksToBounds) {
        layer.masksToBounds = YES;
        objc_setAssociatedObject(window, ClippedKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if(!fullScreen && objc_getAssociatedObject(window, ClippedKey)) {
        layer.masksToBounds = NO;
        objc_setAssociatedObject(window, ClippedKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    const CGRect bounds = LC32NativeViewBounds(window);
    const CGPoint currentCenter = LC32NativeViewCenter(window);
    if(CGSizeEqualToSize(bounds.size, guest.size) &&
            CGAffineTransformEqualToTransform(
                LC32NativeViewTransform(window), transform) &&
            NearlyEqual(currentCenter.x, center.x) &&
            NearlyEqual(currentCenter.y, center.y)) {
        return;
    }
    objc_setAssociatedObject(window, FittingKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LC32NativeSetViewBounds(window, CGRectMake(
        bounds.origin.x, bounds.origin.y, guest.size.width,
        guest.size.height));
    LC32NativeSetViewTransform(window, transform);
    LC32NativeSetViewCenter(window, center);
    [CATransaction commit];
    objc_setAssociatedObject(window, FittingKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static int remaining = 6;
    if(remaining > 0) {
        remaining--;
        fprintf(stderr, "LC32: SDK 8+ canvas window %p %.0fx%.0f x%.3f at "
            "(%.1f,%.1f) (was %.0fx%.0f)\n", (__bridge void *)window,
            guest.size.width, guest.size.height, placement.scale, center.x,
            center.y, bounds.size.width, bounds.size.height);
    }
    if(objc_getAssociatedObject(window, RefitKey)) {
        objc_setAssociatedObject(window, RefitKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{
            LC32UIKitFitModernCanvasWindow(window);
        });
    }
}

/* The game made a window key: it is the game's. */
extern "C" void LC32UIKitModernCanvasGuestMadeKey(UIWindow *window) {
    if(!IsCandidateWindow(window)) return;
    MarkGuestWindow(window);
    LC32UIKitFitModernCanvasWindow(window);
}

extern "C" void LC32UIKitModernCanvasNoteStatusBarHidden(bool hidden) {
    guestStatusBarHidden.store(hidden ? 1 : 0, std::memory_order_relaxed);
}

/* The guest's UIScreen: the canvas in the current orientation. iOS 8 hid a
 * phone's status bar in landscape. */
extern "C" bool LC32UIKitModernPhoneScreen(
        CGRect *bounds, CGRect *applicationFrame) {
    if(!CanvasActive()) return false;
    const bool landscape = CanvasLandscape();
    const CGSize canvas = OrientedCanvas(landscape);
    if(bounds) *bounds = CGRect{CGPointZero, canvas};
    if(applicationFrame) {
        const int requested =
            guestStatusBarHidden.load(std::memory_order_relaxed);
        const bool hidden = landscape || (requested >= 0
            ? requested == 1 : LC32UIKitGuestStatusBarHiddenByDefault());
        *applicationFrame = hidden
            ? CGRect{CGPointZero, canvas}
            : CGRectMake(0, 20, canvas.width, canvas.height - 20);
    }
    return true;
}

/* A game window's frame in guest space, for the frame getter. */
extern "C" bool LC32UIKitModernCanvasWindowFrame(
        UIWindow *window, CGRect *frame) {
    if(!IsCandidateWindow(window) ||
            !objc_getAssociatedObject(window, GuestWindowKey)) {
        return false;
    }
    Placement placement;
    if(!CanvasPlacement(window, &placement)) return false;
    *frame = GuestFrame(window, placement);
    return true;
}

/* -initWithFrame: just ran for a guest window: it is the game's, at the
 * frame it asked for. */
extern "C" void LC32UIKitModernCanvasWindowInitialized(UIWindow *window) {
    if(!IsCandidateWindow(window)) return;
    using RectGetter = CGRect (*)(id, SEL);
    SetGuestFrame(window, ((RectGetter)LC32NativeHostMethod(window,
        @selector(frame)))(window, @selector(frame)));
    MarkGuestWindow(window);
    LC32UIKitFitModernCanvasWindow(window);
}

/* The backdrops are the lowest windows, so one would be the first entry of
 * UIApplication.windows, which engines and ad SDKs take as the app's window
 * to present from. Keep them out of the game's view. */
@interface UIApplication (LC32ModernPhoneCanvas)
- (NSArray<UIWindow *> *)lc32_modernCanvasWindows;
@end

@implementation UIApplication (LC32ModernPhoneCanvas)
+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(windows),
        {@selector(lc32_modernCanvasWindows), nullptr});
    // The other two status-bar setters are noted in GuestSelectorHooks.mm.
    LC32RegisterHostSelectorHook(self,
        @selector(setStatusBarHidden:withAnimation:),
        {nullptr, [](id, const uint64_t *arguments) {
            LC32UIKitModernCanvasNoteStatusBarHidden(
                (arguments[0] & 0xff) != 0);
        }});
}

- (NSArray<UIWindow *> *)lc32_modernCanvasWindows {
    using Getter = NSArray *(*)(id, SEL);
    NSArray<UIWindow *> *windows = ((Getter)LC32NativeHostMethod(self,
        @selector(windows)))(self, @selector(windows));
    NSIndexSet *backdrops = [windows indexesOfObjectsPassingTest:
        ^BOOL(UIWindow *window, NSUInteger, BOOL *) {
            return IsBackdrop(window);
        }];
    if(!backdrops.count) return windows;
    NSMutableArray<UIWindow *> *visible = [windows mutableCopy];
    [visible removeObjectsAtIndexes:backdrops];
    return visible;
}
@end

@interface UIWindow (LC32ModernPhoneCanvas)
- (void)lc32_modernCanvasSetFrame:(CGRect)frame;
- (void)lc32_modernCanvasSetBounds:(CGRect)bounds;
- (void)lc32_modernCanvasSetCenter:(CGPoint)center;
- (void)lc32_modernCanvasSetTransform:(CGAffineTransform)transform;
- (CGPoint)lc32_modernCanvasCenter;
- (CGAffineTransform)lc32_modernCanvasTransform;
@end

@implementation UIWindow (LC32ModernPhoneCanvas)
+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(setFrame:),
        {@selector(lc32_modernCanvasSetFrame:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(setBounds:),
        {@selector(lc32_modernCanvasSetBounds:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(setCenter:),
        {@selector(lc32_modernCanvasSetCenter:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(setTransform:),
        {@selector(lc32_modernCanvasSetTransform:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(center),
        {@selector(lc32_modernCanvasCenter), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(transform),
        {@selector(lc32_modernCanvasTransform), nullptr});

    // UIKit's own geometry changes (scene attach, rotation) end in a window
    // layout pass; put a game window back into the canvas after it.
    const SEL selector = @selector(layoutSubviews);
    Method inherited = class_getInstanceMethod(self, selector);
    const IMP original = method_getImplementation(inherited);
    const char *types = method_getTypeEncoding(inherited);
    IMP replacement = imp_implementationWithBlock(^(UIWindow *window) {
        ((void (*)(id, SEL))original)(window, selector);
        if(IsCandidateWindow(window)) LC32UIKitFitModernCanvasWindow(window);
    });
    if(!class_addMethod(self, selector, replacement, types)) {
        method_setImplementation(class_getInstanceMethod(self, selector),
            replacement);
    }
}

/* Each setter records the game's guest-space intent, then gives the window
 * that size at once (as the native setter would, so a read on the game's
 * thread sees it) and refits it on the main thread. The generic view hooks
 * these shadow run afterwards. */
- (void)lc32_modernCanvasSetFrame:(CGRect)frame {
    if(IsCandidateWindow(self)) {
        MarkGuestWindow(self);
        SetGuestFrame(self, frame);
        const CGRect bounds = LC32NativeViewBounds(self);
        LC32NativeSetViewBounds(self, CGRectMake(bounds.origin.x,
            bounds.origin.y, frame.size.width, frame.size.height));
        LC32UIKitFitModernCanvasWindow(self);
    } else {
        using Setter = void (*)(id, SEL, CGRect);
        ((Setter)LC32NativeHostMethod(self, @selector(setFrame:)))(
            self, @selector(setFrame:), frame);
    }
    LC32UIKitScheduleLegacyOverlayLayout(self, nil);
}

- (void)lc32_modernCanvasSetBounds:(CGRect)bounds {
    Placement placement;
    if(IsCandidateWindow(self) && CanvasPlacement(self, &placement)) {
        MarkGuestWindow(self);
        const CGRect guest = GuestFrame(self, placement);
        SetGuestFrame(self, CGRectMake(
            CGRectGetMidX(guest) - bounds.size.width * 0.5,
            CGRectGetMidY(guest) - bounds.size.height * 0.5,
            bounds.size.width, bounds.size.height));
        LC32NativeSetViewBounds(self, bounds);
        LC32UIKitFitModernCanvasWindow(self);
    } else {
        using Setter = void (*)(id, SEL, CGRect);
        ((Setter)LC32NativeHostMethod(self, @selector(setBounds:)))(
            self, @selector(setBounds:), bounds);
    }
    LC32UIKitScheduleLegacyOverlayLayout(self, nil);
}

- (void)lc32_modernCanvasSetCenter:(CGPoint)center {
    Placement placement;
    if(IsCandidateWindow(self) && CanvasPlacement(self, &placement)) {
        MarkGuestWindow(self);
        const CGRect guest = GuestFrame(self, placement);
        SetGuestFrame(self, CGRectMake(
            center.x - guest.size.width * 0.5,
            center.y - guest.size.height * 0.5,
            guest.size.width, guest.size.height));
        LC32UIKitFitModernCanvasWindow(self);
    } else {
        using Setter = void (*)(id, SEL, CGPoint);
        ((Setter)LC32NativeHostMethod(self, @selector(setCenter:)))(
            self, @selector(setCenter:), center);
    }
    LC32UIKitScheduleLegacyOverlayLayout(self, nil);
}

- (void)lc32_modernCanvasSetTransform:(CGAffineTransform)transform {
    if(IsCandidateWindow(self)) {
        MarkGuestWindow(self);
        objc_setAssociatedObject(self, GuestTransformKey,
            CGAffineTransformIsIdentity(transform)
            ? nil : [NSValue valueWithCGAffineTransform:transform],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LC32UIKitFitModernCanvasWindow(self);
    } else {
        using Setter = void (*)(id, SEL, CGAffineTransform);
        ((Setter)LC32NativeHostMethod(self, @selector(setTransform:)))(
            self, @selector(setTransform:), transform);
    }
    LC32UIKitScheduleLegacyOverlayLayout(self, nil);
}

- (CGPoint)lc32_modernCanvasCenter {
    CGRect frame;
    if(LC32UIKitModernCanvasWindowFrame(self, &frame)) {
        return CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    }
    using Getter = CGPoint (*)(id, SEL);
    return ((Getter)LC32NativeHostMethod(self, @selector(center)))(
        self, @selector(center));
}

- (CGAffineTransform)lc32_modernCanvasTransform {
    if(IsCandidateWindow(self) &&
            objc_getAssociatedObject(self, GuestWindowKey)) {
        return GuestTransform(self);
    }
    using Getter = CGAffineTransform (*)(id, SEL);
    return ((Getter)LC32NativeHostMethod(self, @selector(transform)))(
        self, @selector(transform));
}
@end
#else
extern "C" void LC32UIKitFitModernCanvasWindow(UIWindow *) {}
extern "C" void LC32UIKitModernCanvasGuestMadeKey(UIWindow *) {}
extern "C" void LC32UIKitModernCanvasNoteStatusBarHidden(bool) {}
extern "C" bool LC32UIKitModernPhoneScreen(CGRect *, CGRect *) {
    return false;
}
extern "C" bool LC32UIKitModernCanvasWindowFrame(UIWindow *, CGRect *) {
    return false;
}
extern "C" void LC32UIKitModernCanvasWindowInitialized(UIWindow *) {}
#endif
