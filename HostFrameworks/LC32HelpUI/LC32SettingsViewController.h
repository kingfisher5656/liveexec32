#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/** LiveExec32's launcher screen: what the app is for plus LiveExec32.env switches. */
@interface LC32SettingsViewController : UITableViewController
- (instancetype)initWithSettingsPath:(NSString *)path message:(NSString *)message;
@end

NS_ASSUME_NONNULL_END
