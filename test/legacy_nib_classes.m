#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <stdio.h>
#include <string.h>

/* Nibs compiled for iOS 6 and earlier name removed private UIKit classes
 * (UIRoundedRectButton). Decoding one must not throw, and the button must
 * reach the guest as a UIButton.
 * usage: legacy_nib_classes <bundle dir> <nib name> (e.g. Tapsonic's BugsDialog) */
@interface LegacyNibOwner : NSObject
@end

@implementation LegacyNibOwner
- (void)setValue:(id)value forUndefinedKey:(NSString *)key {
    printf("outlet %s = %s\n", key.UTF8String, class_getName([value class]));
}
- (void)hideAction:(id)sender {}
@end

static unsigned buttons;

static void dump(UIView *view, int depth) {
    printf("%*s%s\n", depth * 2, "", class_getName([view class]));
    if([view isKindOfClass:[UIButton class]]) {
        buttons++;
        UIButton *button = (UIButton *)view;
        printf("%*s  button type=%ld title=%s\n", depth * 2, "",
            (long)button.buttonType,
            [button titleForState:UIControlStateNormal].UTF8String ?: "(nil)");
    }
    for(UIView *subview in view.subviews) dump(subview, depth + 1);
}

int main(int argc, char **argv) {
    if(argc < 3) {
        fprintf(stderr, "usage: %s <bundle dir> <nib name>\n", argv[0]);
        return 2;
    }
    @autoreleasepool {
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
        NSArray *objects = nil;
        @try {
            objects = [[UINib nibWithNibName:@(argv[2]) bundle:bundle]
                instantiateWithOwner:[LegacyNibOwner new] options:nil];
        } @catch(NSException *exception) {
            printf("FAIL %s: %s\n", exception.name.UTF8String,
                exception.reason.UTF8String);
            return 1;
        }
        for(id object in objects) {
            if([object isKindOfClass:[UIView class]]) dump(object, 0);
            else printf("%s\n", class_getName([object class]));
        }
        printf("%s %lu objects, %u buttons\n",
            objects.count && buttons ? "PASS" : "FAIL",
            (unsigned long)objects.count, buttons);
        return objects.count && buttons ? 0 : 1;
    }
}
