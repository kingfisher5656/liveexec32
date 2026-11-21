#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
typedef NSInteger UIInterfaceOrientation;
@interface UIViewController : NSObject
@end
@interface UIWindow : NSObject
- (instancetype)initWithFrame:(CGRect)frame;
@property(nonatomic) CGRect frame;
@property(nonatomic) CGRect bounds;
@end
@interface UIScreenMode : NSObject
@property(nonatomic) CGSize pixels;
@property(nonatomic) CGSize applicationPixels;
@property(nonatomic) NSInteger lastLevel;
- (CGSize)size;
@end
@interface UIScreen : NSObject
+ (instancetype)mainScreen;
@property(nonatomic) CGFloat testScale;
@property(nonatomic, strong) UIScreenMode *currentMode;
@property(nonatomic, copy) NSArray<UIScreenMode *> *availableModes;
- (CGFloat)scale;
@property(nonatomic) CGFloat nativeScale;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGRect applicationFrame;
@end
