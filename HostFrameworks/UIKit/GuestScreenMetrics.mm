#import <UIKit/UIKit.h>
#import "../LC32/host_selector_hooks.h"
#import "LC32LegacyRotation.h"
#include "../../include/LC32UIKitCompatibilityConfig.h"
#if LC32_UIKIT_COMPATIBILITY
#include <cmath>

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
    // The fixed phone canvas is also the guest's pixel mode: iOS 4 engines
    // (Star Battalion) set their GL viewport from currentMode.size, and a
    // full-scene mode zooms and crops the 640x960 drawable.
    CGRect canvas;
    if(LC32UIKitFixedLandscapePhoneScreen(&canvas, nullptr) &&
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
    using ScaleGetter = CGFloat (*)(id, SEL);
    const SEL scaleSelector = @selector(scale);
    CGFloat scale = ((ScaleGetter)LC32NativeHostMethod(self, scaleSelector))(
        self, scaleSelector);
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
    if(LC32NativeLegacyRotationEnabled() && mode &&
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
    // from the resulting pixel width.
    if(scale > 2.0 && LC32UIKitFixedLandscapePhoneScreen(nullptr, nullptr)) {
        scale = 2.0;
    }
    return scale;
}

- (CGRect)lc32_guestScreenBounds {
    CGRect bounds;
    if(LC32UIKitFixedLandscapePhoneScreen(&bounds, nullptr)) return bounds;
    using RectGetter = CGRect (*)(id, SEL);
    return ((RectGetter)LC32NativeHostMethod(self, @selector(bounds)))(
        self, @selector(bounds));
}

- (CGRect)lc32_guestScreenApplicationFrame {
    CGRect frame;
    if(LC32UIKitFixedLandscapePhoneScreen(nullptr, &frame)) return frame;
    using RectGetter = CGRect (*)(id, SEL);
    return ((RectGetter)LC32NativeHostMethod(self,
        @selector(applicationFrame)))(self, @selector(applicationFrame));
}
@end

@interface LC32GuestScreenMetricsHooks : NSObject
@end
@implementation LC32GuestScreenMetricsHooks
+ (void)load {
    // Runtime lookups avoid initializing UIScreen during the runtime's dlopen.
    Class screen = objc_getClass("UIScreen");
    LC32RegisterHostSelectorHook(screen, @selector(bounds),
        {@selector(lc32_guestScreenBounds), nullptr});
    LC32RegisterHostSelectorHook(screen, @selector(applicationFrame),
        {@selector(lc32_guestScreenApplicationFrame), nullptr});
    LC32RegisterHostSelectorHook(screen, @selector(scale),
        {@selector(lc32_guestScreenScale), nullptr});
    if(!LC32NativeLegacyRotationEnabled()) return;
    Class mode = objc_getClass("UIScreenMode");
    LC32RegisterHostSelectorHook(mode, @selector(size),
        {@selector(lc32_guestScreenModeSize), nullptr});
}
@end
#endif
