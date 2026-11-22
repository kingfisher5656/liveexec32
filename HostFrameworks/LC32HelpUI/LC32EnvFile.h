#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Editor for LiveExec32.env, the LC32_* settings file LiveExec32Shared reads
 * when a guest starts (LoadUserEnvironmentFile). A line "LC32_NAME=value" is
 * an enabled variable; "#LC32_NAME=value" is the same variable switched off.
 * Every other line (comments, blank lines) is kept as written.
 */
@interface LC32EnvFile : NSObject

@property(nonatomic, readonly, copy) NSString *path;

/** LiveContainer's top folder (next to Applications/), else Documents. */
+ (NSString *)defaultPathForExecutable:(nullable NSString *)executablePath;

+ (BOOL)isValidKey:(NSString *)key;
+ (BOOL)isValidValue:(NSString *)value;

/** Comment lines written when saving a file that has no lines yet. */
@property(nonatomic, copy, nullable) NSArray<NSString *> *headerLines;

- (instancetype)initWithPath:(NSString *)path;
/** YES when at least one variable is switched on. */
- (BOOL)hasEnabledEntries;
- (void)reload;
- (BOOL)save:(NSError **)error;

/** Variable names in file order, each once. */
- (NSArray<NSString *> *)keys;
- (BOOL)hasKey:(NSString *)key;
/** YES when an uncommented line sets the key (the value the runtime uses). */
- (BOOL)isEnabled:(NSString *)key;
/** The enabled value, else the value of the first switched-off line. */
- (nullable NSString *)valueForKey:(NSString *)key;

/** Sets the value; enabled NO writes it as a switched-off line. */
- (void)setValue:(NSString *)value forKey:(NSString *)key enabled:(BOOL)enabled;
/** Switches every enabled line of the key off, keeping its value. */
- (void)disableKey:(NSString *)key;
- (void)removeKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
