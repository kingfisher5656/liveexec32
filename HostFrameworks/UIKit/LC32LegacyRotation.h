#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Restore pre-iOS-8 guest rotation queries/callbacks and the native legacy
 * backing-layer setup, independently of modern-host canvas compensation. */
bool LC32NativeLegacyRotationEnabled(void);
void LC32PrepareNativeLegacyRotationClass(Class cls);
bool LC32NativeLegacyRotationStartupSceneReady(void);
id LC32LegacyStartupDisplayLinkTarget(id target, SEL *action);
void LC32FinishNativeLegacyRotationStartup(void);

/* Supplied by the emulator: native layout callbacks can arrive before the
 * guest renderer is initialized or on a thread without a guest CPU context. */
BOOL LC32NativeLegacyRotationCanCallGuest(void);
/* Resolve an emulator-owned canvas container without exposing it to guests. */
UIViewController *LC32NativeLegacyRotationContentController(UIViewController *controller);
/* Deliver the deprecated will/did pair for a scene rotation that UIKit only
 * reported to the native root (viewWillTransitionToSize:). */
void LC32NativeLegacyRotationWillRotate(UIViewController *root,
    UIInterfaceOrientation orientation, NSTimeInterval duration);
void LC32NativeLegacyRotationDidRotate(UIViewController *root,
    UIInterfaceOrientation fromOrientation);
/* Re-run the device-orientation rotation after the allowed sides changed. */
void LC32NativeLegacyRotationFollowDevice(void);

#ifdef __cplusplus
}
#endif
