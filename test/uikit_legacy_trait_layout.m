#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* Test double for LiveExec32Shared's guest executable SDK query and guest-class
 * marker. LegacyTraitLayout.mm links directly against these symbols. */
static uint32_t gGuestSDK;

uint32_t LC32GetGuestExecutableSDKVersion(void) {
    return gGuestSDK;
}

@interface NSObject (LC32TraitLayoutTestGuestClass)
- (BOOL)isGuestClass;
@end

@implementation NSObject (LC32TraitLayoutTestGuestClass)
- (BOOL)isGuestClass {
    return NO;
}
@end

@interface TraitGuestEAGLView : UIView
@property (nonatomic) NSUInteger layoutCount;
@property (nonatomic) CGSize lastLayoutSize;
@property (nonatomic) BOOL resizeDuringTraitChange;
@property (nonatomic) BOOL reentrantCallbackRan;
@end

@implementation TraitGuestEAGLView
+ (BOOL)isGuestClass { return YES; }
+ (Class)layerClass { return NSClassFromString(@"CAEAGLLayer"); }
- (void)layoutSubviews {
    self.layoutCount++;
    self.lastLayoutSize = self.bounds.size;
    [super layoutSubviews];
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(self.resizeDuringTraitChange) {
        self.resizeDuringTraitChange = NO;
        self.reentrantCallbackRan = YES;
        CGRect f = self.frame;
        f.size.height -= 10;
        self.frame = f;
    }
}
#pragma clang diagnostic pop
@end

@interface TraitGuestPlainView : UIView
@property (nonatomic) NSUInteger layoutCount;
@end

@implementation TraitGuestPlainView
+ (BOOL)isGuestClass { return YES; }
- (void)layoutSubviews {
    self.layoutCount++;
    [super layoutSubviews];
}
@end

@interface TraitNativeEAGLView : UIView
@property (nonatomic) NSUInteger layoutCount;
@end

@implementation TraitNativeEAGLView
+ (Class)layerClass { return NSClassFromString(@"CAEAGLLayer"); }
- (void)layoutSubviews {
    self.layoutCount++;
    [super layoutSubviews];
}
@end

@interface TraitNativeChildView : UIView
@property (nonatomic) NSUInteger layoutCount;
@end

@implementation TraitNativeChildView
- (void)layoutSubviews {
    self.layoutCount++;
    [super layoutSubviews];
}
@end

static int failures;

static void check(const char *name, BOOL passed) {
    printf("trait-layout-%s: %s\n", name, passed ? "PASS" : "FAIL");
    failures += !passed;
}

static BOOL sameSize(CGSize a, CGSize b) {
    return fabs(a.width - b.width) < 0.01 && fabs(a.height - b.height) < 0.01;
}

static void setWindowStyle(UIWindow *window, UIUserInterfaceStyle style) {
    if(@available(iOS 17.0, *)) {
        window.traitOverrides.userInterfaceStyle = style;
    } else {
        window.overrideUserInterfaceStyle = style;
    }
}

@interface TraitLayoutAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIViewController *ownerController;
@property (nonatomic, strong) TraitGuestEAGLView *glView;
@property (nonatomic, strong) TraitNativeChildView *childView;
@property (nonatomic, strong) TraitGuestPlainView *guestPlainView;
@property (nonatomic, strong) TraitNativeEAGLView *nativeEAGLView;
@end

@implementation TraitLayoutAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;

    NSBundle *bundle = [NSBundle mainBundle];
    gGuestSDK = [[bundle objectForInfoDictionaryKey:@"LC32GuestSDK"] unsignedIntValue];
    BOOL hasFix = [[bundle objectForInfoDictionaryKey:@"LC32HasFix"] boolValue];
    BOOL expectSuppress = [[bundle objectForInfoDictionaryKey:@"LC32ExpectSuppress"] boolValue];
    BOOL expectGLRelayout = [[bundle objectForInfoDictionaryKey:@"LC32ExpectGLRelayout"] boolValue];
    BOOL expectLegacySubtreeInvalidation =
        [[bundle objectForInfoDictionaryKey:@"LC32ExpectLegacySubtreeInvalidation"] boolValue];
    BOOL setRootViewController =
        [[bundle objectForInfoDictionaryKey:@"LC32SetRootViewController"] boolValue];
    BOOL expectPreLayoutCallback =
        [[bundle objectForInfoDictionaryKey:@"LC32ExpectPreLayoutCallback"] boolValue];

    self.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    /* Pin a deterministic starting style so a Dark-mode Simulator cannot make
     * the Light -> Dark stimulus below a no-op. */
    setWindowStyle(self.window, UIUserInterfaceStyleLight);
    if(setRootViewController) {
        self.window.rootViewController = [[UIViewController alloc] init];
    }
    /* Mirror Call of Atlantis Lite: rootless UIWindow with a direct
     * UIViewController-owned EAGLView subview. */
    self.ownerController = [[UIViewController alloc] init];
    self.glView = [[TraitGuestEAGLView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    self.ownerController.view = self.glView;

    self.childView = [[TraitNativeChildView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    [self.glView addSubview:self.childView];

    self.guestPlainView = [[TraitGuestPlainView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    self.nativeEAGLView = [[TraitNativeEAGLView alloc] initWithFrame:CGRectMake(40, 0, 40, 40)];

    [self.window addSubview:self.glView];
    [self.window addSubview:self.guestPlainView];
    [self.window addSubview:self.nativeEAGLView];
    [self.window makeKeyAndVisible];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
        printf("trait-layout-initial: gl=%lu child=%lu plain=%lu nativeGL=%lu hasFix=%d guestSDK=0x%x style=%ld\n",
            (unsigned long)self.glView.layoutCount,
            (unsigned long)self.childView.layoutCount,
            (unsigned long)self.guestPlainView.layoutCount,
            (unsigned long)self.nativeEAGLView.layoutCount,
            hasFix, gGuestSDK, (long)self.glView.traitCollection.userInterfaceStyle);
        check("initial-style-light",
            self.glView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight);
        if(expectSuppress) {
            check("initial-layout-exact-once", self.glView.layoutCount == 1);
        } else {
            check("initial-layout-ran", self.glView.layoutCount >= 1);
        }

        const NSUInteger glBeforeWindowTrait = self.glView.layoutCount;
        const NSUInteger plainBeforeWindowTrait = self.guestPlainView.layoutCount;
        const NSUInteger nativeBeforeWindowTrait = self.nativeEAGLView.layoutCount;

        setWindowStyle(self.window, UIUserInterfaceStyleDark);
        if(@available(iOS 17.0, *)) {
            self.window.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassRegular;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
            const NSUInteger glDelta = self.glView.layoutCount - glBeforeWindowTrait;
            const NSUInteger plainDelta = self.guestPlainView.layoutCount - plainBeforeWindowTrait;
            const NSUInteger nativeDelta = self.nativeEAGLView.layoutCount - nativeBeforeWindowTrait;
            printf("trait-layout-after-window-trait: glDelta=%lu plainDelta=%lu nativeDelta=%lu childStyle=%ld childH=%ld\n",
                (unsigned long)glDelta, (unsigned long)plainDelta, (unsigned long)nativeDelta,
                (long)self.childView.traitCollection.userInterfaceStyle,
                (long)self.childView.traitCollection.horizontalSizeClass);

            if(expectSuppress) {
                check("window-trait-no-gl-relayout", glDelta == 0);
            } else {
                check("window-trait-gl-relayout-passthrough",
                    expectGLRelayout ? glDelta > 0 : glDelta == 0);
            }

            check("native-descendant-observes-style",
                self.childView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
            if(@available(iOS 17.0, *)) {
                check("native-descendant-observes-size-class",
                    self.childView.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular);
            }
            if(expectLegacySubtreeInvalidation) {
                check("non-eagl-guest-view-not-suppressed", plainDelta > 0);
                check("native-eagl-view-not-suppressed", nativeDelta > 0);
            }

            /* Direct trait override on the GL view itself exercises
             * -[UIView _invalidateTraitCollectionAsRoot]. */
            const NSUInteger glBeforeSelfTrait = self.glView.layoutCount;
            self.glView.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                    dispatch_get_main_queue(), ^{
                const NSUInteger selfTraitDelta = self.glView.layoutCount - glBeforeSelfTrait;
                printf("trait-layout-after-self-trait: glDelta=%lu glStyle=%ld\n",
                    (unsigned long)selfTraitDelta,
                    (long)self.glView.traitCollection.userInterfaceStyle);
                check("self-trait-effective-style-light",
                    self.glView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight);
                if(expectSuppress) {
                    check("self-trait-no-gl-relayout", selfTraitDelta == 0);
                }

                /* Clear the local override so subsequent window-style tests
                 * genuinely change glView's effective userInterfaceStyle. */
                self.glView.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                        dispatch_get_main_queue(), ^{
                    check("cleared-override-restores-dark",
                        self.glView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

                    /* Explicit setNeedsLayout must always run. */
                    NSUInteger before = self.glView.layoutCount;
                    [self.glView setNeedsLayout];
                    [self.glView layoutIfNeeded];
                    check("explicit-setNeedsLayout", self.glView.layoutCount == before + 1);

                    /* Bounds/frame resize must always run. */
                    before = self.glView.layoutCount;
                    self.glView.frame = CGRectMake(0, 0, 320, 460);
                    [self.glView layoutIfNeeded];
                    check("frame-resize-layout",
                        self.glView.layoutCount == before + 1 &&
                        sameSize(self.glView.lastLayoutSize, CGSizeMake(320, 460)));

                    /* Hierarchy mutation must always run. */
                    before = self.glView.layoutCount;
                    UIView *extra = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
                    [self.glView addSubview:extra];
                    [self.glView layoutIfNeeded];
                    check("subview-mutation-layout", self.glView.layoutCount == before + 1);

                    /* Mixed order A: explicit setNeedsLayout, then real window
                     * trait transition (Dark -> Light). */
                    before = self.glView.layoutCount;
                    [self.glView setNeedsLayout];
                    setWindowStyle(self.window, UIUserInterfaceStyleLight);
                    [self.glView layoutIfNeeded];
                    check("mixed-explicit-then-trait",
                        self.glView.layoutCount == before + 1 &&
                        self.glView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight);

                    /* Mixed order B: real window trait transition (Light -> Dark),
                     * then explicit setNeedsLayout. */
                    before = self.glView.layoutCount;
                    setWindowStyle(self.window, UIUserInterfaceStyleDark);
                    [self.glView setNeedsLayout];
                    [self.glView layoutIfNeeded];
                    check("mixed-trait-then-explicit",
                        self.glView.layoutCount == before + 1 &&
                        self.glView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

                    /* Let Dark commit before triggering Dark -> Light for the
                     * reentrant pre-layout resize test. */
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                            dispatch_get_main_queue(), ^{
                        if(!expectPreLayoutCallback) {
                            printf("trait-layout-regression: %s\n", failures ? "FAIL" : "PASS");
                            exit(failures ? 1 : 0);
                        }
                        const CGSize expectedSize = CGSizeMake(
                            self.glView.bounds.size.width,
                            self.glView.bounds.size.height - 10);
                        self.glView.reentrantCallbackRan = NO;
                        self.glView.resizeDuringTraitChange = YES;
                        setWindowStyle(self.window, UIUserInterfaceStyleLight);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                                dispatch_get_main_queue(), ^{
                            check("reentrant-callback-ran",
                                self.glView.reentrantCallbackRan);
                            check("reentrant-resize-observed-in-layout",
                                sameSize(self.glView.lastLayoutSize, expectedSize));
                            printf("trait-layout-regression: %s\n", failures ? "FAIL" : "PASS");
                            exit(failures ? 1 : 0);
                        });
                    });
                });
            });
        });
    });
    return YES;
}

@end

int main(int argc, char *argv[]) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass([TraitLayoutAppDelegate class]));
    }
}
