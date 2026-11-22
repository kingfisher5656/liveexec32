#import "LC32GameLibrary.h"
#import "LC32LegacyCanvas.h"
#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>

#ifndef CPU_TYPE_ARM
#define CPU_TYPE_ARM 12
#endif

typedef struct {
    BOOL is32BitOnly;
    uint32_t sdkVersion;
} LC32ExecutableInfo;

static NSData *LC32ReadBytes(NSFileHandle *file, uint64_t offset,
                             NSUInteger length) {
    @try {
        [file seekToFileOffset:offset];
        return [file readDataOfLength:length];
    } @catch(NSException *exception) {
        return nil;
    }
}

/* The sdk of an ARM32 Mach-O image at offset: LC_VERSION_MIN_IPHONEOS, or
 * LC_BUILD_VERSION. 0 means "n/a" (early binaries). */
static uint32_t LC32SDKVersionOfImage(NSFileHandle *file, uint64_t offset) {
    NSData *headerData = LC32ReadBytes(file, offset, sizeof(struct mach_header));
    if(headerData.length < sizeof(struct mach_header)) return 0;
    struct mach_header header;
    memcpy(&header, headerData.bytes, sizeof(header));
    if(header.magic != MH_MAGIC || header.sizeofcmds > 4 * 1024 * 1024) return 0;
    NSData *commands = LC32ReadBytes(file, offset + sizeof(header),
        header.sizeofcmds);
    const uint8_t *cursor = commands.bytes;
    const uint8_t *end = cursor + commands.length;
    for(uint32_t i = 0; i < header.ncmds &&
            cursor + sizeof(struct load_command) <= end; i++) {
        struct load_command command;
        memcpy(&command, cursor, sizeof(command));
        if(command.cmdsize < sizeof(command) || cursor + command.cmdsize > end) break;
        if(command.cmd == LC_VERSION_MIN_IPHONEOS &&
                command.cmdsize >= sizeof(struct version_min_command)) {
            struct version_min_command version;
            memcpy(&version, cursor, sizeof(version));
            return version.sdk;
        }
        if(command.cmd == LC_BUILD_VERSION &&
                command.cmdsize >= sizeof(struct build_version_command)) {
            struct build_version_command version;
            memcpy(&version, cursor, sizeof(version));
            return version.sdk;
        }
        cursor += command.cmdsize;
    }
    return 0;
}

static LC32ExecutableInfo LC32InspectExecutable(NSString *path) {
    LC32ExecutableInfo info = {NO, 0};
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if(!file) return info;
    NSData *head = LC32ReadBytes(file, 0, 4096);
    if(head.length < sizeof(uint32_t)) {
        [file closeFile];
        return info;
    }
    const uint8_t *bytes = head.bytes;
    uint32_t magic;
    memcpy(&magic, bytes, sizeof(magic));
    if((magic == FAT_CIGAM || magic == FAT_CIGAM_64) &&
            head.length >= sizeof(struct fat_header)) {
        const BOOL wide = magic == FAT_CIGAM_64;
        const size_t entrySize = wide ? sizeof(struct fat_arch_64)
                                      : sizeof(struct fat_arch);
        struct fat_header fat;
        memcpy(&fat, bytes, sizeof(fat));
        const uint32_t count = OSSwapBigToHostInt32(fat.nfat_arch);
        BOOL hasARM = NO, has64 = NO;
        uint64_t armOffset = 0;
        int armPriority = 0;
        for(uint32_t i = 0; i < count; i++) {
            const size_t at = sizeof(fat) + i * entrySize;
            if(at + entrySize > head.length) break;
            cpu_type_t type;
            uint32_t subtype;
            uint64_t offset;
            if(wide) {
                struct fat_arch_64 arch;
                memcpy(&arch, bytes + at, sizeof(arch));
                type = (cpu_type_t)OSSwapBigToHostInt32((uint32_t)arch.cputype);
                subtype = OSSwapBigToHostInt32((uint32_t)arch.cpusubtype);
                offset = OSSwapBigToHostInt64(arch.offset);
            } else {
                struct fat_arch arch;
                memcpy(&arch, bytes + at, sizeof(arch));
                type = (cpu_type_t)OSSwapBigToHostInt32((uint32_t)arch.cputype);
                subtype = OSSwapBigToHostInt32((uint32_t)arch.cpusubtype);
                offset = OSSwapBigToHostInt32(arch.offset);
            }
            subtype &= ~CPU_SUBTYPE_MASK;
            if(type & CPU_ARCH_ABI64) has64 = YES;
            if(type == CPU_TYPE_ARM) {
                // The slice the runtime runs (LC32ARMSubtypePriority):
                // armv7s, then armv7, armv6, any.
                const int priority = subtype == CPU_SUBTYPE_ARM_V7S ? 5 :
                    subtype == CPU_SUBTYPE_ARM_V7 ? 4 :
                    subtype == CPU_SUBTYPE_ARM_V6 ? 3 :
                    subtype == CPU_SUBTYPE_ARM_ALL ? 2 : 1;
                if(priority > armPriority) {
                    armPriority = priority;
                    armOffset = offset;
                }
                hasARM = YES;
            }
        }
        info.is32BitOnly = hasARM && !has64;
        if(info.is32BitOnly) info.sdkVersion = LC32SDKVersionOfImage(file, armOffset);
    } else if(magic == MH_MAGIC && head.length >= sizeof(struct mach_header)) {
        struct mach_header header;
        memcpy(&header, bytes, sizeof(header));
        info.is32BitOnly = header.cputype == CPU_TYPE_ARM;
        if(info.is32BitOnly) info.sdkVersion = LC32SDKVersionOfImage(file, 0);
    }
    [file closeFile];
    return info;
}

static NSArray<NSString *> *LC32IconNames(NSDictionary *info) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for(NSString *key in @[@"CFBundleIcons~iphone", @"CFBundleIcons"]) {
        NSDictionary *icons = info[key];
        if(![icons isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        if(![primary isKindOfClass:NSDictionary.class]) continue;
        NSArray *files = primary[@"CFBundleIconFiles"];
        if([files isKindOfClass:NSArray.class]) {
            // Largest last in most bundles.
            for(id name in files.reverseObjectEnumerator) {
                if([name isKindOfClass:NSString.class]) [names addObject:name];
            }
        }
    }
    NSArray *files = info[@"CFBundleIconFiles"];
    if([files isKindOfClass:NSArray.class]) {
        for(id name in files.reverseObjectEnumerator) {
            if([name isKindOfClass:NSString.class]) [names addObject:name];
        }
    }
    if([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) {
        [names addObject:info[@"CFBundleIconFile"]];
    }
    [names addObjectsFromArray:@[@"Icon@2x.png", @"Icon.png", @"icon@2x.png",
        @"icon.png", @"Icon-72.png"]];
    return names;
}

static UIImage *LC32LoadIcon(NSString *bundlePath, NSDictionary *info) {
    NSFileManager *manager = NSFileManager.defaultManager;
    for(NSString *name in LC32IconNames(info)) {
        NSString *base = name.pathExtension.length
            ? name.stringByDeletingPathExtension : name;
        NSArray<NSString *> *candidates = name.pathExtension.length
            ? @[name, [base stringByAppendingString:@"@2x.png"]]
            : @[[base stringByAppendingString:@"@2x.png"],
                [base stringByAppendingString:@".png"],
                [base stringByAppendingString:@"@2x~iphone.png"],
                [base stringByAppendingString:@"~iphone.png"]];
        for(NSString *candidate in candidates) {
            NSString *path = [bundlePath stringByAppendingPathComponent:candidate];
            if(![manager fileExistsAtPath:path]) continue;
            UIImage *image = [UIImage imageWithContentsOfFile:path];
            if(image) return image;
        }
    }
    return nil;
}

@interface LC32GameEntry ()
@property(nonatomic, readwrite, copy) NSString *folderName;
@property(nonatomic, readwrite, copy) NSString *bundlePath;
@property(nonatomic, readwrite, copy) NSString *displayName;
@property(nonatomic, readwrite, copy) NSString *bundleIdentifier;
@property(nonatomic, readwrite) uint32_t sdkVersion;
@property(nonatomic, readwrite, copy) NSString *settingsPath;
@property(nonatomic, readwrite, copy) NSDictionary<NSString *, NSString *> *bundleEnvironment;
@property(nonatomic, copy) NSDictionary *info;
@end

@implementation LC32GameEntry {
    UIImage *_icon;
    BOOL _iconLoaded;
}

- (UIImage *)icon {
    if(!_iconLoaded) {
        _iconLoaded = YES;
        _icon = LC32LoadIcon(self.bundlePath, self.info);
    }
    return _icon;
}

- (NSString *)sdkDescription {
    if(self.sdkVersion == 0) return @"SDK n/a";
    return [NSString stringWithFormat:@"SDK %u.%u", self.sdkVersion >> 16,
        (self.sdkVersion >> 8) & 0xff];
}

static double LC32HostShortEdge(void) {
    const CGSize size = UIScreen.mainScreen.bounds.size;
    return MIN(size.width, size.height);
}

/* As the runtime decides: an iPhone, or an iPhone-only game on an iPad. */
static BOOL LC32PhoneCanvasHost(NSBundle *bundle) {
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);
    return UIDevice.currentDevice.userInterfaceIdiom ==
            UIUserInterfaceIdiomPhone ||
        (families.supportsPhone && !families.supportsPad);
}

- (BOOL)aspectModeApplies {
    NSBundle *bundle = [NSBundle bundleWithPath:self.bundlePath];
    if(self.sdkVersion >= 0x00080000) {
        return LC32BundleModernCanvasForHost(bundle, self.sdkVersion,
            LC32PhoneCanvasHost(bundle), LC32HostShortEdge(),
            LC32AspectModeOriginal).applies;
    }
    return LC32BundleAspectCanvasForHost(bundle, self.sdkVersion, YES,
        LC32AspectModeOriginal).applies;
}

- (NSString *)originalShapeDescription {
    NSBundle *bundle = [NSBundle bundleWithPath:self.bundlePath];
    if(!bundle) return @"Unknown";
    if(LC32BundleLegacyIPadCanvasKind(bundle, self.sdkVersion) !=
            LC32LegacyIPadCanvasNone) {
        return @"iPad app: always shown on its 4:3 iPad screen";
    }
    if(self.sdkVersion >= 0x00080000) {
        const LC32ModernCanvas modern = LC32BundleModernCanvasForHost(bundle,
            self.sdkVersion, LC32PhoneCanvasHost(bundle), LC32HostShortEdge(),
            LC32AspectModeOriginal);
        if(!modern.applies) {
            return LC32BundleSupportedDeviceFamilies(bundle).supportsPhone
                ? @"Shown full screen in its own iPad layout"
                : @"Not an iPhone app";
        }
        if(!modern.letterboxed) {
            return @"Original shape: full screen (it supports this iPhone's "
                "screen)";
        }
        NSString *side = LC32BundleLaunchesLandscape(bundle)
            ? @"landscape" : @"portrait";
        if(modern.shortEdge > 321) {
            return [NSString stringWithFormat:@"Original shape 16:9 "
                "(%.0f×%.0f, %@): made for the iPhone 6", modern.shortEdge,
                modern.longEdge, side];
        }
        return modern.longEdge > 500
            ? [NSString stringWithFormat:@"Original shape 16:9 (320×568, %@): "
                "it has an iPhone 5 launch image but not an iPhone 6 one", side]
            : [NSString stringWithFormat:@"Original shape 3:2 (320×480, %@): "
                "no iPhone 5 or 6 launch image", side];
    }
    const LC32AspectCanvas canvas = LC32BundleAspectCanvasForHost(bundle,
        self.sdkVersion, YES, LC32AspectModeOriginal);
    if(!canvas.applies) return @"Not an iPhone app";
    return canvas.longEdge > 500
        ? [NSString stringWithFormat:@"Original shape 16:9 (320×568, %@): it "
            "has an iPhone 5 launch image", canvas.landscape ? @"landscape" : @"portrait"]
        : [NSString stringWithFormat:@"Original shape 3:2 (320×480, %@): no "
            "iPhone 5 launch image", canvas.landscape ? @"landscape" : @"portrait"];
}

@end

@implementation LC32GameLibrary

+ (NSString *)rootForSettingsPath:(NSString *)settingsPath {
    return settingsPath.stringByDeletingLastPathComponent;
}

+ (NSArray<LC32GameEntry *> *)gamesForSettingsPath:(NSString *)settingsPath {
    NSString *root = [self rootForSettingsPath:settingsPath];
    NSString *applications = [root stringByAppendingPathComponent:@"Applications"];
    NSString *settingsFolder = [root stringByAppendingPathComponent:
        @"LiveExec32-Games"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:applications error:nil] ?: @[];
    NSMutableArray<LC32GameEntry *> *games = [NSMutableArray array];
    for(NSString *name in names) {
        if(![name.pathExtension isEqualToString:@"app"]) continue;
        NSString *bundlePath = [applications stringByAppendingPathComponent:name];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
            [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        NSString *executable = info[@"CFBundleExecutable"];
        if(![executable isKindOfClass:NSString.class] || !executable.length) continue;
        const LC32ExecutableInfo executableInfo = LC32InspectExecutable(
            [bundlePath stringByAppendingPathComponent:executable]);
        if(!executableInfo.is32BitOnly) continue;

        LC32GameEntry *entry = [LC32GameEntry new];
        entry.folderName = name.stringByDeletingPathExtension;
        entry.bundlePath = bundlePath;
        NSString *displayName = info[@"CFBundleDisplayName"];
        if(![displayName isKindOfClass:NSString.class] || !displayName.length)
            displayName = info[@"CFBundleName"];
        if(![displayName isKindOfClass:NSString.class] || !displayName.length)
            displayName = entry.folderName;
        entry.displayName = displayName;
        NSString *identifier = info[@"CFBundleIdentifier"];
        entry.bundleIdentifier = [identifier isKindOfClass:NSString.class]
            ? identifier : entry.folderName;
        entry.sdkVersion = executableInfo.sdkVersion;
        entry.settingsPath = [settingsFolder stringByAppendingPathComponent:
            [entry.folderName stringByAppendingPathExtension:@"env"]];
        NSMutableDictionary<NSString *, NSString *> *environment =
            [NSMutableDictionary dictionary];
        NSDictionary *shipped = info[@"LC32Environment"];
        if([shipped isKindOfClass:NSDictionary.class]) {
            [shipped enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                if(![key isKindOfClass:NSString.class]) return;
                if([value isKindOfClass:NSString.class]) environment[key] = value;
                else if([value respondsToSelector:@selector(stringValue)])
                    environment[key] = [value stringValue];
            }];
        }
        entry.bundleEnvironment = environment;
        entry.info = info;
        [games addObject:entry];
    }
    [games sortUsingComparator:^NSComparisonResult(LC32GameEntry *a, LC32GameEntry *b) {
        return [a.displayName localizedStandardCompare:b.displayName];
    }];
    return games;
}

@end
