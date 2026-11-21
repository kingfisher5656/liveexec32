#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <atomic>
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

extern "C" bool LC32UIKitGuestWindowPointFromHost(
    UIWindow *window, CGPoint *point);

@interface UITouch (LC32GuestCanvasLocation)
- (CGPoint)lc32_guestLocationInView:(UIView *)view;
- (CGPoint)lc32_guestPreviousLocationInView:(UIView *)view;
@end

@implementation UITouch (LC32GuestCanvasLocation)
+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(locationInView:),
        {@selector(lc32_guestLocationInView:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(previousLocationInView:),
        {@selector(lc32_guestPreviousLocationInView:), nullptr});
}

static CGPoint LC32GuestTouchPoint(UITouch *touch, SEL original,
        UIView *view) {
    using Location = CGPoint (*)(id, SEL, UIView *);
    CGPoint point = ((Location)LC32NativeHostMethod(touch, original))(
        touch, original, view);
    // Only window-space requests miss the canvas transform; a view request
    // is already converted through the transformed layer tree.
    UIWindow *window = touch.window;
    if(!view || view == window) {
        LC32UIKitGuestWindowPointFromHost(window, &point);
    }
    return point;
}

- (CGPoint)lc32_guestLocationInView:(UIView *)view {
    return LC32GuestTouchPoint(self, @selector(locationInView:), view);
}

- (CGPoint)lc32_guestPreviousLocationInView:(UIView *)view {
    return LC32GuestTouchPoint(self, @selector(previousLocationInView:),
        view);
}
@end

/*
 * Pre-iOS-8 games (Top Gear Stunt School) leave their own music off when the
 * iPod music player reports Playing, treating it as the user's music. Modern
 * systemMusicPlayer can report Playing while nothing is audible, so for the
 * game's own queries believe it only when iOS also reports other audio.
 */
static NSInteger LC32GuestMusicPlaybackState(id player, SEL _cmd) {
    const SEL original = @selector(playbackState);
    const NSInteger state = ((NSInteger (*)(id, SEL))LC32NativeHostMethod(
        player, original))(player, original);
    Class cls = NSClassFromString(@"MPMusicPlayerController");
    id systemPlayer = nil;
    if([cls respondsToSelector:@selector(systemMusicPlayer)]) {
        systemPlayer = ((id (*)(id, SEL))objc_msgSend)(
            cls, @selector(systemMusicPlayer));
    }
    static std::atomic<int> logged{0};
    if(logged.fetch_add(1) < 8 || getenv("LC32_TRACE_MUSIC_STATE")) {
        fprintf(stderr, "LC32: guest playbackState %p system=%d state=%ld\n",
            player, (int)(player == systemPlayer), (long)state);
    }
    if(player != systemPlayer || state != 1 /* Playing */) return state;
    Class sessionClass = NSClassFromString(@"AVAudioSession");
    id session = ((id (*)(id, SEL))objc_msgSend)(
        sessionClass, @selector(sharedInstance));
    const BOOL otherAudio = ((BOOL (*)(id, SEL))objc_msgSend)(
        session, @selector(isOtherAudioPlaying));
    static bool loggedPlaying;
    if(!loggedPlaying) {
        loggedPlaying = true;
        fprintf(stderr, "LC32: system music player reports Playing; "
            "other audio audible=%d\n", (int)otherAudio);
    }
    return otherAudio ? state : 2 /* Paused */;
}

/*
 * Apps that keep themselves alive with silent background audio (JIT and
 * sideload helpers such as StikDebug) leave AVAudioSession's other-audio
 * flags raised while nothing is audible. Games read those flags to defer to
 * the user's music and mute their own soundtrack: Galaxy on Fire 2 HD asks
 * -isOtherAudioPlaying (Top Gear Stunt School asks the C AudioSession
 * property, handled in AudioToolbox.mm). For the game's own queries, report
 * other audio only while the system Music player is playing.
 * MPMusicPlayerController is main-thread only; elsewhere assume no music.
 */
static BOOL LC32GuestOtherAudioFlag(id session, SEL original) {
    const BOOL host = ((BOOL (*)(id, SEL))LC32NativeHostMethod(
        session, original))(session, original);
    bool music = false;
    if(host && pthread_main_np()) {
        Class cls = NSClassFromString(@"MPMusicPlayerController");
        if([cls respondsToSelector:@selector(systemMusicPlayer)]) {
            id player = ((id (*)(id, SEL))objc_msgSend)(
                cls, @selector(systemMusicPlayer));
            const SEL state = @selector(playbackState);
            music = player && ((NSInteger (*)(id, SEL))LC32NativeHostMethod(
                player, state))(player, state) == 1 /* Playing */;
        }
    }
    static std::atomic<int> logged{0};
    if(logged.fetch_add(1) < 8) {
        fprintf(stderr, "LC32 audio: guest %s=%d (host=%d music=%d)\n",
            sel_getName(original), (int)(host && music), (int)host,
            (int)music);
    }
    return host && music;
}

// Hook replacements receive their own selector as _cmd.
static BOOL LC32GuestIsOtherAudioPlaying(id session, SEL) {
    return LC32GuestOtherAudioFlag(session, @selector(isOtherAudioPlaying));
}

static BOOL LC32GuestSecondaryAudioSilenced(id session, SEL) {
    return LC32GuestOtherAudioFlag(session,
        @selector(secondaryAudioShouldBeSilencedHint));
}

static void LC32LogGuestAudio(const char *what, id object) {
    static std::atomic<int> logged{0};
    if(logged.fetch_add(1) >= 60) return;
    Class sessionClass = NSClassFromString(@"AVAudioSession");
    id session = ((id (*)(id, SEL))objc_msgSend)(
        sessionClass, @selector(sharedInstance));
    NSString *category = ((id (*)(id, SEL))objc_msgSend)(
        session, @selector(category));
    const BOOL other = ((BOOL (*)(id, SEL))objc_msgSend)(
        session, @selector(isOtherAudioPlaying));
    const BOOL silenced = ((BOOL (*)(id, SEL))objc_msgSend)(
        session, @selector(secondaryAudioShouldBeSilencedHint));
    const float outputVolume = ((float (*)(id, SEL))objc_msgSend)(
        session, @selector(outputVolume));
    NSString *detail = @"";
    if([object respondsToSelector:@selector(url)]) {
        NSURL *url = ((id (*)(id, SEL))objc_msgSend)(object, @selector(url));
        const BOOL playing = ((BOOL (*)(id, SEL))objc_msgSend)(
            object, @selector(isPlaying));
        const float volume = ((float (*)(id, SEL))objc_msgSend)(
            object, @selector(volume));
        detail = [NSString stringWithFormat:@" %@ playing=%d vol=%.2f",
            url.lastPathComponent, playing, volume];
    }
    fprintf(stderr, "LC32 audio: %s%s category=%s other=%d silenceHint=%d "
        "outVol=%.2f\n", what, detail.UTF8String, category.UTF8String,
        other, silenced, outputVolume);
}

extern "C" void LC32NoteHostTerminating(void);

@interface LC32HostTerminationObserver : NSObject
@end
@implementation LC32HostTerminationObserver
+ (void)load {
    /* _terminateWithStatus: runs before the delegate's
     * applicationWillTerminate:, where games tear themselves down; the
     * notification is the public fallback if UIKit changes the entry. */
    const SEL terminate = sel_registerName("_terminateWithStatus:");
    Method method = class_getInstanceMethod(UIApplication.class, terminate);
    if(method) {
        __block IMP original = method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(
            ^(UIApplication *application, int status) {
                LC32NoteHostTerminating();
                ((void (*)(id, SEL, int))original)(
                    application, terminate, status);
            }));
    }
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationWillTerminateNotification
                    object:nil queue:nil usingBlock:^(NSNotification *) {
            LC32NoteHostTerminating();
        }];
}
@end

@interface LC32GuestMusicPlayerHooks : NSObject
@end
@implementation LC32GuestMusicPlayerHooks
+ (void)load {
    dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer",
        RTLD_LAZY);
    Class cls = NSClassFromString(@"MPMusicPlayerController");
    if(!cls) return;
    const SEL replacement = sel_registerName("lc32_guestPlaybackState");
    class_addMethod(cls, replacement, (IMP)LC32GuestMusicPlaybackState,
        "q16@0:8");
    LC32RegisterHostSelectorHook(cls, @selector(playbackState),
        {replacement, nullptr});
    dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio",
        RTLD_LAZY);
    if(Class player = NSClassFromString(@"AVAudioPlayer")) {
        LC32RegisterHostSelectorHook(player, @selector(play), {nullptr,
            [](id p, const uint64_t *) { LC32LogGuestAudio("play", p); }});
        LC32RegisterHostSelectorHook(player, @selector(stop), {nullptr,
            [](id p, const uint64_t *) { LC32LogGuestAudio("stop", p); }});
        LC32RegisterHostSelectorHook(player, @selector(pause), {nullptr,
            [](id p, const uint64_t *) { LC32LogGuestAudio("pause", p); }});
    }
    if(Class session = NSClassFromString(@"AVAudioSession")) {
        const struct { SEL original; const char *name; IMP imp; } flags[] = {
            {@selector(isOtherAudioPlaying), "lc32_guestIsOtherAudioPlaying",
                (IMP)LC32GuestIsOtherAudioPlaying},
            {@selector(secondaryAudioShouldBeSilencedHint),
                "lc32_guestSecondaryAudioSilenced",
                (IMP)LC32GuestSecondaryAudioSilenced},
        };
        for(const auto &flag : flags) {
            const SEL replacement = sel_registerName(flag.name);
            class_addMethod(session, replacement, flag.imp, "B16@0:8");
            LC32RegisterHostSelectorHook(session, flag.original,
                {replacement, nullptr});
        }
        LC32RegisterHostSelectorHook(session, @selector(setCategory:error:),
            {nullptr, [](id s, const uint64_t *) {
                LC32LogGuestAudio("setCategory", s); }});
        LC32RegisterHostSelectorHook(session, @selector(setActive:error:),
            {nullptr, [](id s, const uint64_t *a) {
                LC32LogGuestAudio(a[0] ? "setActive YES" : "setActive NO",
                    s); }});
    }
}
@end

extern "C" NSInteger LC32UIKitPortraitHostedStatusBarOrientation(void);
extern "C" bool LC32UIKitGuestStatusBarOrientationIsCosmetic(UIWindow *);
extern "C" bool LC32UIKitRootlessStatusBarOrientationFollowsGuest(UIWindow *);
extern "C" bool LC32UIKitHostedStatusBarOrientationFollowsGuest(UIWindow *);
extern "C" void LC32UIKitPortraitHostedSideChanged(UIInterfaceOrientation);

// Weak reference. Production builds this file without ARC; the
// compatibility-switch test builds it with ARC.
#if __has_feature(objc_arc)
static __weak id LC32GuestKeyWindow;
static void LC32StoreGuestKeyWindow(id window) { LC32GuestKeyWindow = window; }
static id LC32LoadGuestKeyWindow(void) { return LC32GuestKeyWindow; }
#else
static id LC32GuestKeyWindow;
static void LC32StoreGuestKeyWindow(id window) {
    objc_storeWeak(&LC32GuestKeyWindow, window);
}
static id LC32LoadGuestKeyWindow(void) {
    return objc_loadWeak(&LC32GuestKeyWindow);
}
#endif
// See LC32UIKitGuestStatusBarOrientationIsCosmetic: the side the guest set
// without turning the scene (0 = none).
static std::atomic<long> LC32GuestCosmeticStatusBarOrientation{0};
// See LC32UIKitRootlessStatusBarOrientationFollowsGuest: the landscape side a
// rootless canvas game last set (0 = none).
static std::atomic<long> LC32GuestRootlessStatusBarOrientation{0};

@interface LC32GuestKeyWindowHooks : NSObject
@end
@implementation LC32GuestKeyWindowHooks
+ (void)load {
    // Only the game's own calls reach these, never the hosting app's.
    auto madeKey = [](id window, const uint64_t *) {
        LC32StoreGuestKeyWindow(window);
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
- (void)lc32_guestSetStatusBarOrientation:(UIInterfaceOrientation)orientation;
- (void)lc32_guestSetStatusBarOrientation:(UIInterfaceOrientation)orientation
                                 animated:(BOOL)animated;
- (void)lc32_guestSetStatusBarHidden:(BOOL)hidden animated:(BOOL)animated;
- (void)lc32_guestSetStatusBarHidden:(BOOL)hidden;
- (UIWindow *)lc32_guestKeyWindow;
@end

@implementation UIApplication (LC32GuestStatusBarOrientation)
+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(statusBarOrientation),
        {@selector(lc32_guestStatusBarOrientation), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(setStatusBarOrientation:),
        {@selector(lc32_guestSetStatusBarOrientation:), nullptr});
    LC32RegisterHostSelectorHook(self,
        @selector(setStatusBarOrientation:animated:),
        {@selector(lc32_guestSetStatusBarOrientation:animated:), nullptr});
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
    UIWindow *guestKey = LC32LoadGuestKeyWindow();
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

static bool LC32GuestKeepStatusBarOrientationCosmetic(
        UIInterfaceOrientation orientation) {
    if(orientation < UIInterfaceOrientationPortrait ||
       orientation > UIInterfaceOrientationLandscapeLeft) return false;
    if(!LC32UIKitGuestStatusBarOrientationIsCosmetic(
            (UIWindow *)LC32LoadGuestKeyWindow())) return false;
    if(LC32GuestCosmeticStatusBarOrientation.exchange(orientation) !=
            orientation) {
        fprintf(stderr, "LC32: guest status bar orientation %ld kept "
            "guest-only (portrait rootless window)\n", (long)orientation);
    }
    return true;
}

// See LC32UIKitRootlessStatusBarOrientationFollowsGuest. The gate reads the
// window's root controller, so evaluate it on the main thread only; game
// threads (render loops) reuse the last main-thread answer.
static std::atomic<bool> LC32GuestRootlessStatusBarGateOpen{false};
static bool LC32GuestRootlessStatusBarGate(void) {
    if(!pthread_main_np()) return LC32GuestRootlessStatusBarGateOpen.load();
    const bool open = LC32UIKitRootlessStatusBarOrientationFollowsGuest(
        (UIWindow *)LC32LoadGuestKeyWindow());
    LC32GuestRootlessStatusBarGateOpen.store(open);
    return open;
}

// Portrait-hosted, the same game turns its own sideways picture (9mm): make
// the latest side it set the hosted side. Main thread only (the gate reads
// the window's root); the getter retries there, e.g. after a movie root.
static void LC32GuestSyncHostedStatusBarOrientation(void) {
    if(!pthread_main_np()) return;
    const long side = LC32GuestRootlessStatusBarOrientation.load();
    const NSInteger hosted = LC32UIKitPortraitHostedStatusBarOrientation();
    if(!side || !hosted || hosted == side ||
            !LC32UIKitHostedStatusBarOrientationFollowsGuest(
                (UIWindow *)LC32LoadGuestKeyWindow())) return;
    LC32UIKitPortraitHostedSideChanged((UIInterfaceOrientation)side);
    fprintf(stderr, "LC32: guest status bar orientation %ld "
        "(portrait-hosted rootless window, hosted side follows)\n", side);
}

// Every landscape side the game sets is kept, also while the gate is closed
// (a movie root), so the side reported once it opens is the latest one. The
// native setter still runs; it only no longer decides what the game reads.
static void LC32GuestNoteRootlessStatusBarOrientation(
        UIInterfaceOrientation orientation) {
    if(!UIInterfaceOrientationIsLandscape(orientation)) return;
    const long previous =
        LC32GuestRootlessStatusBarOrientation.exchange(orientation);
    if(previous != orientation && LC32GuestRootlessStatusBarGate()) {
        fprintf(stderr, "LC32: guest status bar orientation %ld "
            "(rootless window, reported back to the game)\n",
            (long)orientation);
    }
    LC32GuestSyncHostedStatusBarOrientation();
}

- (void)lc32_guestSetStatusBarOrientation:(UIInterfaceOrientation)orientation {
    if(LC32GuestKeepStatusBarOrientationCosmetic(orientation)) return;
    LC32GuestNoteRootlessStatusBarOrientation(orientation);
    const SEL original = @selector(setStatusBarOrientation:);
    using SetOrientation = void (*)(id, SEL, UIInterfaceOrientation);
    ((SetOrientation)LC32NativeHostMethod(self, original))(
        self, original, orientation);
}

- (void)lc32_guestSetStatusBarOrientation:(UIInterfaceOrientation)orientation
                                 animated:(BOOL)animated {
    if(LC32GuestKeepStatusBarOrientationCosmetic(orientation)) return;
    LC32GuestNoteRootlessStatusBarOrientation(orientation);
    const SEL original = @selector(setStatusBarOrientation:animated:);
    using SetOrientation = void (*)(id, SEL, UIInterfaceOrientation, BOOL);
    ((SetOrientation)LC32NativeHostMethod(self, original))(
        self, original, orientation, animated);
}

- (UIInterfaceOrientation)lc32_guestStatusBarOrientation {
    // A landscape game shown sideways in a portrait scene converts its touches
    // with this; report its landscape side as iPhone OS did. UIKit's own reads
    // are unaffected.
    LC32GuestSyncHostedStatusBarOrientation();
    const NSInteger hosted = LC32UIKitPortraitHostedStatusBarOrientation();
    if(hosted) return (UIInterfaceOrientation)hosted;
    const long cosmetic = LC32GuestCosmeticStatusBarOrientation.load();
    if(cosmetic) return (UIInterfaceOrientation)cosmetic;
    const long rootlessSide = LC32GuestRootlessStatusBarOrientation.load();
    if(rootlessSide && LC32GuestRootlessStatusBarGate())
        return (UIInterfaceOrientation)rootlessSide;
    const SEL original = @selector(statusBarOrientation);
    using GetOrientation = UIInterfaceOrientation (*)(id, SEL);
    return ((GetOrientation)LC32NativeHostMethod(self, original))(self, original);
}
@end

static CGAffineTransform LC32GuestNativeViewTransform(UIView *view) {
    using Getter = CGAffineTransform (*)(id, SEL);
    static Getter getter = reinterpret_cast<Getter>(
        class_getMethodImplementation(UIView.class, @selector(transform)));
    return view ? getter(view, @selector(transform))
                : CGAffineTransformIdentity;
}
extern "C" uint32_t LC32GetGuestExecutableSDKVersion(void);

/*
 * iPhone OS autorotated a landscape game to the side the device was held in,
 * so games converted touches from UIDevice.orientation (Death Rally's
 * didRotate: picks its window-to-game touch mapping from it and ignores flat,
 * portrait and unknown readings). Here the picture is turned once, while the
 * device can be flat, rotation-locked or untracked, and that game keeps its
 * default mapping, which mirrors touches across the screen diagonal. For
 * pre-iOS-8 guests, answer a non-landscape reading with the landscape side
 * the game window is actually turned to; real landscape readings pass through.
 */
static UIDeviceOrientation LC32GuestDisplayedLandscapeDevice(void) {
    UIWindow *window = [UIApplication.sharedApplication
        lc32_guestKeyWindow];
    if(!window) return UIDeviceOrientationUnknown;
    UIView *root = window.rootViewController.view;
    if(!root || root.superview == nil) root = window.subviews.firstObject;
    if(root) {
        const CGAffineTransform turn = LC32GuestNativeViewTransform(root);
        // UIKit turns the root by +pi/2 for interface LandscapeRight (device
        // LandscapeLeft, both 3) and by -pi/2 for LandscapeLeft (both 4).
        if(turn.b > 0.5 && fabs(turn.a) < 0.5) return UIDeviceOrientationLandscapeLeft;
        if(turn.b < -0.5 && fabs(turn.a) < 0.5) return UIDeviceOrientationLandscapeRight;
    }
    const UIInterfaceOrientation side =
        [UIApplication.sharedApplication lc32_guestStatusBarOrientation];
    if(UIInterfaceOrientationIsLandscape(side)) return (UIDeviceOrientation)side;
    return UIDeviceOrientationUnknown;
}

static std::atomic<long> LC32GuestReportedDeviceOrientation{-1};
extern "C" bool LC32UIKitGuestFixedCanvasDeviceOrientation(UIDeviceOrientation *);
static std::atomic<bool> LC32GuestDeviceRecheckScheduled{false};

static void LC32ScheduleGuestDeviceOrientationRecheck(void);

static UIDeviceOrientation LC32GuestDeviceOrientation(id device, SEL) {
    const SEL original = @selector(orientation);
    const UIDeviceOrientation native = ((UIDeviceOrientation (*)(id, SEL))
        LC32NativeHostMethod(device, original))(device, original);
    UIDeviceOrientation pinned;
    if(LC32UIKitGuestFixedCanvasDeviceOrientation(&pinned)) {
        if(LC32GuestReportedDeviceOrientation.exchange(pinned) != pinned) {
            fprintf(stderr, "LC32: guest UIDevice orientation %ld -> %ld "
                "(fixed canvas launch side)\n", (long)native, (long)pinned);
        }
        return pinned;
    }
    if(LC32GetGuestExecutableSDKVersion() >= 0x80000 ||
            UIDeviceOrientationIsLandscape(native) || !NSThread.isMainThread) {
        return native;
    }
    const UIDeviceOrientation displayed = LC32GuestDisplayedLandscapeDevice();
    if(!UIDeviceOrientationIsLandscape(displayed)) return native;
    if(LC32GuestReportedDeviceOrientation.exchange(displayed) != displayed) {
        fprintf(stderr, "LC32: guest UIDevice orientation %ld -> %ld "
            "(displayed landscape side)\n", (long)native, (long)displayed);
    }
    LC32ScheduleGuestDeviceOrientationRecheck();
    return displayed;
}

/* The game may read the orientation before UIKit turns its window. Check
 * again shortly afterwards and, if the side it was given is no longer the
 * displayed one, let it read the orientation again. */
static void LC32ScheduleGuestDeviceOrientationRecheck(void) {
    if(LC32GuestDeviceRecheckScheduled.exchange(true)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
        LC32GuestDeviceRecheckScheduled = false;
        const UIDeviceOrientation native = ((UIDeviceOrientation (*)(id, SEL))
            LC32NativeHostMethod(UIDevice.currentDevice, @selector(orientation)))(
            UIDevice.currentDevice, @selector(orientation));
        if(UIDeviceOrientationIsLandscape(native)) return;
        const UIDeviceOrientation displayed =
            LC32GuestDisplayedLandscapeDevice();
        if(!UIDeviceOrientationIsLandscape(displayed) ||
                displayed == LC32GuestReportedDeviceOrientation.load()) return;
        [NSNotificationCenter.defaultCenter
            postNotificationName:UIDeviceOrientationDidChangeNotification
            object:UIDevice.currentDevice];
    });
}

@interface LC32GuestDeviceOrientationHooks : NSObject
@end
@implementation LC32GuestDeviceOrientationHooks
+ (void)load {
    LC32RegisterHostSelectorHook(UIDevice.class, @selector(orientation),
        {@selector(lc32_guestOrientation), nullptr});
}
@end

@interface UIDevice (LC32GuestDeviceOrientation)
- (UIDeviceOrientation)lc32_guestOrientation;
@end
@implementation UIDevice (LC32GuestDeviceOrientation)
- (UIDeviceOrientation)lc32_guestOrientation {
    return LC32GuestDeviceOrientation(self, @selector(orientation));
}
@end

#if LC32_UIKIT_COMPATIBILITY
#import "LC32LegacyRotation.h"

@implementation CADisplayLink (LC32GuestInitialPresentation)
+ (void)load {
    LC32RegisterHostSelectorHook(object_getClass(self), @selector(displayLinkWithTarget:selector:),
        {@selector(lc32_guestDisplayLinkWithTarget:selector:), nullptr});
}
+ (CADisplayLink *)lc32_guestDisplayLinkWithTarget:(id)target selector:(SEL)action {
    target = LC32LegacyStartupDisplayLinkTarget(target, &action);
    SEL original = @selector(displayLinkWithTarget:selector:);
    using Factory = CADisplayLink *(*)(id, SEL, id, SEL);
    return ((Factory)LC32NativeHostMethod(self, original))(self, original, target, action);
}
@end

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
