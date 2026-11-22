#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/** One installed 32-bit app in LiveContainer's Applications folder. */
@interface LC32GameEntry : NSObject
/** The .app folder name without ".app"; keys the per-game settings file. */
@property(nonatomic, readonly, copy) NSString *folderName;
@property(nonatomic, readonly, copy) NSString *bundlePath;
@property(nonatomic, readonly, copy) NSString *displayName;
@property(nonatomic, readonly, copy) NSString *bundleIdentifier;
/** LC_VERSION_MIN_IPHONEOS sdk (0x00XXYY00 style, 0 = n/a). */
@property(nonatomic, readonly) uint32_t sdkVersion;
/** LiveExec32-Games/<folderName>.env beside LiveExec32.env. */
@property(nonatomic, readonly, copy) NSString *settingsPath;
/** Values the IPA's Info.plist sets through LC32Environment. */
@property(nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *bundleEnvironment;
@property(nonatomic, readonly, nullable) UIImage *icon;

/** "SDK 6.1" or "SDK n/a". */
- (NSString *)sdkDescription;
/** The screen LC32_ASPECT=original gives this game, in words. */
- (NSString *)originalShapeDescription;
/** NO when LC32_ASPECT cannot change this game (iPad-only, SDK 8+). */
- (BOOL)aspectModeApplies;
@end

@interface LC32GameLibrary : NSObject
/** Folder holding LiveExec32.env (LiveContainer's top folder). */
+ (NSString *)rootForSettingsPath:(NSString *)settingsPath;
/** 32-bit-only apps in <root>/Applications, sorted by name. */
+ (NSArray<LC32GameEntry *> *)gamesForSettingsPath:(NSString *)settingsPath;
@end

NS_ASSUME_NONNULL_END
