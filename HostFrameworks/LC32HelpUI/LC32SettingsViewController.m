#import "LC32SettingsViewController.h"
#import "LC32EnvFile.h"

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
@property(nonatomic, copy) NSString *onValue;
@property(nonatomic, copy, nullable) NSString *offValue;
// Choice: title/value pairs; value NSNull = not set (runtime default).
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

#pragma mark - Choice list

@interface LC32ChoiceViewController : UITableViewController
@property(nonatomic, strong) LC32Setting *setting;
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
    return (NSInteger)self.setting.options.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.setting.detail;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"choice"
        forIndexPath:indexPath];
    NSArray *option = self.setting.options[(NSUInteger)indexPath.row];
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
    id value = self.setting.options[(NSUInteger)indexPath.row][1];
    NSString *selected = value == NSNull.null ? nil : value;
    self.currentValue = selected;
    self.onSelect(selected);
    [tableView reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Settings

typedef NS_ENUM(NSInteger, LC32Section) {
    LC32SectionAbout,
    LC32SectionPerformance,
    LC32SectionDiagnostics,
    LC32SectionOther,
    LC32SectionCount,
};

@implementation LC32SettingsViewController {
    LC32EnvFile *_file;
    NSString *_message;
    NSArray<LC32Setting *> *_performance;
    NSArray<LC32Setting *> *_diagnostics;
    NSArray<NSString *> *_otherKeys;
}

- (instancetype)initWithSettingsPath:(NSString *)path message:(NSString *)message {
    if((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _file = [[LC32EnvFile alloc] initWithPath:path];
        _message = [message copy];
        _performance = @[
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
        ];
        _diagnostics = @[
            LC32SwitchSetting(@"LC32_PROFILE", @"Performance Profiler",
                @"Logs where each game thread's time goes every 5 seconds. "
                "Costs a little speed.", NO, NO, @"1", nil),
            LC32SwitchSetting(@"LC32_FPS_LOG", @"Frame Rate Log",
                @"Logs the frame rate every 5 seconds.", NO, YES, @"1", nil),
            LC32SwitchSetting(@"LC32_CRASH_STDERR", @"Crash Reports in Log",
                @"Also writes crash reports to the LiveExec32 log.",
                NO, YES, @"1", nil),
        ];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"LiveExec32";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
    [self reloadSettings];
    // The file may be edited in the Files app while LiveExec32 is open.
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(reloadSettings)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reloadSettings {
    [_file reload];
    [self rebuildOtherKeys];
    [self.tableView reloadData];
}

- (void)rebuildOtherKeys {
    NSMutableSet<NSString *> *managed = [NSMutableSet set];
    for(LC32Setting *setting in [_performance arrayByAddingObjectsFromArray:_diagnostics]) {
        [managed addObject:setting.key];
    }
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

- (BOOL)isOn:(LC32Setting *)setting {
    if(![_file isEnabled:setting.key]) return setting.defaultOn;
    if(setting.presenceOnly) return YES;
    NSString *value = [_file valueForKey:setting.key];
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

- (NSString *)choiceTitle:(LC32Setting *)setting {
    NSString *value = [self choiceValue:setting];
    for(NSArray *option in setting.options) {
        id optionValue = option[1];
        if(optionValue == NSNull.null ? value == nil : [optionValue isEqualToString:value]) {
            return option[0];
        }
    }
    return value;
}

- (nullable LC32Setting *)settingAtIndexPath:(NSIndexPath *)indexPath {
    if(indexPath.section == LC32SectionPerformance) return _performance[(NSUInteger)indexPath.row];
    if(indexPath.section == LC32SectionDiagnostics) return _diagnostics[(NSUInteger)indexPath.row];
    return nil;
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return LC32SectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch(section) {
    case LC32SectionAbout: return 1;
    case LC32SectionPerformance: return (NSInteger)_performance.count;
    case LC32SectionDiagnostics: return (NSInteger)_diagnostics.count;
    case LC32SectionOther: return (NSInteger)_otherKeys.count + 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch(section) {
    case LC32SectionPerformance: return @"Performance";
    case LC32SectionDiagnostics: return @"Diagnostics";
    case LC32SectionOther: return @"Other Variables";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section != LC32SectionOther) return nil;
    NSString *location = getenv("LC_HOME_PATH") ?
        @"LiveExec32.env in LiveContainer's folder (Files app: On My iPhone > "
        "LiveContainer)" : _file.path;
    return [NSString stringWithFormat:
        @"Any LC32_ variable can be added here. Switch one off to keep it in "
        "the file without using it; swipe to delete.\n\n"
        "Saved to %@. Changes apply the next time a 32-bit app starts.",
        location];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"
        forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *content = UIListContentConfiguration.subtitleCellConfiguration;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines = 0;

    if(indexPath.section == LC32SectionAbout) {
        content.text = _message;
        content.textProperties.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.contentConfiguration = content;
        return cell;
    }

    if(indexPath.section == LC32SectionOther) {
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

    LC32Setting *setting = [self settingAtIndexPath:indexPath];
    content.text = setting.title;
    if(setting.kind == LC32SettingKindChoice) {
        content = UIListContentConfiguration.valueCellConfiguration;
        content.text = setting.title;
        content.secondaryText = [self choiceTitle:setting];
        cell.contentConfiguration = content;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    content.secondaryText = setting.detail;
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [UISwitch new];
    toggle.on = [self isOn:setting];
    toggle.accessibilityLabel = setting.title;
    __weak typeof(self) weakSelf = self;
    [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [weakSelf setSetting:setting on:((UISwitch *)action.sender).on];
    }] forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(indexPath.section == LC32SectionOther) {
        NSString *key = (NSUInteger)indexPath.row < _otherKeys.count ?
            _otherKeys[(NSUInteger)indexPath.row] : nil;
        [self editVariable:key];
        return;
    }
    LC32Setting *setting = [self settingAtIndexPath:indexPath];
    if(setting.kind != LC32SettingKindChoice) return;
    LC32ChoiceViewController *choice = [[LC32ChoiceViewController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    choice.setting = setting;
    choice.currentValue = [self choiceValue:setting];
    __weak typeof(self) weakSelf = self;
    choice.onSelect = ^(NSString *value) {
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf) return;
        if(value) {
            [strongSelf->_file setValue:value forKey:setting.key enabled:YES];
        } else {
            [strongSelf->_file disableKey:setting.key];
        }
        [strongSelf commit];
    };
    [self.navigationController pushViewController:choice animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == LC32SectionOther &&
        (NSUInteger)indexPath.row < _otherKeys.count;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
        forRowAtIndexPath:(NSIndexPath *)indexPath {
    if(editingStyle != UITableViewCellEditingStyleDelete) return;
    [_file removeKey:_otherKeys[(NSUInteger)indexPath.row]];
    [self commit];
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
