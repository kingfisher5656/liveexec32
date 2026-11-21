#import <UIKit/UIKit.h>
#import "../LC32/host_selector_hooks.h"
#import "LC32LegacyRotation.h"
#import "LC32ClassicPresentation.h"
#include "../../include/LC32UIKitCompatibilityConfig.h"
#if LC32_UIKIT_COMPATIBILITY
#include <cmath>
#include "../../include/LC32GameProfile.h"

@interface UIScreenMode (LC32ScreenMetricsPrivate)
- (CGSize)_sizeWithLevel:(NSInteger)level;
@end

@interface UIScreenMode (LC32GuestScreenMetrics)
- (CGSize)lc32_applicationScreenModeSize;
- (CGSize)lc32_guestScreenModeSize;
@end

@interface UIScreen (LC32GuestScreenMetrics)
- (CGFloat)lc32_guestScreenScale;
- (CGRect)lc32_guestScreenBounds;
- (CGRect)lc32_guestScreenApplicationFrame;
@end

extern "C" bool LC32UIKitFixedLandscapePhoneScreen(
    CGRect *bounds, CGRect *applicationFrame);
extern "C" bool LC32UIKitGuestScreenIsLandscapeOnly(void);

namespace {
bool hasApplicationModeSize;
bool usesLegacyMetrics;

CGFloat NativeScale(UIScreen *screen) {
    const SEL selector = @selector(scale);
    return ((CGFloat (*)(id, SEL))LC32NativeHostMethod(screen, selector))(screen, selector);
}

CGFloat LegacyScale(UIScreen *screen, CGFloat nativeScale) {
    // New UIKit has removed the caller-sensitive application-scale API.
    // Preserve the pre-iOS-8 main-display contract (before 3x displays), not
    // a game-specific scale or resolution. External screens remain native.
    constexpr CGFloat legacyMaximumScale = 2;
    return usesLegacyMetrics && std::isfinite(nativeScale) && nativeScale > legacyMaximumScale &&
        screen == UIScreen.mainScreen ? legacyMaximumScale : nativeScale;
}
}

/* An SDK 8+ landscape-only guest launches while our scene is still in the
 * launcher's portrait (see LC32UIKitGuestScreenIsLandscapeOnly). Give it the
 * landscape screen iOS 8+ would have launched it into. Once the scene has
 * turned, the native values are landscape already. Phones hide the status
 * bar in landscape, so the application frame is the whole screen too. */
static CGRect LC32LandscapeLaunchExtent(UIScreen *screen, CGRect rect,
                                        const char *what) {
    if(rect.size.width >= rect.size.height ||
            screen != UIScreen.mainScreen ||
            !LC32UIKitGuestScreenIsLandscapeOnly()) {
        return rect;
    }
    using RectGetter = CGRect (*)(id, SEL);
    const CGRect bounds = ((RectGetter)LC32NativeHostMethod(screen,
        @selector(bounds)))(screen, @selector(bounds));
    const CGFloat longEdge = MAX(bounds.size.width, bounds.size.height);
    const CGFloat shortEdge = MIN(bounds.size.width, bounds.size.height);
    static int remaining = 4;
    if(remaining > 0) {
        remaining--;
        fprintf(stderr, "LC32: guest screen %s %.0fx%.0f reported as "
            "landscape %.0fx%.0f (landscape-only SDK 8+ guest, scene still "
            "portrait)\n", what, rect.size.width, rect.size.height,
            longEdge, shortEdge);
    }
    return CGRectMake(0, 0, longEdge, shortEdge);
}

/* A guest window made from that landscape extent while the scene is still
 * portrait would not follow the scene: UIKit resizes only a window that
 * fills the scene, and turns any other one as a rectangle, leaving an
 * 852x393 window as a 393x852 one in the corner of the landscape scene.
 * Start it at the real screen size so it turns with the scene. The guest's
 * GL view keeps the landscape size it was made with. */
static void LC32FitLandscapeLaunchWindow(id window, const uint64_t *) {
    if(![window isKindOfClass:UIWindow.class] ||
            !LC32UIKitGuestScreenIsLandscapeOnly()) {
        return;
    }
    UIScreen *screen = UIScreen.mainScreen;
    using RectGetter = CGRect (*)(id, SEL);
    const CGRect bounds = ((RectGetter)LC32NativeHostMethod(screen,
        @selector(bounds)))(screen, @selector(bounds));
    if(bounds.size.width >= bounds.size.height) return;
    const CGRect frame = ((RectGetter)LC32NativeHostMethod(window,
        @selector(frame)))(window, @selector(frame));
    if(!CGRectEqualToRect(frame, CGRectMake(0, 0, bounds.size.height,
            bounds.size.width))) {
        return;
    }
    using RectSetter = void (*)(id, SEL, CGRect);
    ((RectSetter)LC32NativeHostMethod(window, @selector(setFrame:)))(
        window, @selector(setFrame:), bounds);
    fprintf(stderr, "LC32: landscape launch window %p starts at the "
        "portrait scene size %.0fx%.0f\n", window, bounds.size.width,
        bounds.size.height);
}

/* The scale the guest reads from -[UIScreen scale] (2 on a fixed phone
 * canvas). Pre-iOS-8 UIKit backed drawRect: at this scale. */
extern "C" CGFloat LC32UIKitGuestMainScreenScale(void) {
    return [UIScreen.mainScreen lc32_guestScreenScale];
}

static CGSize LC32NativeModeSize(UIScreenMode *mode) {
    using SizeGetter = CGSize (*)(id, SEL);
    return ((SizeGetter)LC32NativeHostMethod(mode, @selector(size)))(
        mode, @selector(size));
}

// UIKit may hand out a fresh UIScreenMode per -currentMode call, so compare
// by value as well as identity.
static bool LC32ModeIsMainScreenCurrentMode(UIScreenMode *mode) {
    UIScreen *mainScreen = UIScreen.mainScreen;
    using ModeGetter = UIScreenMode *(*)(id, SEL);
    UIScreenMode *current = ((ModeGetter)LC32NativeHostMethod(mainScreen,
        @selector(currentMode)))(mainScreen, @selector(currentMode));
    if(!mode || !current) return false;
    return mode == current || [mode isEqual:current] ||
        CGSizeEqualToSize(LC32NativeModeSize(mode), LC32NativeModeSize(current));
}

@implementation UIScreenMode (LC32GuestScreenMetrics)
- (CGSize)lc32_guestScreenModeSize {
    UIScreen *main = UIScreen.mainScreen;
    LC32ClassicScreenGeometry saved;
    if(self == main.currentMode && LC32GetClassicScreenGeometry(main, &saved)) return saved.modeSize;
    // The fixed phone canvas is also the guest's pixel mode: iOS 4 engines
    // (Star Battalion) set their GL viewport from currentMode.size, and a
    // full-scene mode zooms and crops the 640x960 drawable.
    CGRect canvas;
    if(usesLegacyMetrics && LC32UIKitFixedLandscapePhoneScreen(&canvas, nullptr) &&
            LC32ModeIsMainScreenCurrentMode(self)) {
        const CGFloat scale = [UIScreen.mainScreen lc32_guestScreenScale];
        const CGSize size = CGSizeMake(canvas.size.width * scale,
                                       canvas.size.height * scale);
        static bool logged;
        if(!logged) {
            logged = true;
            fprintf(stderr, "LC32: guest screen mode %.0fx%.0f "
                "(fixed phone canvas)\n", size.width, size.height);
        }
        return size;
    }
    return [self lc32_applicationScreenModeSize];
}

- (CGSize)lc32_applicationScreenModeSize {
    if(!usesLegacyMetrics) return LC32NativeModeSize(self);
    if(!hasApplicationModeSize) {
        CGSize size = LC32NativeModeSize(self);
        UIScreen *screen = UIScreen.mainScreen;
        if(self != screen.currentMode && ![screen.availableModes containsObject:self]) return size;
        const CGFloat nativeScale = NativeScale(screen);
        const CGFloat scale = LegacyScale(screen, nativeScale);
        if(nativeScale > 0 && std::isfinite(nativeScale)) {
            const CGFloat ratio = scale / nativeScale;
            size.width *= ratio;
            size.height *= ratio;
        }
        return size;
    }
    // Level zero asks for the application's legacy scale without inspecting
    // the native caller's image. The external emulator is not the executable
    // (or a framework inside its bundle), so -size can otherwise expose 3x
    // pixels to a guest whose Classic Mode canvas is defined at 2x.
    const SEL selector = @selector(_sizeWithLevel:);
    if(!class_getInstanceMethod(object_getClass(self), selector))
        return LC32NativeModeSize(self);
    using Getter = CGSize (*)(id, SEL, NSInteger);
    return ((Getter)LC32NativeHostMethod(self, selector))(self, selector, 0);
}
@end

@implementation UIScreen (LC32GuestScreenMetrics)
- (CGFloat)lc32_guestScreenScale {
    LC32ClassicScreenGeometry saved;
    if(LC32GetClassicScreenGeometry(self, &saved)) return saved.scale;
    CGFloat scale = NativeScale(self);
    if(usesLegacyMetrics && !hasApplicationModeSize)
        scale = LegacyScale(self, scale);
    const SEL modeSelector = @selector(currentMode);
    using ModeGetter = UIScreenMode *(*)(id, SEL);
    UIScreenMode *mode = ((ModeGetter)LC32NativeHostMethod(self, modeSelector))(
        self, modeSelector);

    // Read both unadapted getters from this same native image, so their
    // caller-dependent scale cancels. Do not derive pixels from window bounds
    // or hard-code an iPhone resolution/scale: UIKit owns the main/external
    // display and iPad policy, and a mode need not match a window's extent.
    using SizeGetter = CGSize (*)(id, SEL);
    const SEL sizeSelector = @selector(size);
    if(usesLegacyMetrics && hasApplicationModeSize && mode &&
            class_getInstanceMethod(object_getClass(mode),
                @selector(_sizeWithLevel:))) {
        const CGSize nativeSize = ((SizeGetter)LC32NativeHostMethod(
            mode, sizeSelector))(mode, sizeSelector);
        const CGSize appSize = [mode lc32_applicationScreenModeSize];
        if(nativeSize.width > 0 && appSize.width > 0 &&
                std::isfinite(nativeSize.width) &&
                std::isfinite(appSize.width)) {
            scale *= appSize.width / nativeSize.width;
        }
    }
    // The fixed phone canvas is a Retina 320x480 screen at most. Engines size
    // their drawable from this, and some derive integer asset/world scales
    // from the resulting pixel width. Games known to handle more (see
    // LC32GameProfile.h) may render up to the display's native scale.
    if(LC32UIKitFixedLandscapePhoneScreen(nullptr, nullptr)) {
        const CGFloat cap = (CGFloat)LC32GameProfileCanvasScale();
        if(cap > 2.0) {
            // The compatibility mode above reports 2x for legacy SDKs; use
            // the panel's own scale instead.
            const CGFloat native = self.nativeScale;
            scale = MAX((CGFloat)2.0, MIN(native, cap));
            static bool logged;
            if(!logged) {
                logged = true;
                fprintf(stderr, "LC32: fixed canvas scale %.2f (cap %.2f)\n",
                    scale, cap);
            }
        } else if(scale > cap) {
            scale = cap;
        }
    }
    return scale;
}

- (CGRect)lc32_guestScreenBounds {
    LC32ClassicScreenGeometry saved;
    if(LC32GetClassicScreenGeometry(self, &saved)) return saved.bounds;
    CGRect bounds;
    if(LC32UIKitFixedLandscapePhoneScreen(&bounds, nullptr)) return bounds;
    using RectGetter = CGRect (*)(id, SEL);
    bounds = ((RectGetter)LC32NativeHostMethod(self, @selector(bounds)))(
        self, @selector(bounds));
    return LC32LandscapeLaunchExtent(self, bounds, "bounds");
}

- (CGRect)lc32_guestScreenApplicationFrame {
    LC32ClassicScreenGeometry saved;
    if(LC32GetClassicScreenGeometry(self, &saved)) return saved.applicationFrame;
    CGRect frame;
    if(LC32UIKitFixedLandscapePhoneScreen(nullptr, &frame)) return frame;
    using RectGetter = CGRect (*)(id, SEL);
    frame = ((RectGetter)LC32NativeHostMethod(self,
        @selector(applicationFrame)))(self, @selector(applicationFrame));
    return LC32LandscapeLaunchExtent(self, frame, "applicationFrame");
}
@end

LC32ClassicScreenGeometry LC32CaptureGuestScreenGeometry(UIScreen *screen) {
    // Preserve the effective application metrics, including older UIKit's
    // caller-sensitive mode API and our fixed phone canvas; do not
    // reconstruct them from the native scale after the host has changed
    // presentation.
    return {[screen lc32_guestScreenBounds], [screen lc32_guestScreenApplicationFrame],
        [screen.currentMode lc32_guestScreenModeSize], [screen lc32_guestScreenScale]};
}

/* Under a fixed phone canvas the guest's screen is 320x480 (or 320x568), but
 * its full-screen window keeps the native scene frame. On iOS 6 that window's
 * frame was the screen's bounds; Tapsonic's gameplay EAGLView pillarboxes its
 * 480-wide picture only when keyWindow.frame is 568 tall. */
@interface UIWindow (LC32GuestScreenMetrics)
- (CGRect)lc32_guestWindowFrame;
- (CGRect)lc32_guestWindowBounds;
@end

static bool LC32GuestFullScreenWindowRect(UIWindow *window, CGRect native,
                                          CGRect *guest) {
    (void)window;
    CGRect screenBounds;
    if(!LC32UIKitFixedLandscapePhoneScreen(&screenBounds, nullptr)) {
        return false;
    }
    UIScreen *screen = UIScreen.mainScreen;
    using RectGetter = CGRect (*)(id, SEL);
    const CGRect nativeScreen = ((RectGetter)LC32NativeHostMethod(screen,
        @selector(bounds)))(screen, @selector(bounds));
    constexpr CGFloat epsilon = 0.5;
    const bool fullScreen =
        (fabs(native.size.width - nativeScreen.size.width) < epsilon &&
         fabs(native.size.height - nativeScreen.size.height) < epsilon) ||
        (fabs(native.size.width - nativeScreen.size.height) < epsilon &&
         fabs(native.size.height - nativeScreen.size.width) < epsilon);
    if(!fullScreen) return false;
    *guest = screenBounds;
    return true;
}

@implementation UIWindow (LC32GuestScreenMetrics)
- (CGRect)lc32_guestWindowFrame {
    using RectGetter = CGRect (*)(id, SEL);
    const CGRect frame = ((RectGetter)LC32NativeHostMethod(self,
        @selector(frame)))(self, @selector(frame));
    CGRect guest;
    return LC32GuestFullScreenWindowRect(self, frame, &guest) ? guest : frame;
}

- (CGRect)lc32_guestWindowBounds {
    using RectGetter = CGRect (*)(id, SEL);
    const CGRect bounds = ((RectGetter)LC32NativeHostMethod(self,
        @selector(bounds)))(self, @selector(bounds));
    CGRect guest;
    return LC32GuestFullScreenWindowRect(self, bounds, &guest) ? guest : bounds;
}
@end

@interface LC32GuestScreenMetricsHooks : NSObject
@end
@implementation LC32GuestScreenMetricsHooks
+ (void)load {
    usesLegacyMetrics = LC32NativeLegacyRotationEnabled();
    // Runtime lookups avoid initializing UIScreen during the runtime's dlopen.
    Class screen = objc_getClass("UIScreen");
    LC32RegisterHostSelectorHook(screen, @selector(bounds),
        {@selector(lc32_guestScreenBounds), nullptr});
    LC32RegisterHostSelectorHook(screen, @selector(applicationFrame),
        {@selector(lc32_guestScreenApplicationFrame), nullptr});
    LC32RegisterHostSelectorHook(screen, @selector(scale),
        {@selector(lc32_guestScreenScale), nullptr});
    LC32RegisterHostSelectorHook(objc_getClass("UIWindow"),
        @selector(initWithFrame:), {nullptr, LC32FitLandscapeLaunchWindow});
    LC32RegisterHostSelectorHook(objc_getClass("UIWindow"), @selector(frame),
        {@selector(lc32_guestWindowFrame), nullptr});
    LC32RegisterHostSelectorHook(objc_getClass("UIWindow"), @selector(bounds),
        {@selector(lc32_guestWindowBounds), nullptr});
    Class mode = objc_getClass("UIScreenMode");
    hasApplicationModeSize = class_getInstanceMethod(mode, @selector(_sizeWithLevel:)) != nullptr;
    LC32RegisterHostSelectorHook(mode, @selector(size),
        {@selector(lc32_guestScreenModeSize), nullptr});
}
@end
#endif
