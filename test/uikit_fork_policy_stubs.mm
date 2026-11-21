#import <UIKit/UIKit.h>

// Fork-only UIKit.mm policies referenced by LegacyRotation.mm. The native
// rotation fixtures do not use the fixed phone canvas or portrait hosting.
extern "C" bool LC32FullScreenRootlessHostingActive(void) { return false; }
extern "C" void LC32RefitPortraitPhoneCanvasWindowLater(UIWindow *) {}
extern "C" bool LC32UIKitKeepsLegacyScenePortrait(void) { return false; }
