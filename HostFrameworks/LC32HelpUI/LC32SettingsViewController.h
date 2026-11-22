#import <UIKit/UIKit.h>

@class LC32GameEntry;

NS_ASSUME_NONNULL_BEGIN

/** LiveExec32's launcher screen: what the app is for plus LiveExec32.env
 * switches, and one game's own settings page (LiveExec32-Games/<app>.env). */
@interface LC32SettingsViewController : UITableViewController
- (instancetype)initWithSettingsPath:(NSString *)path message:(NSString *)message;
/** path is the global LiveExec32.env, shown as what the game inherits. */
- (instancetype)initWithGame:(LC32GameEntry *)game settingsPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
