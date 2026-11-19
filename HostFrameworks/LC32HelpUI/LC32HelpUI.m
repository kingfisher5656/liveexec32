#import <UIKit/UIKit.h>
#import "LC32HelpUI.h"
#import "LC32EnvFile.h"
#import "LC32SettingsViewController.h"

static NSString *LC32LauncherExecutablePath;

static void LC32ShowLauncherWindow(UIWindow *window) {
    NSString *message;
    if (!getenv("LC_HOME_PATH")) {
        message = @"LiveExec32 app requires to be installed inside LiveContainer.";
    } else {
        message = @"LiveExec32 is an 32-bit emulation layer for modern iOS. "
        "To use 32-bit apps, set LiveExec32 as default and launch your app from LiveContainer.";
    }
    NSString *path = [LC32EnvFile
        defaultPathForExecutable:LC32LauncherExecutablePath];
    LC32SettingsViewController *settings = [[LC32SettingsViewController alloc]
        initWithSettingsPath:path message:message];
    window.rootViewController = [[UINavigationController alloc]
        initWithRootViewController:settings];
    [window makeKeyAndVisible];
}

API_AVAILABLE(ios(13.0))
@interface LC32HelpSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation LC32HelpSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
    options:(UISceneConnectionOptions *)connectionOptions {
    (void)session;
    (void)connectionOptions;
    if(![scene isKindOfClass:UIWindowScene.class]) return;

    self.window = [[UIWindow alloc]
        initWithWindowScene:(UIWindowScene *)scene];
    LC32ShowLauncherWindow(self.window);
}

@end

@interface LC32HelpAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation LC32HelpAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;

    /*
     * Do not opt the bundle into scenes in Info.plist. This executable also
     * hosts guest UIApplicationMain calls, and bundle-wide scene routing
     * would replace their application delegates. The scene delegate above is
     * ready for a future launcher-only scene configuration.
     */
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    LC32ShowLauncherWindow(self.window);
    return YES;
}


- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
    options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0)) {
    UISceneConfiguration *config = [UISceneConfiguration
        configurationWithName:@"Default Configuration"
        sessionRole:connectingSceneSession.role];
    config.delegateClass = LC32HelpSceneDelegate.class;
    return config;
}

@end

int LC32RunHelpUI(int argc, char *argv[]) {
    @autoreleasepool {
        if(argc > 0 && argv != NULL && argv[0] != NULL) {
            LC32LauncherExecutablePath = @(argv[0]);
        }
        return UIApplicationMain(
            argc, argv, nil,
            NSStringFromClass(LC32HelpAppDelegate.class));
    }
}
