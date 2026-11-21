#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include "LiveExec32Shared.h"

/* UIKit.mm: a renderer straight in a turned full-screen rootless window. */
extern "C" bool LC32ViewIsInTurnedFullScreenRootlessWindow(UIView *view);
/* UIKit.mm: the fixed portrait canvas window of a landscape phone game. */
extern "C" bool LC32WindowIsLandscapeGamePortraitCanvas(UIWindow *window);

/*
 * On iPhone OS 3.2/4.x, -[MPMoviePlayerViewController initWithContentURL:]
 * started loading the movie by itself. Games such as Gameloft's Starfront
 * wait for MPMoviePlayerLoadStateDidChangeNotification before they present
 * the controller (and never call -play or -prepareToPlay), so on current
 * MediaPlayer their logo/intro movie never starts and the screen stays black.
 *
 * Start loading (and honor shouldAutoplay) the way the old framework did:
 * asynchronously, after the guest has finished configuring the controller.
 *
 * The load-state notification can now arrive before the guest has put its
 * presenting view controller's view into the window (Starfront adds it from a
 * dispatch_async block), and current UIKit then refuses the presentation. Old
 * hosts were slow enough to hide this, so give such a presentation a short
 * grace period for the view to reach a window.
 *
 * Current MediaPlayer also posts MPMoviePlayerPlaybackDidFinishNotification
 * (reason UserExited) some time after the app calls -stop, even when the
 * movie already ended and posted its own DidFinish; iPhone OS 3.x/4.x did
 * not. Starfront observes that notification for every player (object:nil)
 * and stops whichever movie is current, so LOGO's late notification killed
 * the INTRO cinematic that had just been created. Drop DidFinish for a player
 * once the app's -stop has returned (until it is played again), and don't
 * auto-load or present a movie the app has already stopped.
 *
 * Current MediaPlayer also no longer posts PlaybackStateDidChange when an
 * autoplaying movie starts playing (only the paused/stopped transitions).
 * Starfront builds its subtitle overlay, including the intro's Skip button,
 * from that "playing" notification, so post it once per play session when the
 * player is seen playing without one.
 *
 * Starfront also embeds the presenting controller's view in its EAGLView, as
 * iPhone OS 3/4 apps did. Dismissing the movie runs current UIKit's legacy
 * window-controller transition, which gives that view the scene's bounds
 * before it goes back into EAGLView. The view is then a transparent sheet
 * over the game's 320x480 canvas. UIKit forwards one-finger touches from it to
 * EAGLView but not multi-touch, so the two-finger selection box never starts.
 * iPhone OS left an embedded presenter's geometry alone; restore it.
 * The same holds for a renderer placed straight in a rootless window (Unity
 * 3.x, see LC32FitFullScreenRootlessWindow): the transition hands it back
 * turned and landscape-sized, so Unity, which still turns its own content
 * for a portrait view, draws stretched and maps touches wrongly.
 *
 * Old MPMoviePlayerController defaulted shouldAutoplay to YES and started
 * playback by itself once the movie became playable; a presented
 * MPMoviePlayerViewController therefore played without any -play call.
 * Current MediaPlayer defaults it to NO and never autoplays (the property
 * only sets AVPlayer's stall policy). Unity 3.x's Handheld.PlayFullScreenMovie
 * presents such a controller, never calls -play, and holds its game loop until
 * DidFinish, so the app sat on a paused, black movie forever. Restore the old
 * default and play an autoplay movie once it is playable.
 *
 * A controller shown with presentMoviePlayerViewControllerAnimated: also
 * dismissed itself when its movie finished; Unity's movie code only stops and
 * releases it. Current MediaPlayer leaves the dead movie view over the game,
 * and the next movie (Air Mail's upsell) cannot be presented. Dismiss it after
 * DidFinish or the app's -stop unless the app already did.
 */

namespace {
IMP LC32OriginalMoviePlayerViewControllerInit;
IMP LC32OriginalPresentMoviePlayerViewController;
bool LC32LegacyMoviePlayerHookInstalled;
IMP LC32OriginalMoviePlayerStop;
IMP LC32OriginalMoviePlayerPlay;
IMP LC32OriginalMoviePlayerPrepareToPlay;
IMP LC32OriginalMoviePlayerInitWithContentURL;
IMP LC32OriginalPostNotification;
IMP LC32OriginalPostNotificationNameObjectUserInfo;
NSString *LC32MoviePlayerDidFinishName;
const void *LC32MoviePlayerStoppedKey = &LC32MoviePlayerStoppedKey;
const void *LC32MoviePlayerPlayingPostedKey = &LC32MoviePlayerPlayingPostedKey;
// Set once a player's DidFinish was delivered (cleared by -play).
const void *LC32MoviePlayerFinishedKey = &LC32MoviePlayerFinishedKey;
const void *LC32MoviePlayerAutoplayedKey = &LC32MoviePlayerAutoplayedKey;
const void *LC32MoviePlayerAutoDismissKey = &LC32MoviePlayerAutoDismissKey;
NSString *LC32MoviePlayerStateChangeName;
constexpr int LC32PlayingPollLimit = 50;              // 50 x 100 ms = 5 s
constexpr int64_t LC32PlayingPollDelay = 100 * NSEC_PER_MSEC;
constexpr int LC32PresentRetryLimit = 40;            // 40 x 50 ms = 2 s
constexpr int64_t LC32PresentRetryDelay = 50 * NSEC_PER_MSEC;
const void *LC32EmbeddedPresenterGeometryKey =
    &LC32EmbeddedPresenterGeometryKey;

struct LC32EmbeddedPresenterGeometry {
    CGRect bounds;
    CGPoint center;
    CGAffineTransform transform;
    // Straight in a turned full-screen window: finish after the transition.
    bool fullScreenWindow;
};

/* UIView's and UIViewController's own IMPs: the guest may subclass both, and
 * these run from native UIKit transitions. */
template<typename Result, typename... Arguments>
Result LC32NativeCall(Class owner, id object, SEL selector,
                      Arguments... arguments) {
    using Function = Result (*)(id, SEL, Arguments...);
    return reinterpret_cast<Function>(class_getMethodImplementation(
        owner, selector))(object, selector, arguments...);
}

UIView *LC32NativeViewIfLoaded(UIViewController *controller) {
    return controller ? LC32NativeCall<UIView *>(UIViewController.class,
        controller, @selector(viewIfLoaded)) : nil;
}

UIView *LC32NativeSuperview(UIView *view) {
    return LC32NativeCall<UIView *>(UIView.class, view, @selector(superview));
}

void LC32RecordEmbeddedPresenterGeometry(UIViewController *presenter) {
    UIView *view = LC32NativeViewIfLoaded(presenter);
    if(!view) return;
    UIView *superview = LC32NativeSuperview(view);
    if(!superview || ([superview isKindOfClass:UIWindow.class] &&
            !LC32ViewIsInTurnedFullScreenRootlessWindow(view))) {
        objc_setAssociatedObject(view, LC32EmbeddedPresenterGeometryKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    const LC32EmbeddedPresenterGeometry geometry = {
        LC32NativeCall<CGRect>(UIView.class, view, @selector(bounds)),
        LC32NativeCall<CGPoint>(UIView.class, view, @selector(center)),
        LC32NativeCall<CGAffineTransform>(UIView.class, view,
                                          @selector(transform)),
        LC32ViewIsInTurnedFullScreenRootlessWindow(view),
    };
    objc_setAssociatedObject(view, LC32EmbeddedPresenterGeometryKey,
        [NSValue valueWithBytes:&geometry
                       objCType:@encode(LC32EmbeddedPresenterGeometry)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LC32RestoreEmbeddedPresenterGeometry(UIView *view, bool finished) {
    NSValue *saved = objc_getAssociatedObject(
        view, LC32EmbeddedPresenterGeometryKey);
    if(!saved) return;
    if(finished) {
        objc_setAssociatedObject(view, LC32EmbeddedPresenterGeometryKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The app may have made it a window root since; leave that to UIKit.
    if([LC32NativeSuperview(view) isKindOfClass:UIWindow.class] &&
            !LC32ViewIsInTurnedFullScreenRootlessWindow(view)) return;
    LC32EmbeddedPresenterGeometry geometry;
    [saved getValue:&geometry size:sizeof(geometry)];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LC32NativeCall<void>(UIView.class, view, @selector(setTransform:),
                         geometry.transform);
    LC32NativeCall<void>(UIView.class, view, @selector(setBounds:),
                         geometry.bounds);
    LC32NativeCall<void>(UIView.class, view, @selector(setCenter:),
                         geometry.center);
    [CATransaction commit];
}

bool LC32MoviePlayerWasStopped(id player) {
    return player &&
        objc_getAssociatedObject(player, LC32MoviePlayerStoppedKey) != nil;
}

void LC32SetMoviePlayerStopped(id player, bool stopped) {
    objc_setAssociatedObject(player, LC32MoviePlayerStoppedKey,
        stopped ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

id LC32MoviePlayerOfController(id controller) {
    if(![controller respondsToSelector:@selector(moviePlayer)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(controller, @selector(moviePlayer));
}

void LC32RunMovieAutoDismiss(id player) {
    void (^dismiss)(void) = player
        ? objc_getAssociatedObject(player, LC32MoviePlayerAutoDismissKey) : nil;
    if(dismiss) dismiss();
}

void LC32RemoveMovieOverlay(id player);

void LC32LegacyMoviePlayerStop(id self, SEL cmd) {
    LC32RemoveMovieOverlay(self);
    // A DidFinish posted from inside -stop is delivered as before.
    ((void (*)(id, SEL))LC32OriginalMoviePlayerStop)(self, cmd);
    // iOS 5 MediaPlayer started posting DidFinish after -stop; keep that for
    // guests built against it. (The guest SDK is not known yet when the hooks
    // are installed.)
    if(LC32GetGuestExecutableSDKVersion() < 0x50000) {
        LC32SetMoviePlayerStopped(self, true);
    }
    /* Current MediaPlayer posts nothing for an app's -stop, so a movie
     * presented with presentMoviePlayerViewControllerAnimated: stays up
     * (Unity's tap-to-skip); iOS 5's DidFinish dismissed it. Not gated on
     * the SDK: these old binaries often record none (Air Mail, Starfront),
     * and an app that dismisses the movie itself leaves nothing to do. */
    LC32RunMovieAutoDismiss(self);
}

id LC32LegacyMoviePlayerInitWithContentURL(id self, SEL cmd, NSURL *url) {
    id player = ((id (*)(id, SEL, NSURL *))
        LC32OriginalMoviePlayerInitWithContentURL)(self, cmd, url);
    if([player respondsToSelector:@selector(setShouldAutoplay:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            player, @selector(setShouldAutoplay:), YES);
    }
    return player;
}

/*
 * iPhone OS 2.x/3.1 MPMoviePlayerController had no view: -play showed the
 * movie full screen in its own landscape window, over the app. H.A.W.X.
 * creates one, sets movieControlMode/scalingMode and calls -play, nothing
 * else. Current MediaPlayer only plays such a player's audio, since its view
 * is never put on screen, and leaves nothing to tap. When a stand-alone
 * player (not an MPMoviePlayerViewController's) is still off-screen shortly
 * after -play, show its view in an overlay window the way the old framework
 * did, turned to the landscape side the app uses, and let a tap skip it.
 */
const void *LC32MoviePlayerOwnedByControllerKey =
    &LC32MoviePlayerOwnedByControllerKey;
const void *LC32MoviePlayerOverlayKey = &LC32MoviePlayerOverlayKey;
constexpr int64_t LC32StandaloneMovieDelay = 300 * NSEC_PER_MSEC;

void LC32PostMovieDidFinish(id player, NSInteger reason);
}  // namespace

@interface LC32LegacyMovieOverlayWindow : UIWindow
@property(nonatomic, weak) id lc32_player;
@property(nonatomic, strong) UIView *lc32_movieView;
@property(nonatomic, weak) UIView *lc32_originalSuperview;
@end

/* MediaPlayer's view is a proxy that installs the real playback view only
 * under a view controller, so the overlay needs a root. It must not turn the
 * scene: answer only the scene's current orientation. */
@interface LC32LegacyMovieOverlayController : UIViewController
@property(nonatomic) UIInterfaceOrientationMask lc32_mask;
@end

@implementation LC32LegacyMovieOverlayController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return self.lc32_mask ?: UIInterfaceOrientationMaskAll;
}
- (BOOL)shouldAutorotate { return NO; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

@implementation LC32LegacyMovieOverlayWindow
- (void)lc32_skip:(UITapGestureRecognizer *)recognizer {
    if(recognizer.state != UIGestureRecognizerStateEnded) return;
    id player = self.lc32_player;
    if(!player) return;
    fprintf(stderr, "LC32: legacy movie skipped by tap\n");
    // The app's own -stop path is not involved: stop natively, then post the
    // DidFinish the old player sent when the user ended a movie.
    ((void (*)(id, SEL))LC32OriginalMoviePlayerStop)(player, @selector(stop));
    LC32PostMovieDidFinish(player, 2 /* MPMovieFinishReasonUserExited */);
}
@end

namespace {
void LC32RemoveMovieOverlay(id player) {
    LC32LegacyMovieOverlayWindow *overlay = player
        ? objc_getAssociatedObject(player, LC32MoviePlayerOverlayKey) : nil;
    if(!overlay) return;
    objc_setAssociatedObject(player, LC32MoviePlayerOverlayKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *movieView = overlay.lc32_movieView;
    if(movieView.window == overlay) {
        [movieView removeFromSuperview];
        movieView.transform = CGAffineTransformIdentity;
    }
    overlay.hidden = YES;
    overlay.lc32_movieView = nil;
}

void LC32PostMovieDidFinish(id player, NSInteger reason) {
    if(!player || !LC32MoviePlayerDidFinishName) return;
    LC32RemoveMovieOverlay(player);
    if(LC32MoviePlayerWasStopped(player)) return;
    NSString *__strong *reasonKey = (NSString *__strong *)dlsym(RTLD_DEFAULT,
        "MPMoviePlayerPlaybackDidFinishReasonUserInfoKey");
    ((void (*)(id, SEL, id, id, id))
        LC32OriginalPostNotificationNameObjectUserInfo)(
            NSNotificationCenter.defaultCenter,
            @selector(postNotificationName:object:userInfo:),
            LC32MoviePlayerDidFinishName, player,
            reasonKey && *reasonKey ? @{*reasonKey: @(reason)} : nil);
    // Old players finished once; drop a later native DidFinish.
    if(LC32GetGuestExecutableSDKVersion() < 0x50000)
        LC32SetMoviePlayerStopped(player, true);
}

UIWindowScene *LC32MovieOverlayScene(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *key = nil;
    if([application respondsToSelector:@selector(lc32_guestKeyWindow)])
        key = ((UIWindow *(*)(id, SEL))objc_msgSend)(
            application, @selector(lc32_guestKeyWindow));
    if(key.windowScene) return key.windowScene;
    for(UIScene *scene in application.connectedScenes) {
        if([scene isKindOfClass:UIWindowScene.class] &&
                scene.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)scene;
    }
    return nil;
}

void LC32ShowStandaloneMovie(id player) {
    if(!player || LC32MoviePlayerWasStopped(player) ||
            objc_getAssociatedObject(player, LC32MoviePlayerOwnedByControllerKey) ||
            objc_getAssociatedObject(player, LC32MoviePlayerOverlayKey) ||
            ![player respondsToSelector:@selector(view)]) return;
    const NSInteger state = [player respondsToSelector:@selector(playbackState)]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(player, @selector(playbackState))
        : 0;
    if(state == 0 /* Stopped */) return;
    UIView *movieView = ((UIView *(*)(id, SEL))objc_msgSend)(
        player, @selector(view));
    if(!movieView || movieView.window) return;   // The app shows it itself.
    UIWindowScene *scene = LC32MovieOverlayScene();
    if(!scene) return;

    const CGRect bounds = scene.coordinateSpace.bounds;
    LC32LegacyMovieOverlayWindow *overlay =
        [[LC32LegacyMovieOverlayWindow alloc] initWithWindowScene:scene];
    overlay.frame = bounds;
    overlay.windowLevel = UIWindowLevelNormal + 10;
    overlay.backgroundColor = UIColor.blackColor;
    overlay.lc32_player = player;
    overlay.lc32_movieView = movieView;
    overlay.lc32_originalSuperview = movieView.superview;
    LC32LegacyMovieOverlayController *root =
        [LC32LegacyMovieOverlayController new];
    root.lc32_mask = (UIInterfaceOrientationMask)(1 << scene.interfaceOrientation);
    root.view.backgroundColor = UIColor.blackColor;
    overlay.rootViewController = root;

    // The old movie window was landscape. In a portrait scene, turn the view
    // to the side the app set with setStatusBarOrientation: (the guest-only
    // value), else iPhone OS's default LandscapeRight.
    CGAffineTransform turn = CGAffineTransformIdentity;
    CGSize size = bounds.size;
    if(bounds.size.height > bounds.size.width) {
        UIInterfaceOrientation side = UIInterfaceOrientationLandscapeRight;
        UIApplication *application = UIApplication.sharedApplication;
        if([application respondsToSelector:
                @selector(lc32_guestStatusBarOrientation)]) {
            const UIInterfaceOrientation guest =
                ((UIInterfaceOrientation (*)(id, SEL))objc_msgSend)(
                    application, @selector(lc32_guestStatusBarOrientation));
            if(guest == UIInterfaceOrientationLandscapeLeft) side = guest;
        }
        turn = CGAffineTransformMakeRotation(
            side == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 : M_PI_2);
        size = CGSizeMake(bounds.size.height, bounds.size.width);
    }
    if([player respondsToSelector:@selector(setControlStyle:)]) {
        // Taps skip; old VolumeOnly/Hidden modes had no transport controls.
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            player, @selector(setControlStyle:), 0 /* None */);
    }
    [movieView removeFromSuperview];
    movieView.transform = CGAffineTransformIdentity;
    movieView.autoresizingMask = UIViewAutoresizingNone;
    movieView.bounds = CGRectMake(0, 0, size.width, size.height);
    movieView.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    movieView.transform = turn;
    movieView.userInteractionEnabled = NO;
    [root.view addSubview:movieView];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:overlay action:@selector(lc32_skip:)];
    [overlay addGestureRecognizer:tap];
    overlay.hidden = NO;
    objc_setAssociatedObject(player, LC32MoviePlayerOverlayKey, overlay,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    fprintf(stderr, "LC32: legacy movie shown full screen (%.0fx%.0f, %s)\n",
        size.width, size.height,
        CGAffineTransformIsIdentity(turn) ? "unturned" : "turned");

    /* MediaPlayer attaches its AVPlayerView to the proxy later, at the
     * proxy's old 320x480 size, and autoresizing never catches up. Keep the
     * proxy's children filling it while the overlay is up. */
    __weak LC32LegacyMovieOverlayWindow *weakOverlay = overlay;
    __weak UIView *weakMovieView = movieView;
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES
        block:^(NSTimer *timer) {
            LC32LegacyMovieOverlayWindow *shown = weakOverlay;
            UIView *view = weakMovieView;
            if(!shown || shown.hidden || !view || view.window != shown) {
                [timer invalidate];
                return;
            }
            for(UIView *child in view.subviews) {
                if(!CGRectEqualToRect(child.frame, view.bounds))
                    child.frame = view.bounds;
            }
        }];

    if(LC32MoviePlayerDidFinishName) {
        __weak id weakPlayer = player;
        __block id observer = [NSNotificationCenter.defaultCenter
            addObserverForName:LC32MoviePlayerDidFinishName object:player
            queue:nil usingBlock:^(NSNotification *) {
                LC32RemoveMovieOverlay(weakPlayer);
                [NSNotificationCenter.defaultCenter removeObserver:observer];
                observer = nil;
            }];
    }
}

/*
 * iPhone OS 3.2-4.x showed a full-screen movie (MPMoviePlayerController's
 * fullscreen mode) turned to the app's status-bar side. Gameloft's N.O.V.A. 2
 * puts an MPMoviePlayerViewController's view straight into its rootless
 * 320x480 game window and sets moviePlayer.fullscreen. Current MediaPlayer
 * then presents the movie in its own full-screen controller, which follows
 * the scene and not the game: its landscape logo and intro played upright and
 * letterboxed, sideways to the player, whether the game was hosted upright in
 * a portrait scene or its window was turned for a landscape one. The game
 * draws its landscape picture sideways into that portrait canvas, so keep the
 * movie in the view the app placed in its window (its Skip/subtitle overlay
 * stays above it, as on iPhone OS) and turn that view the same way.
 */
IMP LC32OriginalMoviePlayerSetFullscreen;
IMP LC32OriginalMoviePlayerSetFullscreenAnimated;
const void *LC32MovieFullscreenRequestedKey = &LC32MovieFullscreenRequestedKey;
const void *LC32MovieTurnedInGameCanvasKey =
    &LC32MovieTurnedInGameCanvasKey;

NSInteger LC32GameCanvasMovieSide(UIWindow *window) {
    if(LC32GetGuestExecutableSDKVersion() >= 0x80000) return 0;
    UIApplication *application = UIApplication.sharedApplication;
    if(!window && [application respondsToSelector:@selector(lc32_guestKeyWindow)])
        window = ((UIWindow *(*)(id, SEL))objc_msgSend)(
            application, @selector(lc32_guestKeyWindow));
    if(!window || !LC32WindowIsLandscapeGamePortraitCanvas(window) ||
            ![application respondsToSelector:
                @selector(lc32_guestStatusBarOrientation)]) return 0;
    // The side the game draws for (portrait-hosted or the scene's side).
    const UIInterfaceOrientation side =
        ((UIInterfaceOrientation (*)(id, SEL))objc_msgSend)(
            application, @selector(lc32_guestStatusBarOrientation));
    return UIInterfaceOrientationIsLandscape(side) ? side : 0;
}

void LC32TurnMovieInGameCanvas(id player) {
    if(!player || LC32MoviePlayerWasStopped(player) ||
            !objc_getAssociatedObject(player, LC32MovieFullscreenRequestedKey) ||
            ![player respondsToSelector:@selector(view)]) return;
    UIView *movieView = ((UIView *(*)(id, SEL))objc_msgSend)(
        player, @selector(view));
    UIWindow *window = movieView.window;
    // The overlay window of a stand-alone movie is already turned.
    if(!window || [window isKindOfClass:LC32LegacyMovieOverlayWindow.class])
        return;
    UIView *child = movieView;
    while(child.superview && child.superview != window) child = child.superview;
    if(objc_getAssociatedObject(child, LC32MovieTurnedInGameCanvasKey)) return;
    /* Only the movie's own view (or its controller's, not presented) placed
     * straight in the game window. A presented movie controller (Starfront)
     * or one embedded elsewhere gets the full-screen request it asked for. */
    UIResponder *owner = child.nextResponder;
    const bool placedByApp = child.superview == window &&
        child != window.subviews.firstObject &&
        (child == movieView ||
         ([owner isKindOfClass:UIViewController.class] &&
          !((UIViewController *)owner).presentingViewController));
    const NSInteger side = LC32GameCanvasMovieSide(window);
    const CGRect bounds = window.bounds;
    if(!placedByApp || !side || bounds.size.height <= bounds.size.width) {
        objc_setAssociatedObject(player, LC32MovieFullscreenRequestedKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, BOOL, BOOL))
            LC32OriginalMoviePlayerSetFullscreenAnimated)(
                player, @selector(setFullscreen:animated:), YES, NO);
        return;
    }
    objc_setAssociatedObject(child, LC32MovieTurnedInGameCanvasKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if([player respondsToSelector:@selector(setControlStyle:)]) {
        // Full-screen movies of that era had no transport controls here.
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            player, @selector(setControlStyle:), 0 /* None */);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    child.autoresizingMask = UIViewAutoresizingNone;
    child.transform = CGAffineTransformIdentity;
    child.bounds = CGRectMake(0, 0, bounds.size.height, bounds.size.width);
    child.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    child.transform = CGAffineTransformMakeRotation(
        side == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 : M_PI_2);
    if(child.backgroundColor == nil) child.backgroundColor = UIColor.blackColor;
    [CATransaction commit];
    fprintf(stderr, "LC32: full-screen movie turned in the game canvas "
        "(%.0fx%.0f, side %ld)\n", bounds.size.height,
        bounds.size.width, (long)side);

    /* MediaPlayer attaches its playback view to the proxy later, at the
     * proxy's old size; keep the proxy's children filling it. */
    __weak UIView *weakChild = child;
    __weak UIView *weakMovieView = movieView;
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES
        block:^(NSTimer *timer) {
            UIView *turned = weakChild;
            UIView *view = weakMovieView;
            if(!turned || !view || !turned.window) {
                [timer invalidate];
                return;
            }
            if(view != turned && !CGRectEqualToRect(view.frame, turned.bounds))
                view.frame = turned.bounds;
            for(UIView *grandchild in view.subviews) {
                if(!CGRectEqualToRect(grandchild.frame, view.bounds))
                    grandchild.frame = view.bounds;
            }
        }];
}

bool LC32KeepMovieInGameWindow(id player, BOOL fullscreen) {
    if(!player) return false;
    if(!fullscreen) {
        objc_setAssociatedObject(player, LC32MovieFullscreenRequestedKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return false;
    }
    if(!LC32GameCanvasMovieSide(nil)) return false;
    objc_setAssociatedObject(player, LC32MovieFullscreenRequestedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The app adds the movie's view to its window right after this.
    __weak id weakPlayer = player;
    dispatch_async(dispatch_get_main_queue(), ^{
        LC32TurnMovieInGameCanvas(weakPlayer);
    });
    return true;
}

void LC32LegacyMoviePlayerSetFullscreen(id self, SEL cmd, BOOL fullscreen) {
    if(LC32KeepMovieInGameWindow(self, fullscreen)) return;
    ((void (*)(id, SEL, BOOL))LC32OriginalMoviePlayerSetFullscreen)(
        self, cmd, fullscreen);
}

void LC32LegacyMoviePlayerSetFullscreenAnimated(id self, SEL cmd,
                                                BOOL fullscreen, BOOL animated) {
    if(LC32KeepMovieInGameWindow(self, fullscreen)) return;
    ((void (*)(id, SEL, BOOL, BOOL))LC32OriginalMoviePlayerSetFullscreenAnimated)(
        self, cmd, fullscreen, animated);
}

void LC32LegacyMoviePlayerPlay(id self, SEL cmd) {
    LC32SetMoviePlayerStopped(self, false);
    // An explicit -play replaces the one-shot autoplay.
    objc_setAssociatedObject(self, LC32MoviePlayerAutoplayedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, LC32MoviePlayerPlayingPostedKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, LC32MoviePlayerFinishedKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL))LC32OriginalMoviePlayerPlay)(self, cmd);
    if(NSThread.isMainThread) LC32TurnMovieInGameCanvas(self);
    __weak id weakPlayer = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, LC32StandaloneMovieDelay),
        dispatch_get_main_queue(), ^{
            LC32TurnMovieInGameCanvas(weakPlayer);
            LC32ShowStandaloneMovie(weakPlayer);
        });
}

void LC32LegacyMoviePlayerPrepareToPlay(id self, SEL cmd) {
    LC32SetMoviePlayerStopped(self, false);
    objc_setAssociatedObject(self, LC32MoviePlayerPlayingPostedKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL))LC32OriginalMoviePlayerPrepareToPlay)(self, cmd);
}

/*
 * A movie whose repeatMode is One never finished by itself on iPhone OS 3-8.
 * Current MediaPlayer maps repeatMode to its player controller's looping and
 * keeps the movie going, but -_avPlayerItemDidPlayToEndNotification: still
 * posts DidFinish (PlaybackEnded) at the end of every pass. BioShock embeds
 * its main-menu buttons in a looping background movie's view and removes that
 * view on DidFinish, so the menu vanished after 23 s and left a black screen.
 */
bool LC32IsRepeatingMovieLoopEnd(id object, NSDictionary *userInfo) {
    if(![object respondsToSelector:@selector(repeatMode)] ||
       ((NSInteger (*)(id, SEL))objc_msgSend)(
           object, @selector(repeatMode)) != 1)    // MPMovieRepeatModeOne
        return false;
    static NSString *reasonKey = ^NSString * {
        NSString *__strong *key = (NSString *__strong *)dlsym(RTLD_DEFAULT,
            "MPMoviePlayerPlaybackDidFinishReasonUserInfoKey");
        return key && *key ? *key
            : @"MPMoviePlayerPlaybackDidFinishReasonUserInfoKey";
    }();
    id reason = [userInfo isKindOfClass:NSDictionary.class]
        ? userInfo[reasonKey] : nil;
    return [reason respondsToSelector:@selector(integerValue)] &&
        [reason integerValue] == 0;                 // PlaybackEnded
}

bool LC32ShouldDropMovieNotification(NSString *name, id object,
                                     NSDictionary *userInfo) {
    if(!name || !(name == LC32MoviePlayerDidFinishName ||
                  [name isEqualToString:LC32MoviePlayerDidFinishName]))
        return false;
    return LC32MoviePlayerWasStopped(object) ||
        LC32IsRepeatingMovieLoopEnd(object, userInfo);
}

void LC32LegacyPostNotification(NSNotificationCenter *self, SEL cmd,
                                NSNotification *note) {
    if(LC32ShouldDropMovieNotification(note.name, note.object, note.userInfo))
        return;
    ((void (*)(id, SEL, id))LC32OriginalPostNotification)(self, cmd, note);
}

void LC32LegacyPostNotificationNameObjectUserInfo(NSNotificationCenter *self,
        SEL cmd, NSNotificationName name, id object, NSDictionary *userInfo) {
    if(LC32ShouldDropMovieNotification(name, object, userInfo)) return;
    ((void (*)(id, SEL, id, id, id))
        LC32OriginalPostNotificationNameObjectUserInfo)(
            self, cmd, name, object, userInfo);
}

bool LC32MoviePlayerIsPlaying(id player) {
    return [player respondsToSelector:@selector(playbackState)] &&
        ((NSInteger (*)(id, SEL))objc_msgSend)(
            player, @selector(playbackState)) == 1;   // Playing
}

void LC32PostPlayingWhenStarted(__weak id weakPlayer, int attempt) {
    id player = weakPlayer;
    if(!player || LC32MoviePlayerWasStopped(player) ||
            objc_getAssociatedObject(player, LC32MoviePlayerPlayingPostedKey))
        return;
    if(LC32MoviePlayerIsPlaying(player)) {
        objc_setAssociatedObject(player, LC32MoviePlayerPlayingPostedKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSNotificationCenter.defaultCenter
            postNotificationName:LC32MoviePlayerStateChangeName object:player];
        return;
    }
    if(attempt >= LC32PlayingPollLimit) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, LC32PlayingPollDelay),
        dispatch_get_main_queue(), ^{
            LC32PostPlayingWhenStarted(weakPlayer, attempt + 1);
        });
}

void LC32AutoplayWhenPlayable(id player) {
    if(!player || LC32MoviePlayerWasStopped(player) ||
            objc_getAssociatedObject(player, LC32MoviePlayerAutoplayedKey) ||
            ![player respondsToSelector:@selector(shouldAutoplay)] ||
            ![player respondsToSelector:@selector(loadState)] ||
            !((BOOL (*)(id, SEL))objc_msgSend)(
                player, @selector(shouldAutoplay)))
        return;
    const NSUInteger loadState = ((NSUInteger (*)(id, SEL))objc_msgSend)(
        player, @selector(loadState));
    if(!(loadState & 1)) return;   // MPMovieLoadStatePlayable
    objc_setAssociatedObject(player, LC32MoviePlayerAutoplayedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(!LC32MoviePlayerIsPlaying(player)) {
        ((void (*)(id, SEL))objc_msgSend)(player, @selector(play));
    }
}

/* iPhone OS 3.x-5 still posted MPMoviePlayerContentPreloadDidFinishNotification
 * once a movie had preloaded (deprecated since 3.2, no longer posted now).
 * Gameloft's Asphalt 6 HD builds its intro overlay (the Skip button and
 * subtitles, -[MoviePlayer substView_init]) only from that notification, so
 * the intro could not be skipped. Post it once per player when it becomes
 * playable, as the old framework did. */
const void *LC32MoviePlayerPreloadPostedKey = &LC32MoviePlayerPreloadPostedKey;

void LC32PostPreloadFinishedWhenPlayable(id player) {
    if(!player || LC32MoviePlayerWasStopped(player) ||
            objc_getAssociatedObject(player, LC32MoviePlayerPreloadPostedKey) ||
            ![player respondsToSelector:@selector(loadState)])
        return;
    const NSUInteger loadState = ((NSUInteger (*)(id, SEL))objc_msgSend)(
        player, @selector(loadState));
    if(!(loadState & 1)) return;   // MPMovieLoadStatePlayable
    objc_setAssociatedObject(player, LC32MoviePlayerPreloadPostedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"MPMoviePlayerContentPreloadDidFinishNotification"
                      object:player];
}

void LC32InstallLegacyMoviePlayerPlayingNotification() {
    NSString *__strong *stateName = (NSString *__strong *)dlsym(
        RTLD_DEFAULT, "MPMoviePlayerPlaybackStateDidChangeNotification");
    NSString *__strong *loadName = (NSString *__strong *)dlsym(
        RTLD_DEFAULT, "MPMoviePlayerLoadStateDidChangeNotification");
    if(!stateName || !*stateName || !loadName || !*loadName) return;
    LC32MoviePlayerStateChangeName = *stateName;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if(LC32MoviePlayerDidFinishName) {
        [center addObserverForName:LC32MoviePlayerDidFinishName object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                if(note.object) objc_setAssociatedObject(note.object,
                    LC32MoviePlayerFinishedKey, @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }];
    }
    // A real "playing" notification makes the synthesized one unnecessary.
    [center addObserverForName:*stateName object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            if(LC32MoviePlayerIsPlaying(note.object)) {
                objc_setAssociatedObject(note.object,
                    LC32MoviePlayerPlayingPostedKey, @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }];
    [center addObserverForName:*loadName object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            __weak id weakPlayer = note.object;
            dispatch_async(dispatch_get_main_queue(), ^{
                LC32TurnMovieInGameCanvas(weakPlayer);
                LC32AutoplayWhenPlayable(weakPlayer);
                LC32PostPreloadFinishedWhenPlayable(weakPlayer);
                LC32PostPlayingWhenStarted(weakPlayer, 0);
            });
        }];
}

/*
 * iPhone OS drew a movie inside MPMoviePlayerController.view wherever the app
 * put that view, under any subviews the app layered on it. Current
 * MediaPlayer attaches its AVPlayerViewController to that view only when the
 * view's superview is a controller's root view (or hostingViewController is
 * set); anywhere else the movie plays unseen. BioShock adds its looping
 * main-menu movie, which carries the menu buttons, to its EAGLView, so the
 * menu showed over black. Host such a player in the nearest controller up
 * the responder chain, and keep the movie under the app's own subviews.
 *
 * Current MediaPlayer's _MPMoviePlayerProxyView also forwards its own frame
 * (including a non-zero origin) to its child AVPlayerView, which shifts the
 * video inside the proxy view whenever an app positions moviePlayer.view at a
 * non-zero origin (e.g. Ace Combat Xi sets frame (-80, 80, 480, 320) before
 * rotating it 90 degrees into a 320x480 window). Keep AVPlayerView aligned to
 * the proxy view's bounds.
 */
Class LC32MovieProxyClass;
IMP LC32OriginalMovieProxyUpdateContainment;
IMP LC32OriginalMovieProxyLayoutSubviews;

bool LC32ViewIsControllerRootView(UIView *view) {
    UIResponder *next = view.nextResponder;
    return [next isKindOfClass:UIViewController.class] &&
        [(UIViewController *)next viewIfLoaded] == view;
}

void LC32FitMovieProxyPlaybackView(UIView *self, id player) {
    if(!player && [self respondsToSelector:@selector(controller)]) {
        player = ((id (*)(id, SEL))objc_msgSend)(self, @selector(controller));
    }
    UIViewController *playback =
        [player respondsToSelector:@selector(playerViewController)]
        ? ((UIViewController *(*)(id, SEL))objc_msgSend)(
            player, @selector(playerViewController)) : nil;
    UIView *playbackView = playback.viewIfLoaded;
    if(playbackView && playbackView.superview == self) {
        if(!CGRectEqualToRect(playbackView.frame, self.bounds))
            playbackView.frame = self.bounds;
        if(self.subviews.firstObject != playbackView)
            [self sendSubviewToBack:playbackView];
    }
}

void LC32LegacyMovieProxyUpdateContainment(UIView *self, SEL cmd,
                                           UIWindow *window,
                                           UIView *superview) {
    id player = [self respondsToSelector:@selector(controller)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(controller)) : nil;
    if(superview && player &&
            [player respondsToSelector:@selector(hostingViewController)] &&
            [player respondsToSelector:@selector(setHostingViewController:)] &&
            !((id (*)(id, SEL))objc_msgSend)(
                player, @selector(hostingViewController)) &&
            !LC32ViewIsControllerRootView(superview)) {
        UIResponder *responder = superview.nextResponder;
        while(responder && ![responder isKindOfClass:UIViewController.class])
            responder = responder.nextResponder;
        if(responder) {
            ((void (*)(id, SEL, id))objc_msgSend)(player,
                @selector(setHostingViewController:), responder);
            fprintf(stderr, "LC32: embedded movie view in %s hosted by %s\n",
                class_getName(object_getClass(superview)),
                class_getName(object_getClass(responder)));
        }
    }
    ((void (*)(id, SEL, id, id))LC32OriginalMovieProxyUpdateContainment)(
        self, cmd, window, superview);
    LC32FitMovieProxyPlaybackView(self, player);
}

void LC32LegacyMovieProxyLayoutSubviews(UIView *self, SEL cmd) {
    if(LC32OriginalMovieProxyLayoutSubviews) {
        ((void (*)(id, SEL))LC32OriginalMovieProxyLayoutSubviews)(self, cmd);
    } else if(LC32MovieProxyClass) {
        struct objc_super sup = {self, class_getSuperclass(LC32MovieProxyClass)};
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, cmd);
    }
    LC32FitMovieProxyPlaybackView(self, nil);
}

void LC32InstallLegacyMovieProxyHook() {
    Class proxyClass = NSClassFromString(@"_MPMoviePlayerProxyView");
    Method update = class_getInstanceMethod(
        proxyClass,
        NSSelectorFromString(@"_updateContainmentInWindow:superview:"));
    if(!proxyClass || !update || LC32OriginalMovieProxyUpdateContainment) return;
    LC32MovieProxyClass = proxyClass;
    LC32OriginalMovieProxyUpdateContainment = method_setImplementation(
        update, (IMP)LC32LegacyMovieProxyUpdateContainment);
    Method layout = class_getInstanceMethod(proxyClass, @selector(layoutSubviews));
    if(layout) {
        if(!class_addMethod(proxyClass, @selector(layoutSubviews),
                (IMP)LC32LegacyMovieProxyLayoutSubviews,
                method_getTypeEncoding(layout))) {
            LC32OriginalMovieProxyLayoutSubviews = method_setImplementation(
                layout, (IMP)LC32LegacyMovieProxyLayoutSubviews);
        }
    }
}

void LC32InstallLegacyMoviePlayerStopHooks() {
    LC32InstallLegacyMovieProxyHook();
    Class playerClass = NSClassFromString(@"MPMoviePlayerController");
    NSString *__strong *finishName = (NSString *__strong *)dlsym(
        RTLD_DEFAULT, "MPMoviePlayerPlaybackDidFinishNotification");
    Method stop = class_getInstanceMethod(playerClass, @selector(stop));
    Method play = class_getInstanceMethod(playerClass, @selector(play));
    Method prepare = class_getInstanceMethod(playerClass,
                                             @selector(prepareToPlay));
    Method init = class_getInstanceMethod(playerClass,
                                          @selector(initWithContentURL:));
    Method post = class_getInstanceMethod(NSNotificationCenter.class,
                                          @selector(postNotification:));
    Method postName = class_getInstanceMethod(NSNotificationCenter.class,
        @selector(postNotificationName:object:userInfo:));
    if(!finishName || !*finishName || !stop || !play || !prepare || !init ||
       !post || !postName) return;
    LC32MoviePlayerDidFinishName = *finishName;
    LC32OriginalMoviePlayerStop = method_setImplementation(
        stop, (IMP)LC32LegacyMoviePlayerStop);
    LC32OriginalMoviePlayerPlay = method_setImplementation(
        play, (IMP)LC32LegacyMoviePlayerPlay);
    LC32OriginalMoviePlayerPrepareToPlay = method_setImplementation(
        prepare, (IMP)LC32LegacyMoviePlayerPrepareToPlay);
    LC32OriginalMoviePlayerInitWithContentURL = method_setImplementation(
        init, (IMP)LC32LegacyMoviePlayerInitWithContentURL);
    LC32OriginalPostNotification = method_setImplementation(
        post, (IMP)LC32LegacyPostNotification);
    LC32OriginalPostNotificationNameObjectUserInfo = method_setImplementation(
        postName, (IMP)LC32LegacyPostNotificationNameObjectUserInfo);
    Method fullscreen = class_getInstanceMethod(playerClass,
        @selector(setFullscreen:));
    Method fullscreenAnimated = class_getInstanceMethod(playerClass,
        @selector(setFullscreen:animated:));
    if(fullscreen && fullscreenAnimated) {
        LC32OriginalMoviePlayerSetFullscreen = method_setImplementation(
            fullscreen, (IMP)LC32LegacyMoviePlayerSetFullscreen);
        LC32OriginalMoviePlayerSetFullscreenAnimated = method_setImplementation(
            fullscreenAnimated, (IMP)LC32LegacyMoviePlayerSetFullscreenAnimated);
    }
}

// The app's own DidFinish handlers run first (they were registered before the
// presentation); an app that dismisses the movie itself leaves nothing to do.
extern "C" void LC32RefitFullScreenRootlessWindowAfterMovie(UIWindow *window);
const void *LC32MovieHelperPresenterKey = &LC32MovieHelperPresenterKey;
// Set around our own auto-dismiss (main thread only).
bool LC32DismissMovieWithoutAnimation;

void LC32DismissMoviePlayerWhenFinished(UIViewController *presenter,
                                        UIViewController *controller) {
    id player = LC32MoviePlayerOfController(controller);
    if(!player || !LC32MoviePlayerDidFinishName) return;
    __block id observer = nil;
    __weak id weakPlayer = player;
    void (^dismiss)(void) = ^{
        objc_setAssociatedObject(weakPlayer, LC32MoviePlayerAutoDismissKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(observer) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            observer = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            /* Usually presenter.presentedViewController; above a previous
             * movie that never went away (LC32PresentMoviePlayerWhenAttached)
             * dismissing from the presenter takes both down. */
            if(!controller.presentingViewController ||
                    controller.isBeingDismissed) return;
            UIViewController *top = presenter.presentedViewController;
            if(top != controller) {
                fprintf(stderr, "LC32: dismissing movie together with "
                    "the %s under it\n", class_getName(object_getClass(top)));
            }
            /* Without animation: on an iOS 27 device the scene can turn
             * (and the game view with it) during the dismiss animation,
             * which cancels it. UIKit then still lists the movie as
             * presented while its view has left the window, and drops
             * every later presentation from this presenter (Air Mail's
             * upsell: audio over black). */
            // The presenter's view leaves the window under a full-screen movie.
            UIWindow *window = controller.viewIfLoaded.window ?:
                presenter.viewIfLoaded.window;
            UIViewController *helper = objc_getAssociatedObject(
                presenter, LC32MovieHelperPresenterKey) ? presenter : nil;
            LC32DismissMovieWithoutAnimation = true;
            ((void (*)(id, SEL))objc_msgSend)(presenter,
                @selector(dismissMoviePlayerViewControllerAnimated));
            LC32DismissMovieWithoutAnimation = false;
            if(helper) [helper.viewIfLoaded removeFromSuperview];
            LC32RefitFullScreenRootlessWindowAfterMovie(window);
        });
    };
    objc_setAssociatedObject(player, LC32MoviePlayerAutoDismissKey, dismiss,
        OBJC_ASSOCIATION_COPY_NONATOMIC);
    observer = [NSNotificationCenter.defaultCenter
        addObserverForName:LC32MoviePlayerDidFinishName object:player queue:nil
        usingBlock:^(NSNotification *) {
            LC32RunMovieAutoDismiss(weakPlayer);
        }];
}

void LC32PresentMoviePlayerWhenAttached(UIViewController *presenter,
                                        UIViewController *controller,
                                        int attempt);

/* UIKit can drop a presentation and only log it (busy presenter, presenter
 * view out of the window). The autoplaying movie is then heard over a black
 * screen, which iOS 5 never did. Present again if the movie is still not up
 * once everything has been quiet for a while: a presentation UIKit merely
 * deferred behind a running transition still goes up by itself (Starfront),
 * and presenting it a second time throws "present modally an active
 * controller". Only the latest movie the app asked for is retried. */
constexpr int LC32PresentVerifyRetries = 2;
constexpr int LC32PresentVerifyQuietChecks = 6;     // 6 x 250 ms
constexpr int LC32PresentVerifyChecks = 60;         // 15 s
constexpr int64_t LC32PresentVerifyDelay = 250 * NSEC_PER_MSEC;
const void *LC32PresentVerifyRetriesKey = &LC32PresentVerifyRetriesKey;
const void *LC32MovieDismissedByAppKey = &LC32MovieDismissedByAppKey;
__weak UIViewController *LC32LatestPresentedMovieController;

bool LC32ControllerChainInTransition(UIViewController *controller) {
    for(UIViewController *c = controller; c; c = c.presentingViewController) {
        if(c.transitionCoordinator || c.isBeingPresented ||
                c.isBeingDismissed) return true;
    }
    return false;
}

void LC32VerifyMoviePresented(UIViewController *presenter,
                              UIViewController *controller, int checks,
                              int quiet) {
    __weak UIViewController *weakPresenter = presenter;
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, LC32PresentVerifyDelay),
            dispatch_get_main_queue(), ^{
        UIViewController *presenter = weakPresenter;
        UIViewController *controller = weakController;
        if(!presenter || !controller ||
                controller != LC32LatestPresentedMovieController) return;
        if(controller.presentingViewController || controller.isBeingPresented ||
                controller.isBeingDismissed ||
                objc_getAssociatedObject(controller, LC32MovieDismissedByAppKey))
            return;
        id player = LC32MoviePlayerOfController(controller);
        if(!player || LC32MoviePlayerWasStopped(player) ||
                objc_getAssociatedObject(player, LC32MoviePlayerFinishedKey))
            return;
        UIWindow *window = presenter.viewIfLoaded.window;
        const bool settled = window && !presenter.presentedViewController &&
            !LC32ControllerChainInTransition(presenter) &&
            !LC32ControllerChainInTransition(window.rootViewController);
        const int nowQuiet = settled ? quiet + 1 : 0;
        if(nowQuiet < LC32PresentVerifyQuietChecks) {
            if(checks + 1 < LC32PresentVerifyChecks) {
                LC32VerifyMoviePresented(presenter, controller, checks + 1,
                                         nowQuiet);
            }
            return;
        }
        NSNumber *retries = objc_getAssociatedObject(controller,
                                                     LC32PresentVerifyRetriesKey);
        fprintf(stderr, "LC32: movie presentation was dropped (retry %d): "
            "presenter=%s %p controller=%p\n", retries.intValue,
            class_getName(object_getClass(presenter)), (__bridge void *)presenter,
            (__bridge void *)controller);
        if(retries.intValue >= LC32PresentVerifyRetries) return;
        objc_setAssociatedObject(controller, LC32PresentVerifyRetriesKey,
            @(retries.intValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LC32PresentMoviePlayerWhenAttached(presenter, controller, 0);
    });
}

/* Present from a plain controller whose (empty) view sits in the game's
 * window: Unity's own controller can be left unable to present (see
 * LC32DismissMoviePlayerWhenFinished). The helper's view is removed once the
 * movie is dismissed. */
void LC32PresentMovieFromHelper(UIViewController *presenter,
                                UIViewController *controller) {
    UIWindow *window = presenter.viewIfLoaded.window;
    UIViewController *helper = [UIViewController new];
    objc_setAssociatedObject(helper, LC32MovieHelperPresenterKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Keep it alive with the movie.
    objc_setAssociatedObject(controller, LC32MovieHelperPresenterKey, helper,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *view = helper.view;
    view.frame = CGRectZero;
    view.userInteractionEnabled = NO;
    [window addSubview:view];
    ((void (*)(id, SEL, id))LC32OriginalPresentMoviePlayerViewController)(
        helper, @selector(presentMoviePlayerViewControllerAnimated:),
        controller);
    id player = LC32MoviePlayerOfController(controller);
    LC32DismissMoviePlayerWhenFinished(helper, controller);
    (void)player;
    LC32LatestPresentedMovieController = controller;
    fprintf(stderr, "LC32: movie from helper: presenting=%d being=%d\n",
        controller.presentingViewController != nil,
        (int)controller.isBeingPresented);
}

void LC32PresentMoviePlayerWhenAttached(UIViewController *presenter,
                                        UIViewController *controller,
                                        int attempt) {
    // The app stopped (and dismissed) this movie while it was still loading.
    if(LC32MoviePlayerWasStopped(LC32MoviePlayerOfController(controller))) {
        return;
    }
    /* Already up (Asphalt 6 presents its intro from both its resume path
     * and the preload notification): old UIKit ignored the second request,
     * current UIKit throws "present modally an active controller". */
    if(controller.presentingViewController || controller.isBeingPresented) {
        return;
    }
    /* The previous movie is still up or still animating away. Unity presents
     * Air Mail's upsell from the logo's DidFinish, while the logo's dismissal
     * (above) is still running; iOS 5 queued that, current UIKit drops the
     * request ("while a presentation or dismiss is in progress") and the
     * autoplaying upsell is only heard, over a black screen. Wait for the
     * transition, and take down a dead movie nobody dismissed. */
    UIViewController *previous = presenter.presentedViewController;
    if(previous && previous != controller) {
        UIViewController *top = previous;
        while(top.presentedViewController) top = top.presentedViewController;
        /* UIKit lists a movie whose view already left the window and that is
         * in no transition: its dismissal was cancelled. Nothing can be
         * presented from this presenter any more; use a fresh one. */
        const bool orphaned = LC32MoviePlayerOfController(top) &&
            !top.viewIfLoaded.window && !top.isBeingDismissed &&
            !top.isBeingPresented && !top.transitionCoordinator &&
            !previous.isBeingDismissed && presenter.viewIfLoaded.window;
        if(orphaned) {
            fprintf(stderr, "LC32: %s is still listed as presented but has "
                "left the window; presenting from a helper\n",
                class_getName(object_getClass(top)));
            [presenter dismissViewControllerAnimated:NO completion:nil];
            LC32PresentMovieFromHelper(presenter, controller);
            return;
        }
        if(attempt < LC32PresentRetryLimit) {
            if(attempt == 0) {
                fprintf(stderr, "LC32: movie present waits for %s%s\n",
                    class_getName(object_getClass(previous)),
                    previous.isBeingDismissed ? " (dismissing)" : "");
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    LC32PresentRetryDelay), dispatch_get_main_queue(), ^{
                LC32PresentMoviePlayerWhenAttached(presenter, controller,
                                                   attempt + 1);
            });
            return;
        }
        /* A finished movie that is still up (its dismissal never completed
         * on an iOS 27 device; a non-animated dismiss did not take it down
         * either): show the next one above it. Dismissing the new movie from
         * the presenter later removes both. */
        if(LC32MoviePlayerOfController(top) && top != controller &&
                !top.isBeingDismissed && !top.isBeingPresented &&
                !top.transitionCoordinator) {
            fprintf(stderr, "LC32: previous movie %s still up after %d ms "
                "(dismissing=%d, window=%p); presenting above it\n",
                class_getName(object_getClass(top)), attempt * 50,
                (int)previous.isBeingDismissed,
                (__bridge void *)top.viewIfLoaded.window);
            ((void (*)(id, SEL, id))LC32OriginalPresentMoviePlayerViewController)(
                top, @selector(presentMoviePlayerViewControllerAnimated:),
                controller);
            id player = LC32MoviePlayerOfController(controller);
            if(!objc_getAssociatedObject(player, LC32MoviePlayerAutoDismissKey)) {
                LC32DismissMoviePlayerWhenFinished(presenter, controller);
            }
            LC32LatestPresentedMovieController = controller;
            fprintf(stderr, "LC32: movie above previous: presenting=%s "
                "being=%d\n", controller.presentingViewController
                    ? class_getName(object_getClass(
                        controller.presentingViewController)) : "nil",
                (int)controller.isBeingPresented);
            return;
        }
        fprintf(stderr, "LC32: presenter still busy after %d ms with %s "
            "(dismissing=%d presenting=%d coordinator=%d); presenting anyway\n",
            attempt * 50, class_getName(object_getClass(top)),
            (int)top.isBeingDismissed, (int)top.isBeingPresented,
            top.transitionCoordinator != nil);
    }
    if(!previous && attempt > 0) {
        fprintf(stderr, "LC32: movie presented after %d ms wait\n",
                attempt * 50);
    }
    if(presenter.viewIfLoaded.window || attempt >= LC32PresentRetryLimit) {
        LC32RecordEmbeddedPresenterGeometry(presenter);
        ((void (*)(id, SEL, id))LC32OriginalPresentMoviePlayerViewController)(
            presenter, @selector(presentMoviePlayerViewControllerAnimated:),
            controller);
        id player = LC32MoviePlayerOfController(controller);
        if(!objc_getAssociatedObject(player, LC32MoviePlayerAutoDismissKey)) {
            LC32DismissMoviePlayerWhenFinished(presenter, controller);
        }
        LC32LatestPresentedMovieController = controller;
        LC32VerifyMoviePresented(presenter, controller, 0, 0);
        LC32RefitFullScreenRootlessWindowAfterMovie(
            presenter.viewIfLoaded.window ?: controller.viewIfLoaded.window);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, LC32PresentRetryDelay),
        dispatch_get_main_queue(), ^{
            LC32PresentMoviePlayerWhenAttached(presenter, controller,
                                               attempt + 1);
        });
}

void LC32LegacyPresentMoviePlayerViewController(UIViewController *self,
                                                SEL, UIViewController *controller) {
    LC32PresentMoviePlayerWhenAttached(self, controller, 0);
}

id LC32LegacyMoviePlayerViewControllerInit(id self, SEL cmd, NSURL *url) {
    id controller = ((id (*)(id, SEL, NSURL *))
        LC32OriginalMoviePlayerViewControllerInit)(self, cmd, url);
    if(!controller) return controller;

    // Presented by the app; never give its player the stand-alone overlay.
    if(id player = LC32MoviePlayerOfController(controller)) {
        objc_setAssociatedObject(player, LC32MoviePlayerOwnedByControllerKey,
            @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    __weak id weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        id player = LC32MoviePlayerOfController(weakController);
        // The app may already have stopped it (e.g. the previous movie's
        // DidFinish handler); loading it now would present a dead movie.
        if(LC32MoviePlayerWasStopped(player)) return;
        if(![player respondsToSelector:@selector(prepareToPlay)] ||
           ![player respondsToSelector:@selector(loadState)]) return;
        // MPMovieLoadStateUnknown: nobody has started loading it yet.
        const NSUInteger loadState =
            ((NSUInteger (*)(id, SEL))objc_msgSend)(
                player, @selector(loadState));
        if(loadState != 0) return;
        // The old shouldAutoplay began playback as soon as the movie loaded;
        // current players only honor it once something asks them to load.
        const BOOL autoplay =
            [player respondsToSelector:@selector(shouldAutoplay)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(
                player, @selector(shouldAutoplay));
        ((void (*)(id, SEL))objc_msgSend)(player,
            autoplay ? @selector(play) : @selector(prepareToPlay));
    });
    return controller;
}

/* iOS 4.3-5 posted DidFinish (UserExited) when an app dismissed a playing
 * MPMoviePlayerViewController. Asphalt 6's Skip button only pauses the movie
 * and dismisses it on 4.3+, then waits for that DidFinish to load its title;
 * current MediaPlayer posts nothing, so the game sat on a black screen. Post
 * it (and stop the player) once, unless the movie already finished. */
IMP LC32OriginalDismissMoviePlayerViewController;

/* The old player stopped, and posted DidFinish, once the dismissal had
 * completed (the movie view had left the screen). Posting while the
 * animated dismissal is still running lets Asphalt 6 start loading its title;
 * the transition's completion then puts the presenter view back into the
 * EAGLView, whose -layoutSubviews redraws the game re-entrantly from inside
 * its loading run-loop pump, and GameSWF asserts (drop_ref). Wait for it. */
constexpr int LC32DismissFinishPollLimit = 60;              // 3 s
constexpr int64_t LC32DismissFinishPollDelay = 50 * NSEC_PER_MSEC;

void LC32ReportDismissedMovieFinished(UIViewController *presenter,
                                      UIViewController *presented,
                                      id player, int attempt) {
    const bool dismissing = presented && (presented.isBeingDismissed ||
        presented.presentingViewController ||
        presenter.presentedViewController == presented ||
        presented.transitionCoordinator);
    if(dismissing && attempt < LC32DismissFinishPollLimit) {
        __weak UIViewController *weakPresenter = presenter;
        __weak UIViewController *weakPresented = presented;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                LC32DismissFinishPollDelay), dispatch_get_main_queue(), ^{
            LC32ReportDismissedMovieFinished(weakPresenter, weakPresented,
                                             player, attempt + 1);
        });
        return;
    }
    // One more turn so the transition's completion work has run too.
    dispatch_async(dispatch_get_main_queue(), ^{
        fprintf(stderr, "LC32: dismissed movie reports DidFinish "
            "(user exited, after %d ms)\n", attempt * 50);
        ((void (*)(id, SEL))LC32OriginalMoviePlayerStop)(
            player, @selector(stop));
        LC32PostMovieDidFinish(player, 2 /* MPMovieFinishReasonUserExited */);
        // Drop the late native DidFinish this -stop may still post.
        LC32SetMoviePlayerStopped(player, true);
    });
}

void LC32LegacyDismissMoviePlayerViewController(UIViewController *self,
                                                SEL cmd) {
    UIViewController *presented = self.presentedViewController;
    id player = LC32MoviePlayerOfController(presented);
    // The app took it down; never present it again (LC32VerifyMoviePresented).
    if(presented) {
        objc_setAssociatedObject(presented, LC32MovieDismissedByAppKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if(LC32DismissMovieWithoutAnimation) {
        [self dismissViewControllerAnimated:NO completion:nil];
    } else {
        ((void (*)(id, SEL))LC32OriginalDismissMoviePlayerViewController)(
            self, cmd);
    }
    if(!player || LC32MoviePlayerWasStopped(player) ||
            objc_getAssociatedObject(player, LC32MoviePlayerFinishedKey))
        return;
    objc_setAssociatedObject(player, LC32MoviePlayerFinishedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LC32ReportDismissedMovieFinished(self, presented, player, 0);
}

/*
 * BioShock's cutscenes (PlaneSequence.m4v, WouldYouKindly.m4v, ...) hold a
 * 1280x720 H.264 stream in a track that says 1279x720, so the decoder hands
 * out 1279-pixel-wide 4:2:0 frames. The iPhone's video display (not the
 * Mac's, so the simulator never shows it) draws such an odd-width YUV frame
 * with a green column along its right edge: the last chroma sample is read
 * past the plane. The decoder's own conversion to BGRA handles the odd width
 * correctly, so ask for BGRA frames wherever a movie with an odd width or
 * height is shown. (A video composition cropping to an even size is no
 * fix: its renderer leaves the same green column at the new edge.)
 */
const void *const LC32OddSizeMovieKey = &LC32OddSizeMovieKey;
IMP LC32OriginalPlayerItemInitWithAssetKeys;
IMP LC32OriginalPlayerLayerSetPlayer;
NSHashTable *LC32MoviePlayerLayers;    // main thread only

id LC32CurrentItemOfLayer(CALayer *layer) {
    id player = ((id (*)(id, SEL))objc_msgSend)(layer, @selector(player));
    return [player respondsToSelector:@selector(currentItem)]
        ? ((id (*)(id, SEL))objc_msgSend)(player, @selector(currentItem)) : nil;
}

void LC32ShowMovieLayerAsRGB(CALayer *layer) {
    static SEL attributes = NSSelectorFromString(@"pixelBufferAttributes");
    static SEL setAttributes = NSSelectorFromString(@"setPixelBufferAttributes:");
    static NSDictionary *rgb = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    if(![layer respondsToSelector:setAttributes]) return;
    id item = LC32CurrentItemOfLayer(layer);
    if(!item || !objc_getAssociatedObject(item, LC32OddSizeMovieKey)) return;
    // AVKit hands its controller's attributes to the layers it makes; set
    // them there too so a layer it builds later gets them as well.
    UIResponder *responder = [layer.delegate isKindOfClass:UIView.class]
        ? (UIView *)layer.delegate : nil;
    while(responder && ![responder respondsToSelector:setAttributes])
        responder = responder.nextResponder;
    for(id target in @[layer, responder ?: layer]) {
        if(((id (*)(id, SEL))objc_msgSend)(target, attributes)) continue;
        ((void (*)(id, SEL, id))objc_msgSend)(target, setAttributes, rgb);
        fprintf(stderr, "LC32: odd-size movie shown as BGRA frames by %s\n",
            class_getName(object_getClass(target)));
    }
}

void LC32PlayerLayerSetPlayer(CALayer *self, SEL cmd, id player) {
    ((void (*)(id, SEL, id))LC32OriginalPlayerLayerSetPlayer)(self, cmd, player);
    if(!player) return;
    __weak CALayer *weakLayer = self;
    dispatch_block_t remember = ^{
        CALayer *layer = weakLayer;
        if(!layer) return;
        if(!LC32MoviePlayerLayers)
            LC32MoviePlayerLayers = [NSHashTable weakObjectsHashTable];
        [LC32MoviePlayerLayers addObject:layer];
        LC32ShowMovieLayerAsRGB(layer);
    };
    if(NSThread.isMainThread) remember();
    else dispatch_async(dispatch_get_main_queue(), remember);
}

void LC32MarkOddSizeMovie(id item, id asset) {
    static SEL loadValues =
        NSSelectorFromString(@"loadValuesAsynchronouslyForKeys:completionHandler:");
    if(![asset respondsToSelector:loadValues]) return;
    __weak id weakItem = item;
    ((void (*)(id, SEL, NSArray *, dispatch_block_t))objc_msgSend)(
            asset, loadValues, @[@"tracks"], ^{
        NSArray *tracks = ((NSArray *(*)(id, SEL, NSString *))objc_msgSend)(
            asset, NSSelectorFromString(@"tracksWithMediaType:"), @"vide");
        id track = tracks.firstObject;
        if(!track) return;
        ((void (*)(id, SEL, NSArray *, dispatch_block_t))objc_msgSend)(
                track, loadValues, @[@"naturalSize", @"preferredTransform"], ^{
            CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(
                track, NSSelectorFromString(@"naturalSize"));
            CGAffineTransform transform =
                ((CGAffineTransform (*)(id, SEL))objc_msgSend)(
                    track, NSSelectorFromString(@"preferredTransform"));
            CGSize shown = CGSizeApplyAffineTransform(size, transform);
            long width = lround(fabs(shown.width));
            long height = lround(fabs(shown.height));
            if(width <= 0 || height <= 0 || (!(width & 1) && !(height & 1)))
                return;
            dispatch_async(dispatch_get_main_queue(), ^{
                id strongItem = weakItem;
                if(!strongItem) return;
                objc_setAssociatedObject(strongItem, LC32OddSizeMovieKey, @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                fprintf(stderr, "LC32: movie frames are %ldx%ld\n",
                    width, height);
                for(CALayer *layer in LC32MoviePlayerLayers.allObjects)
                    if(LC32CurrentItemOfLayer(layer) == strongItem)
                        LC32ShowMovieLayerAsRGB(layer);
            });
        });
    });
}

id LC32PlayerItemInitWithAssetKeys(id self, SEL cmd, id asset, id keys) {
    id item = ((id (*)(id, SEL, id, id))LC32OriginalPlayerItemInitWithAssetKeys)(
        self, cmd, asset, keys);
    if(item && asset) LC32MarkOddSizeMovie(item, asset);
    return item;
}

void LC32InstallOddSizeMovieHooks() {
    if(LC32OriginalPlayerItemInitWithAssetKeys) return;
    const char *enabled = getenv("LC32_ODD_MOVIE_RGB");
    if(enabled && !strcmp(enabled, "0")) return;
    Method init = class_getInstanceMethod(NSClassFromString(@"AVPlayerItem"),
        NSSelectorFromString(@"initWithAsset:automaticallyLoadedAssetKeys:"));
    Method setPlayer = class_getInstanceMethod(
        NSClassFromString(@"AVPlayerLayer"), @selector(setPlayer:));
    if(!init || !setPlayer) return;
    LC32OriginalPlayerLayerSetPlayer = method_setImplementation(
        setPlayer, (IMP)LC32PlayerLayerSetPlayer);
    LC32OriginalPlayerItemInitWithAssetKeys = method_setImplementation(
        init, (IMP)LC32PlayerItemInitWithAssetKeys);
}

void LC32InstallLegacyMoviePlayerHook(const struct mach_header *, intptr_t) {
    // AVFoundation can arrive without MediaPlayer (guests using AVPlayer).
    LC32InstallOddSizeMovieHooks();
    if(LC32LegacyMoviePlayerHookInstalled) return;
    Class controllerClass = NSClassFromString(@"MPMoviePlayerViewController");
    if(!controllerClass) return;
    Method method = class_getInstanceMethod(
        controllerClass, @selector(initWithContentURL:));
    Method present = class_getInstanceMethod(UIViewController.class,
        @selector(presentMoviePlayerViewControllerAnimated:));
    if(!method || !present) return;
    LC32LegacyMoviePlayerHookInstalled = true;
    LC32InstallLegacyMoviePlayerStopHooks();
    LC32InstallLegacyMoviePlayerPlayingNotification();
    LC32OriginalMoviePlayerViewControllerInit = method_setImplementation(
        method, (IMP)LC32LegacyMoviePlayerViewControllerInit);
    LC32OriginalPresentMoviePlayerViewController = method_setImplementation(
        present, (IMP)LC32LegacyPresentMoviePlayerViewController);
    if(Method dismiss = class_getInstanceMethod(UIViewController.class,
            @selector(dismissMoviePlayerViewControllerAnimated))) {
        LC32OriginalDismissMoviePlayerViewController = method_setImplementation(
            dismiss, (IMP)LC32LegacyDismissMoviePlayerViewController);
    }
}
} // namespace

/* Called by the legacy dismissal hook (LegacyAlerts.mm) once UIKit's dismiss
 * transition has run, with the controller that presented the movie. */
extern "C" void LC32RestoreEmbeddedMoviePresenter(
        UIViewController *presenter) {
    UIView *view = LC32NativeViewIfLoaded(presenter);
    if(!view || !objc_getAssociatedObject(
            view, LC32EmbeddedPresenterGeometryKey)) return;
    LC32RestoreEmbeddedPresenterGeometry(view, false);
    // The transition can apply scene geometry again when it completes. In a
    // turned full-screen window that happens later, after its animation;
    // LC32RestoreMoviePresenterAfterTransition finishes there.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSValue *saved = objc_getAssociatedObject(
            view, LC32EmbeddedPresenterGeometryKey);
        LC32EmbeddedPresenterGeometry geometry = {};
        [saved getValue:&geometry size:sizeof(geometry)];
        LC32RestoreEmbeddedPresenterGeometry(view, !geometry.fullScreenWindow);
    });
}

/* Called by UIKit.mm once the legacy transition that brought a presenter's
 * view back into its window has completed. */
extern "C" bool LC32RestoreMoviePresenterAfterTransition(UIView *view) {
    if(!view || !objc_getAssociatedObject(
            view, LC32EmbeddedPresenterGeometryKey)) return false;
    LC32RestoreEmbeddedPresenterGeometry(view, true);
    return true;
}

__attribute__((constructor)) static void LC32RegisterLegacyMoviePlayerHook() {
    // MediaPlayer is loaded only when a guest links it; this callback also
    // runs for every image that is already loaded.
    _dyld_register_func_for_add_image(LC32InstallLegacyMoviePlayerHook);
}
