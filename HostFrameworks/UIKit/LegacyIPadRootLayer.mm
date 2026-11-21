// iPad hosts: keep pre-iOS-8 window rotation visible.
//
// With the process SDK below 8 (LiveContainer spoofs the guest's SDK), UIKit
// rotates every window the iOS 6 way: the window keeps portrait screen bounds
// and -[UIWindow _updateTransformLayer] puts the quarter turn on the window's
// topmost layer (the root of its render context). iPadOS ignores that root
// layer's transform and position and stretches its portrait bounds over the
// landscape scene, so the whole app shows sideways and squashed (Tapsonic on
// iPad, simulator and device). iPhones honour the turn and are left alone.
//
// After UIKit updates the transform layers, move the turn one level down:
// the root gets the scene-sized landscape bounds and no transform, and each
// of its sublayers carries the turn instead. Geometry, hit testing and
// coordinate conversion through the layer tree stay equivalent.
// LC32_IPAD_ROOT_TURN=0 turns this off.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

#include "LC32LegacyRotation.h"

#if LC32_UIKIT_COMPATIBILITY

namespace {

struct LayerBase {
    CATransform3D transform;
    CGPoint position;
};

char LayerBaseKey;
char LayerAppliedKey;
void (*OriginalUpdateTransformLayer)(id, SEL);

bool RootTurnEnabled(void) {
    static const bool enabled = [] {
        const char *value = getenv("LC32_IPAD_ROOT_TURN");
        if(value && strcmp(value, "0") == 0) return false;
        return UIDevice.currentDevice.userInterfaceIdiom !=
            UIUserInterfaceIdiomPhone;
    }();
    return enabled;
}

/* The values UIKit last gave this sublayer: ours are recognised by the
 * transform we applied, so a repeated update never turns it twice. */
LayerBase SublayerBase(CALayer *layer) {
    LayerBase base = {layer.transform, layer.position};
    NSValue *applied = objc_getAssociatedObject(layer, &LayerAppliedKey);
    NSValue *stored = objc_getAssociatedObject(layer, &LayerBaseKey);
    if(applied && stored) {
        CATransform3D appliedTransform;
        [applied getValue:&appliedTransform];
        if(CATransform3DEqualToTransform(appliedTransform, base.transform))
            [stored getValue:&base];
    }
    return base;
}

void MoveRootTurnDown(UIWindow *window) {
    CALayer *root = window.layer;
    while(root.superlayer) root = root.superlayer;
    if(root == window.layer) return;
    const CATransform3D turn = root.transform;
    if(CATransform3DIsIdentity(turn) || !CATransform3DIsAffine(turn)) return;

    const CGAffineTransform affine = CATransform3DGetAffineTransform(turn);
    const CGRect bounds = root.bounds;
    const CGSize slot = CGRectApplyAffineTransform(
        CGRectMake(0, 0, bounds.size.width, bounds.size.height),
        CGAffineTransformMake(affine.a, affine.b, affine.c, affine.d, 0, 0))
        .size;
    if(!(slot.width > 0) || !(slot.height > 0)) return;
    const CGAffineTransform linear =
        CGAffineTransformMake(affine.a, affine.b, affine.c, affine.d, 0, 0);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for(CALayer *child in root.sublayers) {
        const LayerBase base = SublayerBase(child);
        const CGPoint offset = CGPointApplyAffineTransform(
            CGPointMake(base.position.x - CGRectGetMidX(bounds),
                        base.position.y - CGRectGetMidY(bounds)),
            linear);
        CATransform3D moved = CATransform3DConcat(base.transform, turn);
        moved.m41 = base.transform.m41;
        moved.m42 = base.transform.m42;
        objc_setAssociatedObject(child, &LayerBaseKey,
            [NSValue value:&base withObjCType:@encode(LayerBase)],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(child, &LayerAppliedKey,
            [NSValue valueWithCATransform3D:moved],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        child.transform = moved;
        child.position = CGPointMake(slot.width * 0.5 + offset.x + affine.tx,
                                     slot.height * 0.5 + offset.y + affine.ty);
    }
    const CGPoint position = root.position;
    root.transform = CATransform3DIdentity;
    root.bounds = CGRectMake(0, 0, slot.width, slot.height);
    root.position = position;
    [CATransaction commit];
}

void UpdateTransformLayer(UIWindow *self, SEL _cmd) {
    OriginalUpdateTransformLayer(self, _cmd);
    if(RootTurnEnabled()) MoveRootTurnDown(self);
}

} // namespace

@interface UIWindow (LC32LegacyIPadRootLayer)
@end

@implementation UIWindow (LC32LegacyIPadRootLayer)

+ (void)load {
    if(!LC32NativeLegacyRotationEnabled()) return;
    Method method = class_getInstanceMethod(self,
        NSSelectorFromString(@"_updateTransformLayer"));
    if(!method) return;
    OriginalUpdateTransformLayer = (void (*)(id, SEL))
        method_setImplementation(method, (IMP)UpdateTransformLayer);
}

@end

#endif // LC32_UIKIT_COMPATIBILITY
