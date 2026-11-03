#import <UIKit/UIKit.h>
#import "../LC32/bridge.h"
#import "../LC32/host_selector_hooks.h"
#import "LegacyNibLoading.h"

@interface NSBundle (LC32GuestNibLoading)
- (NSArray *)lc32_guestLoadNibNamed:(NSString *)name owner:(id)owner
    options:(NSDictionary *)options;
@end

@implementation NSBundle (LC32GuestNibLoading)
+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(loadNibNamed:owner:options:),
        {@selector(lc32_guestLoadNibNamed:owner:options:), nullptr});
}

- (NSArray *)lc32_guestLoadNibNamed:(NSString *)name owner:(id)owner
        options:(NSDictionary *)options {
    if(![(id)object_getClass(self) isGuestClass])
        return LC32LoadGuestNib(self, name, owner, options);
    // Preserve the old guest-subclass/super dispatch and its exception policy.
    const SEL original = @selector(loadNibNamed:owner:options:);
    using LoadNib = NSArray *(*)(id, SEL, NSString *, id, NSDictionary *);
    return ((LoadNib)LC32NativeHostMethod(self, original))(self, original,
        name, owner, options);
}
@end

@interface UIViewController (LC32GuestViewLoading)
- (UIView *)lc32_guestView;
@end

@implementation UIViewController (LC32GuestViewLoading)
+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(view), {@selector(lc32_guestView), nullptr});
}

- (UIView *)lc32_guestView {
    id loadedView = nil;
    if(LC32UIKitGetViewDuringGuestLoad(self, &loadedView)) return loadedView;
    const SEL original = @selector(view);
    using GetView = UIView *(*)(id, SEL);
    return ((GetView)LC32NativeHostMethod(self, original))(self, original);
}
@end

@interface UIAlertView (LC32GuestAlertPresentation)
- (void)lc32_guestShow;
@end

@implementation UIAlertView (LC32GuestAlertPresentation)
+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(show), {@selector(lc32_guestShow), nullptr});
}

- (void)lc32_guestShow {
    // Some legacy games report loading/network errors from a worker thread.
    // Modern alert windows must attach to their scene on the main thread.
    // Schedule only guest show requests; native UIKit calls remain untouched.
    void (^show)(void) = ^{
        const SEL original = @selector(show);
        ((void (*)(id, SEL))LC32NativeHostMethod(self, original))(self, original);
    };
    if(NSThread.isMainThread) show();
    else dispatch_async(dispatch_get_main_queue(), show);
}
@end

extern "C" NSInteger LC32UIKitPortraitHostedStatusBarOrientation(void);

// Weak reference (this file is not ARC); see objc_storeWeak.
static id LC32GuestKeyWindow;

@interface LC32GuestKeyWindowHooks : NSObject
@end
@implementation LC32GuestKeyWindowHooks
+ (void)load {
    // Only the game's own calls reach these, never the hosting app's.
    auto madeKey = [](id window, const uint64_t *) {
        objc_storeWeak(&LC32GuestKeyWindow, window);
    };
    LC32RegisterHostSelectorHook(UIWindow.class,
        @selector(makeKeyAndVisible), {nullptr, madeKey});
    LC32RegisterHostSelectorHook(UIWindow.class,
        @selector(makeKeyWindow), {nullptr, madeKey});
    for(Class cls : {UITextField.class, UITextView.class})
        LC32RegisterHostSelectorHook(cls, @selector(becomeFirstResponder),
            {@selector(lc32_guestBecomeFirstResponder), nullptr});
}
@end

@interface UIView (LC32GuestKeyWindowEditing)
- (BOOL)lc32_guestBecomeFirstResponder;
@end

@implementation UIView (LC32GuestKeyWindowEditing)
// Text input only reaches the key window. A game window that the hosting
// app's own window displaced would get no keyboard, so make it key first,
// as tapping the game would.
- (BOOL)lc32_guestBecomeFirstResponder {
    UIWindow *window = self.window;
    if(window && !window.isKeyWindow) [window makeKeyWindow];
    const SEL original = @selector(becomeFirstResponder);
    using Become = BOOL (*)(id, SEL);
    return ((Become)LC32NativeHostMethod(self, original))(self, original);
}
@end

@interface UIApplication (LC32GuestStatusBarOrientation)
- (UIInterfaceOrientation)lc32_guestStatusBarOrientation;
- (void)lc32_guestSetStatusBarHidden:(BOOL)hidden animated:(BOOL)animated;
- (void)lc32_guestSetStatusBarHidden:(BOOL)hidden;
- (UIWindow *)lc32_guestKeyWindow;
@end

@implementation UIApplication (LC32GuestStatusBarOrientation)
+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(statusBarOrientation),
        {@selector(lc32_guestStatusBarOrientation), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(setStatusBarHidden:animated:),
        {@selector(lc32_guestSetStatusBarHidden:animated:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(setStatusBarHidden:),
        {@selector(lc32_guestSetStatusBarHidden:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(keyWindow),
        {@selector(lc32_guestKeyWindow), nullptr});
}

// iPhone OS games reach their UI through keyWindow (Zenonia 5 adds its
// nickname UITextField to keyWindow.rootViewController.view and messages
// that controller). In a hosting app the process-wide key window can be nil
// or one of the host's own windows, which leaves such views outside the game
// or sends game selectors to a host controller. Answer with the window the
// game itself last made key while it is still on screen.
- (UIWindow *)lc32_guestKeyWindow {
    const SEL original = @selector(keyWindow);
    using GetWindow = UIWindow *(*)(id, SEL);
    UIWindow *key =
        ((GetWindow)LC32NativeHostMethod(self, original))(self, original);
    UIWindow *guestKey = objc_loadWeak(&LC32GuestKeyWindow);
    if(!guestKey || guestKey == key || guestKey.hidden || !guestKey.windowScene)
        return key;
    static BOOL logged;
    if(!logged) {
        logged = YES;
        fprintf(stderr, "LC32: guest keyWindow is %p, not %p\n", guestKey, key);
    }
    return guestKey;
}

// The game's landscape status bar would only appear as a portrait strip over
// its sideways canvas, and showing it re-lays out the scaled game window (pause
// menus toggle it). Keep it hidden while the game is shown that way.
- (void)lc32_guestSetStatusBarHidden:(BOOL)hidden animated:(BOOL)animated {
    if(LC32UIKitPortraitHostedStatusBarOrientation()) hidden = YES;
    const SEL original = @selector(setStatusBarHidden:animated:);
    using SetHidden = void (*)(id, SEL, BOOL, BOOL);
    ((SetHidden)LC32NativeHostMethod(self, original))(
        self, original, hidden, animated);
}

- (void)lc32_guestSetStatusBarHidden:(BOOL)hidden {
    if(LC32UIKitPortraitHostedStatusBarOrientation()) hidden = YES;
    const SEL original = @selector(setStatusBarHidden:);
    using SetHidden = void (*)(id, SEL, BOOL);
    ((SetHidden)LC32NativeHostMethod(self, original))(self, original, hidden);
}

- (UIInterfaceOrientation)lc32_guestStatusBarOrientation {
    // A landscape game shown sideways in a portrait scene converts its touches
    // with this; report its landscape side as iPhone OS did. UIKit's own reads
    // are unaffected.
    const NSInteger hosted = LC32UIKitPortraitHostedStatusBarOrientation();
    if(hosted) return (UIInterfaceOrientation)hosted;
    const SEL original = @selector(statusBarOrientation);
    using GetOrientation = UIInterfaceOrientation (*)(id, SEL);
    return ((GetOrientation)LC32NativeHostMethod(self, original))(self, original);
}
@end

#if LC32_UIKIT_COMPATIBILITY
@interface LC32GuestViewMutationHooks : NSObject
@end
@implementation LC32GuestViewMutationHooks
+ (void)load {
    // Run after the complete guest setter (including native subclass overrides),
    // never for setters issued by UIKit's own layout or compatibility code.
    auto geometryChanged = [](id view, const uint64_t *) {
        LC32UIKitScheduleLegacyOverlayLayout(view, nil);
    };
    const SEL geometry[] = {@selector(setTransform:), @selector(setBounds:),
        @selector(setCenter:), @selector(setFrame:)};
    for(SEL selector : geometry)
        LC32RegisterHostSelectorHook(UIView.class, selector, {nullptr, geometryChanged});
    LC32RegisterHostSelectorHook(UIView.class, @selector(addSubview:),
        {nullptr, [](id view, const uint64_t *args) {
            LC32UIKitScheduleLegacyOverlayLayout(view, (__bridge id)(void *)(uintptr_t)args[0]);
        }});
    LC32RegisterHostSelectorHook(UIView.class, @selector(setAutoresizingMask:),
        {nullptr, [](id view, const uint64_t *) {
            LC32UIKitDidSetGuestAutoresizingMask(view);
        }});
}
@end
#endif
