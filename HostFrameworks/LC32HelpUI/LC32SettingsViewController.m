#import "LC32SettingsViewController.h"
#import "LC32EnvFile.h"
#import "LC32GameLibrary.h"
#import "LC32BuiltinGameSettings.h"

typedef NS_ENUM(NSInteger, LC32SettingKind) {
    LC32SettingKindSwitch,
    LC32SettingKindChoice,
};

/* A variable with its own row. Anything else in the file is listed under
 * "Other Variables". */
@interface LC32Setting : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic) LC32SettingKind kind;
// Switch: state when the variable is not set, and the values written.
@property(nonatomic) BOOL defaultOn;
@property(nonatomic) BOOL presenceOnly; // runtime checks only that it is set
@property(nonatomic) BOOL exactOn;      // on only when the value is onValue
@property(nonatomic, copy) NSString *onValue;
@property(nonatomic, copy, nullable) NSString *offValue;
// Choice: title/value pairs; value NSNull = not set (runtime default, or the
// global/IPA value on a game's page).
@property(nonatomic, copy) NSArray<NSArray *> *options;
@end

@implementation LC32Setting
@end

static LC32Setting *LC32SwitchSetting(NSString *key, NSString *title,
        NSString *detail, BOOL defaultOn, BOOL presenceOnly,
        NSString *onValue, NSString *offValue) {
    LC32Setting *setting = [LC32Setting new];
    setting.key = key;
    setting.title = title;
    setting.detail = detail;
    setting.kind = LC32SettingKindSwitch;
    setting.defaultOn = defaultOn;
    setting.presenceOnly = presenceOnly;
    setting.onValue = onValue;
    setting.offValue = offValue;
    return setting;
}

static LC32Setting *LC32ChoiceSetting(NSString *key, NSString *title,
        NSString *detail, NSArray<NSArray *> *options) {
    LC32Setting *setting = [LC32Setting new];
    setting.key = key;
    setting.title = title;
    setting.detail = detail;
    setting.kind = LC32SettingKindChoice;
    setting.options = options;
    return setting;
}

static NSString *const LC32AspectDetail =
    @"3:2 or 16:9, as iOS showed each game on later iPhones.";

static NSString *const LC32ScreenFooter =
    @"Original Aspect Ratio shows each iPhone game in the shape iOS gave it on "
    "later iPhones: 3:2 when it has no iPhone 5 launch image, 16:9 when it has "
    "one, and for iOS 8+ games made for the iPhone 6 a 375×667 screen "
    "(414×736 on the largest phones). Off "
    "keeps LiveExec32's per-game rules, which show some games full screen. A "
    "game can choose otherwise under Per-Game Settings.";

static NSString *const LC32ScaleDetail =
    @"How many pixels per point games render at. 2× is the original Retina "
    "look; 3× is sharper but heavier and can confuse some engines; 1× is "
    "blurry but much cooler. Default: 2× for older games, the screen's own "
    "scale for iOS 8+ games.";

static NSString *const LC32ShapeDetail =
    @"Automatic: LiveExec32's per-game rules. Original: the shape iOS gave "
    "this game (3:2, 16:9, or 375×667 for iOS 8+ games made for the iPhone "
    "6). 16:9: never 3:2, so a 320×568 screen even without an iPhone 5 launch "
    "image, for engines that size themselves from the screen. Full Screen: no "
    "black bars; some games draw for a fixed size and break.";

#pragma mark - Choice list

@interface LC32ChoiceViewController : UITableViewController
@property(nonatomic, strong) LC32Setting *setting;
@property(nonatomic, copy) NSArray<NSArray *> *options;
@property(nonatomic, copy, nullable) NSString *currentValue;
@property(nonatomic, copy) void (^onSelect)(NSString *_Nullable value);
@end

@implementation LC32ChoiceViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.setting.title;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"choice"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.options.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.setting.detail;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"choice"
        forIndexPath:indexPath];
    NSArray *option = self.options[(NSUInteger)indexPath.row];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = option[0];
    cell.contentConfiguration = content;
    id value = option[1];
    BOOL selected = value == NSNull.null ? self.currentValue == nil :
        [self.currentValue isEqualToString:value];
    cell.accessoryType = selected ?
        UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    id value = self.options[(NSUInteger)indexPath.row][1];
    NSString *selected = value == NSNull.null ? nil : value;
    self.currentValue = selected;
    self.onSelect(selected);
    [tableView reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Settings

typedef NS_ENUM(NSInteger, LC32SectionKind) {
    LC32SectionKindAbout,
    LC32SectionKindGames,
    LC32SectionKindSettings,
    LC32SectionKindOther,
    LC32SectionKindReset,
};

@interface LC32SettingsSection : NSObject
@property(nonatomic) LC32SectionKind kind;
@property(nonatomic, copy, nullable) NSString *title;
@property(nonatomic, copy, nullable) NSString *footer;
@property(nonatomic, copy) NSArray<LC32Setting *> *settings;
@end

@implementation LC32SettingsSection
@end

static LC32SettingsSection *LC32Section(LC32SectionKind kind, NSString *title,
        NSString *footer, NSArray<LC32Setting *> *settings) {
    LC32SettingsSection *section = [LC32SettingsSection new];
    section.kind = kind;
    section.title = title;
    section.footer = footer;
    section.settings = settings ?: @[];
    return section;
}

/* The global page's rows; a game's page offers the same keys. */
static NSArray<LC32SettingsSection *> *LC32GlobalSettingSections(void) {
    return @[
        LC32Section(LC32SectionKindSettings, @"Screen", LC32ScreenFooter, @[
            ({
                LC32Setting *aspect = LC32SwitchSetting(@"LC32_ASPECT",
                    @"Original Aspect Ratio", LC32AspectDetail, NO, NO,
                    @"original", nil);
                aspect.exactOn = YES;
                aspect;
            }),
            LC32ChoiceSetting(@"LC32_CANVAS_SCALE", @"Render Scale",
                LC32ScaleDetail,
                @[@[@"Default", NSNull.null], @[@"1× (cooler)", @"1"],
                  @[@"2× (Retina)", @"2"], @[@"3× (sharper)", @"3"]]),
        ]),
        LC32Section(LC32SectionKindSettings, @"Performance", nil, @[
            LC32SwitchSetting(@"LC32_FAST_FP", @"Fast Floating Point",
                @"Starts game threads in the float mode real 32-bit iOS used. "
                "Much faster and cooler; turn off only if a game misbehaves.",
                YES, NO, @"1", @"0"),
            LC32ChoiceSetting(@"LC32_MAX_FPS", @"Frame Rate Cap",
                @"The biggest lever against heat: 30 roughly halves the work "
                "in games that otherwise run at 60.",
                @[@[@"Default", NSNull.null], @[@"30 fps", @"30"],
                  @[@"60 fps", @"60"], @[@"120 fps", @"120"], @[@"No Cap", @"0"]]),
            LC32ChoiceSetting(@"LC32_JIT_CACHE_MB", @"JIT Cache per Thread",
                @"Translated-code cache for each game thread. A bigger cache "
                "can reduce stutter in large games.",
                @[@[@"Default (32 MB)", NSNull.null], @[@"16 MB", @"16"],
                  @[@"64 MB", @"64"], @[@"128 MB", @"128"]]),
        ]),
        LC32Section(LC32SectionKindSettings, @"Diagnostics", nil, @[
            LC32SwitchSetting(@"LC32_PROFILE", @"Performance Profiler",
                @"Logs where each game thread's time goes every 5 seconds. "
                "Costs a little speed.", NO, NO, @"1", nil),
            LC32SwitchSetting(@"LC32_FPS_LOG", @"Frame Rate Log",
                @"Logs the frame rate every 5 seconds.", NO, YES, @"1", nil),
            LC32SwitchSetting(@"LC32_CRASH_STDERR", @"Crash Reports in Log",
                @"Also writes crash reports to the LiveExec32 log.",
                NO, YES, @"1", nil),
        ]),
    ];
}

/* A game's page: every row is a choice whose first option keeps the global
 * (or IPA) value. */
static NSArray<LC32SettingsSection *> *LC32GameSettingSections(void) {
    NSArray *inherit = @[@"Use Global", NSNull.null];
    return @[
        LC32Section(LC32SectionKindSettings, @"Screen", nil, @[
            LC32ChoiceSetting(@"LC32_ASPECT", @"Screen Shape", LC32ShapeDetail,
                @[inherit, @[@"Automatic", @"auto"], @[@"Original", @"original"],
                  @[@"16:9", @"wide"], @[@"Full Screen", @"fill"]]),
            LC32ChoiceSetting(@"LC32_CANVAS_SCALE", @"Render Scale",
                LC32ScaleDetail,
                @[inherit, @[@"1× (cooler)", @"1"], @[@"2× (Retina)", @"2"],
                  @[@"3× (sharper)", @"3"]]),
        ]),
        LC32Section(LC32SectionKindSettings, @"Performance", nil, @[
            LC32ChoiceSetting(@"LC32_MAX_FPS", @"Frame Rate Cap",
                @"30 roughly halves the work in games that otherwise run at 60.",
                @[inherit, @[@"30 fps", @"30"], @[@"60 fps", @"60"],
                  @[@"120 fps", @"120"], @[@"No Cap", @"0"]]),
            LC32ChoiceSetting(@"LC32_FAST_FP", @"Fast Floating Point",
                @"Turn off only if this game misbehaves with it.",
                @[inherit, @[@"On", @"1"], @[@"Off", @"0"]]),
            LC32ChoiceSetting(@"LC32_JIT_CACHE_MB", @"JIT Cache per Thread",
                @"A bigger cache can reduce stutter in large games.",
                @[inherit, @[@"16 MB", @"16"], @[@"32 MB", @"32"],
                  @[@"64 MB", @"64"], @[@"128 MB", @"128"]]),
        ]),
        LC32Section(LC32SectionKindSettings, @"Compatibility",
            @"Device Model is the hw.machine value the game reads. Some games "
            "pick their quality level from it; Real Device turns off "
            "LiveExec32's built-in choice for this game.", @[
            LC32ChoiceSetting(@"LC32_GUEST_MACHINE", @"Device Model",
                @"The model this game is told it runs on. Older models can "
                "unlock a game's quality tiers it does not know newer phones "
                "for.",
                @[@[@"Automatic", NSNull.null], @[@"Real Device", @""],
                  @[@"iPhone 4 (iPhone3,1)", @"iPhone3,1"],
                  @[@"iPhone 4S (iPhone4,1)", @"iPhone4,1"],
                  @[@"iPhone 5 (iPhone5,2)", @"iPhone5,2"],
                  @[@"iPhone 5s (iPhone6,2)", @"iPhone6,2"],
                  @[@"iPhone 6 (iPhone7,2)", @"iPhone7,2"],
                  @[@"iPad 2 (iPad2,1)", @"iPad2,1"],
                  @[@"iPad 4 (iPad3,4)", @"iPad3,4"],
                  @[@"iPad Air (iPad4,1)", @"iPad4,1"]]),
        ]),
    ];
}

static NSString *LC32OptionTitle(LC32Setting *setting, NSString *value) {
    for(NSArray *option in setting.options) {
        id optionValue = option[1];
        if(optionValue != NSNull.null && [optionValue isEqualToString:value]) {
            return option[0];
        }
    }
    return value.length ? value : @"(empty)";
}

/* Short form of one per-game value for the games list. */
static NSString *LC32SummaryForGameValue(NSString *key, NSString *value) {
    if([key isEqualToString:@"LC32_ASPECT"]) {
        NSDictionary *names = @{@"auto": @"Automatic shape",
            @"original": @"Original shape", @"wide": @"16:9",
            @"fill": @"Full screen"};
        return names[value] ?: [@"Shape " stringByAppendingString:value];
    }
    if([key isEqualToString:@"LC32_CANVAS_SCALE"])
        return [NSString stringWithFormat:@"Render %@×", value];
    if([key isEqualToString:@"LC32_MAX_FPS"])
        return [value isEqualToString:@"0"] ? @"No FPS cap"
            : [value stringByAppendingString:@" fps"];
    if([key isEqualToString:@"LC32_FAST_FP"])
        return [value hasPrefix:@"0"] ? @"Fast FP off" : @"Fast FP on";
    if([key isEqualToString:@"LC32_JIT_CACHE_MB"])
        return [NSString stringWithFormat:@"JIT %@ MB", value];
    if([key isEqualToString:@"LC32_GUEST_MACHINE"])
        return value.length ? value : @"Real device";
    return key;
}

@interface LC32GamesViewController : UITableViewController
- (instancetype)initWithSettingsPath:(NSString *)path;
@end

@implementation LC32SettingsViewController {
    LC32EnvFile *_file;
    NSString *_settingsPath;    // the global LiveExec32.env
    LC32EnvFile *_globalFile;   // game page: the global file, for labels
    LC32GameEntry *_game;       // nil on the global page
    NSString *_message;
    NSArray<LC32SettingsSection *> *_sections;
    NSArray<LC32SettingsSection *> *_globalSections;
    NSArray<NSString *> *_otherKeys;
    NSUInteger _gameCount;
}

- (instancetype)initWithSettingsPath:(NSString *)path message:(NSString *)message {
    if((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _settingsPath = [path copy];
        _file = [[LC32EnvFile alloc] initWithPath:path];
        _message = [message copy];
        _globalSections = LC32GlobalSettingSections();
        NSMutableArray *sections = [NSMutableArray array];
        [sections addObject:LC32Section(LC32SectionKindAbout, nil, nil, nil)];
        [sections addObject:LC32Section(LC32SectionKindGames, @"Games",
            @"Give one game its own screen shape, render scale or "
            "performance settings.", nil)];
        [sections addObjectsFromArray:_globalSections];
        [sections addObject:LC32Section(LC32SectionKindOther,
            @"Other Variables", nil, nil)];
        _sections = sections;
    }
    return self;
}

- (instancetype)initWithGame:(LC32GameEntry *)game settingsPath:(NSString *)path {
    if((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _settingsPath = [path copy];
        _game = game;
        _file = [[LC32EnvFile alloc] initWithPath:game.settingsPath];
        _file.headerLines = @[
            [NSString stringWithFormat:@"# LiveExec32 settings for %@ (%@).",
                game.displayName, game.bundleIdentifier],
            @"# Read before LiveExec32.env when this app starts; same format."];
        _globalFile = [[LC32EnvFile alloc] initWithPath:path];
        _globalSections = LC32GlobalSettingSections();
        NSMutableArray *sections = [NSMutableArray array];
        [sections addObject:LC32Section(LC32SectionKindAbout, nil, nil, nil)];
        [sections addObjectsFromArray:LC32GameSettingSections()];
        [sections addObject:LC32Section(LC32SectionKindOther,
            @"Other Variables", nil, nil)];
        [sections addObject:LC32Section(LC32SectionKindReset, nil, nil, nil)];
        _sections = sections;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if(_game) {
        self.title = _game.displayName;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    } else {
        self.title = @"LiveExec32";
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
        self.navigationController.navigationBar.prefersLargeTitles = YES;
    }
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
    [self reloadSettings];
    // The file may be edited in the Files app while LiveExec32 is open.
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(reloadSettings)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if(!_game) {
        _gameCount = [LC32GameLibrary gamesForSettingsPath:_settingsPath].count;
        [self.tableView reloadData];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reloadSettings {
    [_file reload];
    [_globalFile reload];
    [self rebuildOtherKeys];
    [self.tableView reloadData];
}

- (NSArray<LC32Setting *> *)managedSettings {
    NSMutableArray<LC32Setting *> *settings = [NSMutableArray array];
    for(LC32SettingsSection *section in _sections) {
        [settings addObjectsFromArray:section.settings];
    }
    return settings;
}

- (void)rebuildOtherKeys {
    NSMutableSet<NSString *> *managed = [NSMutableSet set];
    for(LC32Setting *setting in [self managedSettings]) [managed addObject:setting.key];
    NSMutableArray<NSString *> *other = [NSMutableArray array];
    for(NSString *key in _file.keys) {
        if(![managed containsObject:key]) [other addObject:key];
    }
    _otherKeys = other;
}

- (void)commit {
    NSError *error = nil;
    if(![_file save:&error]) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Could Not Save"
            message:error.localizedDescription ?: _file.path
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [_file reload];
    }
    [self rebuildOtherKeys];
    [self.tableView reloadData];
}

#pragma mark Setting state

- (BOOL)isOn:(LC32Setting *)setting inFile:(LC32EnvFile *)file {
    if(![file isEnabled:setting.key]) return setting.defaultOn;
    if(setting.presenceOnly) return YES;
    NSString *value = [file valueForKey:setting.key];
    if(setting.exactOn) return [value isEqualToString:setting.onValue];
    return value.length > 0 && ![value hasPrefix:@"0"];
}

- (void)setSetting:(LC32Setting *)setting on:(BOOL)on {
    if(on == setting.defaultOn) {
        // The runtime default needs no line; keep the old one switched off.
        [_file disableKey:setting.key];
    } else {
        [_file setValue:(on ? setting.onValue : setting.offValue)
            forKey:setting.key enabled:YES];
    }
    [self commit];
}

- (nullable NSString *)choiceValue:(LC32Setting *)setting {
    return [_file isEnabled:setting.key] ? [_file valueForKey:setting.key] : nil;
}

- (nullable LC32Setting *)globalSettingForKey:(NSString *)key {
    for(LC32SettingsSection *section in _globalSections) {
        for(LC32Setting *setting in section.settings) {
            if([setting.key isEqualToString:key]) return setting;
        }
    }
    return nil;
}

/* What a game gets for a key it does not set itself: the IPA's own value,
 * else the global page's. */
- (NSString *)inheritedTitle:(LC32Setting *)setting {
    NSString *shipped = _game.bundleEnvironment[setting.key];
    if(shipped) {
        return [NSString stringWithFormat:@"From IPA: %@",
            LC32OptionTitle(setting, shipped)];
    }
    const char *builtin = LC32BuiltinGameSettingValue(
        _game.bundleIdentifier.UTF8String, setting.key.UTF8String);
    if(builtin) {
        return [NSString stringWithFormat:@"Built-in: %@",
            LC32OptionTitle(setting, @(builtin))];
    }
    LC32Setting *global = [self globalSettingForKey:setting.key];
    if(!global) {
        if([_globalFile isEnabled:setting.key]) {
            return [NSString stringWithFormat:@"Use Global: %@",
                LC32OptionTitle(setting, [_globalFile valueForKey:setting.key])];
        }
        return setting.options.firstObject.firstObject;
    }
    NSString *title;
    if(global.kind == LC32SettingKindSwitch) {
        if([setting.key isEqualToString:@"LC32_ASPECT"]) {
            // The global page only switches "original"; the file may say more.
            NSString *value = [_globalFile isEnabled:setting.key]
                ? [_globalFile valueForKey:setting.key] : nil;
            title = value.length ? LC32OptionTitle(setting, value) : @"Automatic";
        } else {
            title = [self isOn:global inFile:_globalFile] ? @"On" : @"Off";
        }
    } else {
        NSString *value = [_globalFile isEnabled:global.key]
            ? [_globalFile valueForKey:global.key] : nil;
        title = value ? LC32OptionTitle(global, value) : global.options[0][0];
    }
    return [NSString stringWithFormat:@"Use Global: %@", title];
}

- (NSArray<NSArray *> *)optionsForSetting:(LC32Setting *)setting {
    if(!_game) return setting.options;
    NSMutableArray<NSArray *> *options = [setting.options mutableCopy];
    for(NSUInteger i = 0; i < options.count; i++) {
        if(options[i][1] == NSNull.null) {
            options[i] = @[[self inheritedTitle:setting], NSNull.null];
        }
    }
    return options;
}

- (NSString *)choiceTitle:(LC32Setting *)setting {
    NSString *value = [self choiceValue:setting];
    for(NSArray *option in [self optionsForSetting:setting]) {
        id optionValue = option[1];
        if(optionValue == NSNull.null ? value == nil : [optionValue isEqualToString:value]) {
            return option[0];
        }
    }
    return value.length ? value : @"(empty)";
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)index {
    LC32SettingsSection *section = _sections[(NSUInteger)index];
    switch(section.kind) {
    case LC32SectionKindAbout:
    case LC32SectionKindGames:
    case LC32SectionKindReset:
        return 1;
    case LC32SectionKindSettings:
        return (NSInteger)section.settings.count;
    case LC32SectionKindOther:
        return (NSInteger)_otherKeys.count + 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)index {
    return _sections[(NSUInteger)index].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)index {
    LC32SettingsSection *section = _sections[(NSUInteger)index];
    if(section.kind == LC32SectionKindReset) {
        return [NSString stringWithFormat:@"Saved to LiveExec32-Games/%@.env "
            "in LiveContainer's folder. Changes apply the next time this app "
            "starts.", _game.folderName];
    }
    if(section.kind != LC32SectionKindOther) return section.footer;
    if(_game) {
        return @"Any LC32_ variable can be set for this game alone; it wins "
            "over the same variable in LiveExec32.env.";
    }
    NSString *location = getenv("LC_HOME_PATH") ?
        @"LiveExec32.env in LiveContainer's folder (Files app: On My iPhone > "
        "LiveContainer)" : _file.path;
    return [NSString stringWithFormat:
        @"Any LC32_ variable can be added here. Switch one off to keep it in "
        "the file without using it; swipe to delete.\n\n"
        "Saved to %@. Changes apply the next time a 32-bit app starts.",
        location];
}

- (UITableViewCell *)aboutCell:(UITableViewCell *)cell {
    UIListContentConfiguration *content = UIListContentConfiguration.subtitleCellConfiguration;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines = 0;
    content.textProperties.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if(!_game) {
        content.text = _message;
        cell.contentConfiguration = content;
        return cell;
    }
    content.text = _game.displayName;
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%@ · %@\n%@",
        _game.bundleIdentifier, [_game sdkDescription],
        [_game originalShapeDescription]];
    if(_game.bundleEnvironment.count) {
        NSMutableArray<NSString *> *pairs = [NSMutableArray array];
        for(NSString *key in [_game.bundleEnvironment.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            [pairs addObject:[NSString stringWithFormat:@"%@=%@", key,
                _game.bundleEnvironment[key]]];
        }
        [detail appendFormat:@"\nThis IPA sets %@ unless overridden here.",
            [pairs componentsJoinedByString:@", "]];
    }
    content.secondaryText = detail;
    if(_game.icon) {
        content.image = _game.icon;
        content.imageProperties.maximumSize = CGSizeMake(57, 57);
        content.imageProperties.cornerRadius = 12;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"
        forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    LC32SettingsSection *section = _sections[(NSUInteger)indexPath.section];
    UIListContentConfiguration *content = UIListContentConfiguration.subtitleCellConfiguration;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines = 0;

    switch(section.kind) {
    case LC32SectionKindAbout:
        return [self aboutCell:cell];
    case LC32SectionKindGames:
        content = UIListContentConfiguration.valueCellConfiguration;
        content.text = @"Per-Game Settings";
        content.secondaryText = [NSString stringWithFormat:@"%lu",
            (unsigned long)_gameCount];
        cell.contentConfiguration = content;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    case LC32SectionKindReset:
        content = cell.defaultContentConfiguration;
        content.text = @"Reset to Global Settings";
        content.textProperties.color = UIColor.systemRedColor;
        content.textProperties.alignment = UIListContentTextAlignmentCenter;
        cell.contentConfiguration = content;
        return cell;
    case LC32SectionKindOther:
        break;
    case LC32SectionKindSettings: {
        LC32Setting *setting = section.settings[(NSUInteger)indexPath.row];
        if(setting.kind == LC32SettingKindChoice) {
            content = UIListContentConfiguration.valueCellConfiguration;
            content.text = setting.title;
            content.secondaryText = [self choiceTitle:setting];
            cell.contentConfiguration = content;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        content.text = setting.title;
        content.secondaryText = setting.detail;
        cell.contentConfiguration = content;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self isOn:setting inFile:_file];
        toggle.accessibilityLabel = setting.title;
        __weak typeof(self) weakSelf = self;
        [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
            [weakSelf setSetting:setting on:((UISwitch *)action.sender).on];
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }
    }

    if((NSUInteger)indexPath.row == _otherKeys.count) {
        content = cell.defaultContentConfiguration;
        content.text = @"Add Variable…";
        content.textProperties.color = self.view.tintColor;
        cell.contentConfiguration = content;
        return cell;
    }
    NSString *key = _otherKeys[(NSUInteger)indexPath.row];
    NSString *value = [_file valueForKey:key];
    content.text = key;
    content.textProperties.font = [UIFont monospacedSystemFontOfSize:
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].pointSize
        weight:UIFontWeightRegular];
    content.secondaryText = value.length ? value : @"(empty)";
    cell.contentConfiguration = content;
    UISwitch *toggle = [UISwitch new];
    toggle.on = [_file isEnabled:key];
    toggle.accessibilityLabel = key;
    __weak typeof(self) weakSelf = self;
    [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf) return;
        UISwitch *sender = (UISwitch *)action.sender;
        if(sender.on) {
            [strongSelf->_file setValue:[strongSelf->_file valueForKey:key] ?: @""
                forKey:key enabled:YES];
        } else {
            [strongSelf->_file disableKey:key];
        }
        [strongSelf commit];
    }] forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LC32SettingsSection *section = _sections[(NSUInteger)indexPath.section];
    switch(section.kind) {
    case LC32SectionKindAbout:
        return;
    case LC32SectionKindGames:
        [self.navigationController pushViewController:
            [[LC32GamesViewController alloc] initWithSettingsPath:_settingsPath]
            animated:YES];
        return;
    case LC32SectionKindReset:
        [self confirmReset];
        return;
    case LC32SectionKindOther: {
        NSString *key = (NSUInteger)indexPath.row < _otherKeys.count ?
            _otherKeys[(NSUInteger)indexPath.row] : nil;
        [self editVariable:key];
        return;
    }
    case LC32SectionKindSettings:
        break;
    }
    LC32Setting *setting = section.settings[(NSUInteger)indexPath.row];
    if(setting.kind != LC32SettingKindChoice) return;
    LC32ChoiceViewController *choice = [[LC32ChoiceViewController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    choice.setting = setting;
    choice.options = [self optionsForSetting:setting];
    choice.currentValue = [self choiceValue:setting];
    __weak typeof(self) weakSelf = self;
    choice.onSelect = ^(NSString *value) {
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf) return;
        if(value) {
            [strongSelf->_file setValue:value forKey:setting.key enabled:YES];
        } else if(strongSelf->_game) {
            // A game page keeps no switched-off lines: unset means inherit.
            [strongSelf->_file removeKey:setting.key];
        } else {
            [strongSelf->_file disableKey:setting.key];
        }
        [strongSelf commit];
    };
    [self.navigationController pushViewController:choice animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return _sections[(NSUInteger)indexPath.section].kind == LC32SectionKindOther &&
        (NSUInteger)indexPath.row < _otherKeys.count;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
        forRowAtIndexPath:(NSIndexPath *)indexPath {
    if(editingStyle != UITableViewCellEditingStyleDelete) return;
    [_file removeKey:_otherKeys[(NSUInteger)indexPath.row]];
    [self commit];
}

- (void)confirmReset {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset to Global Settings?"
        message:[NSString stringWithFormat:@"Removes every setting made for "
            "%@ alone. Values its IPA sets still apply.", _game.displayName]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf) return;
        [NSFileManager.defaultManager removeItemAtPath:strongSelf->_file.path
            error:nil];
        [strongSelf reloadSettings];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Add / edit

- (void)editVariable:(nullable NSString *)existingKey {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:existingKey ? @"Edit Variable" : @"Add Variable"
        message:@"Name must start with LC32_. The variable is switched on when saved."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"LC32_NAME";
        field.text = existingKey ?: @"LC32_";
        field.keyboardType = UIKeyboardTypeASCIICapable;
        field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
        field.font = [UIFont monospacedSystemFontOfSize:UIFont.systemFontSize
            weight:UIFontWeightRegular];
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"value";
        field.text = existingKey ? [self->_file valueForKey:existingKey] : @"1";
        field.keyboardType = UIKeyboardTypeASCIICapable;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
        field.font = [UIFont monospacedSystemFontOfSize:UIFont.systemFontSize
            weight:UIFontWeightRegular];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf) return;
        NSCharacterSet *spaces = NSCharacterSet.whitespaceCharacterSet;
        NSString *key = [[weakAlert.textFields[0].text
            stringByTrimmingCharactersInSet:spaces] uppercaseString];
        NSString *value = [weakAlert.textFields[1].text
            stringByTrimmingCharactersInSet:spaces] ?: @"";
        if(![LC32EnvFile isValidKey:key] || ![LC32EnvFile isValidValue:value]) {
            UIAlertController *invalid = [UIAlertController
                alertControllerWithTitle:@"Not Saved"
                message:@"Use a name like LC32_MAX_FPS (capital letters, digits "
                    "and _) and a value without # or line breaks."
                preferredStyle:UIAlertControllerStyleAlert];
            [invalid addAction:[UIAlertAction actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:invalid animated:YES completion:nil];
            return;
        }
        if(existingKey && ![existingKey isEqualToString:key]) {
            [strongSelf->_file removeKey:existingKey];
        }
        [strongSelf->_file setValue:value forKey:key enabled:YES];
        [strongSelf commit];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Games

@implementation LC32GamesViewController {
    NSString *_settingsPath;
    NSArray<LC32GameEntry *> *_games;
}

- (instancetype)initWithSettingsPath:(NSString *)path {
    if((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _settingsPath = [path copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Per-Game Settings";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"game"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _games = [LC32GameLibrary gamesForSettingsPath:_settingsPath];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_games.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(!_games.count) {
        return @"No 32-bit apps found in LiveContainer's Applications folder "
            "(the one LiveExec32 is installed in).";
    }
    return @"32-bit apps installed next to LiveExec32. Settings made here "
        "apply to that app only and win over the main page.";
}

- (NSString *)summaryForGame:(LC32GameEntry *)game {
    LC32EnvFile *file = [[LC32EnvFile alloc] initWithPath:game.settingsPath];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for(NSString *key in file.keys) {
        if(![file isEnabled:key]) continue;
        [parts addObject:LC32SummaryForGameValue(key, [file valueForKey:key])];
    }
    for(NSString *key in game.bundleEnvironment) {
        if([file isEnabled:key]) continue;
        [parts addObject:[NSString stringWithFormat:@"IPA: %@",
            LC32SummaryForGameValue(key, game.bundleEnvironment[key])]];
    }
    for(unsigned i = 0; i < sizeof(LC32BuiltinGameSettings) /
            sizeof(LC32BuiltinGameSettings[0]); i++) {
        const LC32BuiltinGameSetting *builtin = &LC32BuiltinGameSettings[i];
        NSString *key = @(builtin->key);
        if(![game.bundleIdentifier isEqualToString:@(builtin->bundleIdentifier)] ||
                [file isEnabled:key] || game.bundleEnvironment[key]) continue;
        [parts addObject:[NSString stringWithFormat:@"Built-in: %@",
            LC32SummaryForGameValue(key, @(builtin->value))]];
    }
    return parts.count ? [parts componentsJoinedByString:@" · "]
        : @"Global settings";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"game"
        forIndexPath:indexPath];
    LC32GameEntry *game = _games[(NSUInteger)indexPath.row];
    UIListContentConfiguration *content = UIListContentConfiguration.subtitleCellConfiguration;
    content.text = game.displayName;
    content.secondaryText = [self summaryForGame:game];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.image = game.icon ?: [UIImage systemImageNamed:@"gamecontroller"];
    content.imageProperties.maximumSize = CGSizeMake(40, 40);
    content.imageProperties.reservedLayoutSize = CGSizeMake(40, 40);
    content.imageProperties.cornerRadius = 9;
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LC32SettingsViewController *settings = [[LC32SettingsViewController alloc]
        initWithGame:_games[(NSUInteger)indexPath.row] settingsPath:_settingsPath];
    [self.navigationController pushViewController:settings animated:YES];
}

@end
