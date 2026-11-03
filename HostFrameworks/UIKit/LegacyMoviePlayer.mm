#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include "LiveExec32Shared.h"

/* UIKit.mm: a renderer straight in a turned full-screen rootless window. */
extern "C" bool LC32ViewIsInTurnedFullScreenRootlessWindow(UIView *view);

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

void LC32LegacyMoviePlayerStop(id self, SEL cmd) {
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

void LC32LegacyMoviePlayerPlay(id self, SEL cmd) {
    LC32SetMoviePlayerStopped(self, false);
    // An explicit -play replaces the one-shot autoplay.
    objc_setAssociatedObject(self, LC32MoviePlayerAutoplayedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, LC32MoviePlayerPlayingPostedKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL))LC32OriginalMoviePlayerPlay)(self, cmd);
}

void LC32LegacyMoviePlayerPrepareToPlay(id self, SEL cmd) {
    LC32SetMoviePlayerStopped(self, false);
    objc_setAssociatedObject(self, LC32MoviePlayerPlayingPostedKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL))LC32OriginalMoviePlayerPrepareToPlay)(self, cmd);
}

bool LC32ShouldDropMovieNotification(NSString *name, id object) {
    return name && (name == LC32MoviePlayerDidFinishName ||
                    [name isEqualToString:LC32MoviePlayerDidFinishName]) &&
        LC32MoviePlayerWasStopped(object);
}

void LC32LegacyPostNotification(NSNotificationCenter *self, SEL cmd,
                                NSNotification *note) {
    if(LC32ShouldDropMovieNotification(note.name, note.object)) return;
    ((void (*)(id, SEL, id))LC32OriginalPostNotification)(self, cmd, note);
}

void LC32LegacyPostNotificationNameObjectUserInfo(NSNotificationCenter *self,
        SEL cmd, NSNotificationName name, id object, NSDictionary *userInfo) {
    if(LC32ShouldDropMovieNotification(name, object)) return;
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

void LC32InstallLegacyMoviePlayerPlayingNotification() {
    NSString *__strong *stateName = (NSString *__strong *)dlsym(
        RTLD_DEFAULT, "MPMoviePlayerPlaybackStateDidChangeNotification");
    NSString *__strong *loadName = (NSString *__strong *)dlsym(
        RTLD_DEFAULT, "MPMoviePlayerLoadStateDidChangeNotification");
    if(!stateName || !*stateName || !loadName || !*loadName) return;
    LC32MoviePlayerStateChangeName = *stateName;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
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
                LC32AutoplayWhenPlayable(weakPlayer);
                LC32PostPlayingWhenStarted(weakPlayer, 0);
            });
        }];
}

void LC32InstallLegacyMoviePlayerStopHooks() {
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
}

// The app's own DidFinish handlers run first (they were registered before the
// presentation); an app that dismisses the movie itself leaves nothing to do.
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
            if(presenter.presentedViewController != controller ||
                    controller.isBeingDismissed) return;
            ((void (*)(id, SEL))objc_msgSend)(presenter,
                @selector(dismissMoviePlayerViewControllerAnimated));
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
                                        int attempt) {
    // The app stopped (and dismissed) this movie while it was still loading.
    if(LC32MoviePlayerWasStopped(LC32MoviePlayerOfController(controller))) {
        return;
    }
    if(presenter.viewIfLoaded.window || attempt >= LC32PresentRetryLimit) {
        LC32RecordEmbeddedPresenterGeometry(presenter);
        ((void (*)(id, SEL, id))LC32OriginalPresentMoviePlayerViewController)(
            presenter, @selector(presentMoviePlayerViewControllerAnimated:),
            controller);
        LC32DismissMoviePlayerWhenFinished(presenter, controller);
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

void LC32InstallLegacyMoviePlayerHook(const struct mach_header *, intptr_t) {
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
