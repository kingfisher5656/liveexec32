#ifndef LC32_LEGACY_CANVAS_H
#define LC32_LEGACY_CANVAS_H

#import <Foundation/Foundation.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef enum {
    LC32LegacyIPadCanvasNone,
    LC32LegacyIPadCanvasDeclared,
    LC32LegacyIPadCanvasInferred,
} LC32LegacyIPadCanvasKind;

typedef struct {
    BOOL supportsPhone;
    BOOL supportsPad;
} LC32SupportedDeviceFamilies;

static inline LC32SupportedDeviceFamilies LC32BundleSupportedDeviceFamilies(
        NSBundle *bundle) {
    LC32SupportedDeviceFamilies result = {NO, NO};
    NSDictionary *info = [bundle infoDictionary];
    NSArray *families = [info objectForKey:@"UIDeviceFamily"];
    if(![families isKindOfClass:NSArray.class] || ![families count]) {
        /* UIDeviceFamily predates the iPad. Its absence in an early iOS
         * application therefore means the original phone family. */
        result.supportsPhone = [[info objectForKey:
            @"LSRequiresIPhoneOS"] boolValue];
        return result;
    }
    for(id family in families) {
        if(![family respondsToSelector:@selector(integerValue)]) continue;
        const NSInteger value = [family integerValue];
        result.supportsPhone |= value == 1;
        result.supportsPad |= value == 2;
    }
    return result;
}

static inline BOOL LC32BundleContainsLegacyLaunchImage(
        NSBundle *bundle, NSString *resourceName) {
    if(!bundle || ![resourceName isKindOfClass:NSString.class] ||
            [resourceName length] == 0) {
        return NO;
    }

    NSString *extension = [resourceName pathExtension];
    NSString *baseName = [extension length]
        ? [resourceName stringByDeletingPathExtension] : resourceName;
    if([extension length]) {
        return [bundle pathForResource:baseName ofType:extension] != nil;
    }
    return [bundle pathForResource:baseName ofType:@"png"] != nil ||
           [bundle pathForResource:baseName ofType:@"PNG"] != nil;
}

static inline BOOL LC32BundleContainsLaunchImageFromArray(
        NSBundle *bundle, id value) {
    if(![value isKindOfClass:NSArray.class]) return NO;
    for(id entry in (NSArray *)value) {
        if(![entry isKindOfClass:NSDictionary.class]) continue;
        if(LC32BundleContainsLegacyLaunchImage(
                bundle, [(NSDictionary *)entry objectForKey:
                    @"UILaunchImageName"])) {
            return YES;
        }
    }
    return NO;
}

static inline BOOL LC32BundleContainsPhoneLaunchArt(
        NSBundle *bundle, NSDictionary *info) {
    BOOL result =
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default") ||
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default@2x") ||
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default-568h@2x") ||
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default~iphone") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default@2x~iphone") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-568h@2x~iphone");
    result |= LC32BundleContainsLegacyLaunchImage(
        bundle, [info objectForKey:@"UILaunchImageFile~iphone"]);
    /* A generic declaration can serve the phone half of a universal app. */
    result |= LC32BundleContainsLegacyLaunchImage(
        bundle, [info objectForKey:@"UILaunchImageFile"]);
    result |= LC32BundleContainsLaunchImageFromArray(
        bundle, [info objectForKey:@"UILaunchImages"]);
    result |= LC32BundleContainsLaunchImageFromArray(
        bundle, [info objectForKey:@"UILaunchImages~iphone"]);
    return result;
}

static inline BOOL LC32LaunchImageArrayContainsTallPhoneArt(id value) {
    if(![value isKindOfClass:NSArray.class]) return NO;
    for(id entry in (NSArray *)value) {
        if(![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [(NSDictionary *)entry objectForKey:
            @"UILaunchImageName"];
        NSString *size = [(NSDictionary *)entry objectForKey:
            @"UILaunchImageSize"];
        if(([name isKindOfClass:NSString.class] &&
                [name rangeOfString:@"568"
                            options:NSCaseInsensitiveSearch].location !=
                    NSNotFound) ||
                ([size isKindOfClass:NSString.class] &&
                [size rangeOfString:@"568"].location != NSNotFound)) {
            return YES;
        }
    }
    return NO;
}

static inline BOOL LC32BundleContainsTallVariantOfLaunchImage(
        NSBundle *bundle, id value) {
    if(![value isKindOfClass:NSString.class] || ![(NSString *)value length]) {
        return NO;
    }
    NSString *name = (NSString *)value;
    if([name rangeOfString:@"568"
                   options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    NSString *extension = [name pathExtension];
    NSString *baseName = [extension length]
        ? [name stringByDeletingPathExtension] : name;
    return LC32BundleContainsLegacyLaunchImage(
               bundle, [baseName stringByAppendingString:@"-568h@2x"]) ||
           LC32BundleContainsLegacyLaunchImage(
               bundle, [baseName stringByAppendingString:
                   @"-568h@2x~iphone"]);
}

static inline BOOL LC32BundleContainsTallPhoneLaunchArt(
        NSBundle *bundle, NSDictionary *info) {
    if(LC32BundleContainsLegacyLaunchImage(
            bundle, @"Default-568h@2x") ||
            LC32BundleContainsLegacyLaunchImage(
                bundle, @"Default-568h@2x~iphone") ||
            LC32BundleContainsTallVariantOfLaunchImage(
                bundle, [info objectForKey:@"UILaunchImageFile"]) ||
            LC32BundleContainsTallVariantOfLaunchImage(
                bundle, [info objectForKey:
                    @"UILaunchImageFile~iphone"])) {
        return YES;
    }
    return LC32LaunchImageArrayContainsTallPhoneArt(
               [info objectForKey:@"UILaunchImages"]) ||
           LC32LaunchImageArrayContainsTallPhoneArt(
               [info objectForKey:@"UILaunchImages~iphone"]);
}

static inline BOOL LC32BundleContainsIPadLaunchArt(
        NSBundle *bundle, NSDictionary *info) {
    BOOL result =
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default-Portrait") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Portrait@2x") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Portrait~ipad") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Portrait@2x~ipad") ||
        LC32BundleContainsLegacyLaunchImage(bundle, @"Default-Landscape") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Landscape@2x") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Landscape~ipad") ||
        LC32BundleContainsLegacyLaunchImage(bundle,
                                             @"Default-Landscape@2x~ipad");
    NSString *explicitIPadImage =
        [info objectForKey:@"UILaunchImageFile~ipad"];
    result |= LC32BundleContainsLegacyLaunchImage(
        bundle, explicitIPadImage);
    return result;
}

/* Some early App Store binaries advertise both device families even though
 * their bundle contains only an iPad UI.  On a phone-sized modern scene they
 * still require the old 768x1024 compatibility canvas.  Restrict this
 * inference to pre-iOS-8 binaries with exclusively iPad launch art so real
 * universal applications retain the phone path. */
static inline LC32LegacyIPadCanvasKind LC32BundleLegacyIPadCanvasKind(
        NSBundle *bundle, uint32_t sdkVersion) {
    NSDictionary *info = [bundle infoDictionary];
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);

    if(families.supportsPad && !families.supportsPhone) {
        return LC32LegacyIPadCanvasDeclared;
    }
    if(!families.supportsPad || !families.supportsPhone || sdkVersion == 0 ||
            sdkVersion >= 0x00080000) {
        return LC32LegacyIPadCanvasNone;
    }

    const BOOL hasIPadLaunchArt =
        LC32BundleContainsIPadLaunchArt(bundle, info);

    const BOOL hasPhoneLaunchArt =
        LC32BundleContainsPhoneLaunchArt(bundle, info);

    return hasIPadLaunchArt && !hasPhoneLaunchArt
        ? LC32LegacyIPadCanvasInferred : LC32LegacyIPadCanvasNone;
}

static inline BOOL LC32BundleNeedsLegacyIPadCanvas(
        NSBundle *bundle, uint32_t sdkVersion) {
    return LC32BundleLegacyIPadCanvasKind(bundle, sdkVersion) !=
        LC32LegacyIPadCanvasNone;
}

static inline BOOL LC32BundleUsesLandscapeOnlyPolicy(
        NSBundle *bundle, NSString *deviceOrientationKey) {
    NSDictionary *info = [bundle infoDictionary];
    NSArray *orientations = [info objectForKey:deviceOrientationKey];
    if(![orientations isKindOfClass:NSArray.class]) {
        orientations = [info objectForKey:
            @"UISupportedInterfaceOrientations"];
    }
    if([orientations isKindOfClass:NSArray.class] &&
            [orientations count] != 0) {
        for(id value in orientations) {
            if(![value isKindOfClass:NSString.class] ||
                    ![value hasPrefix:@"UIInterfaceOrientationLandscape"]) {
                return NO;
            }
        }
        return YES;
    }

    NSString *orientation = [info objectForKey:@"UIInterfaceOrientation"];
    return [orientation isKindOfClass:NSString.class] &&
        [orientation hasPrefix:@"UIInterfaceOrientationLandscape"];
}

static inline BOOL LC32BundleUsesLandscapeOnlyIPadPolicy(NSBundle *bundle) {
    return LC32BundleUsesLandscapeOnlyPolicy(
        bundle, @"UISupportedInterfaceOrientations~ipad");
}

static inline BOOL LC32BundleUsesLandscapeOnlyPhonePolicy(NSBundle *bundle) {
    return LC32BundleUsesLandscapeOnlyPolicy(
        bundle, @"UISupportedInterfaceOrientations~iphone");
}

static inline BOOL LC32BundleDeclaresStableLandscapeSide(NSBundle *bundle) {
    NSDictionary *info = [bundle infoDictionary];
    NSString *initial = [info objectForKey:@"UIInterfaceOrientation"];
    if([initial isEqualToString:@"UIInterfaceOrientationLandscapeLeft"] ||
            [initial isEqualToString:
                @"UIInterfaceOrientationLandscapeRight"]) {
        return YES;
    }

    NSArray *orientations = [info objectForKey:
        @"UISupportedInterfaceOrientations~iphone"];
    if(![orientations isKindOfClass:NSArray.class]) {
        orientations = [info objectForKey:
            @"UISupportedInterfaceOrientations"];
    }
    if([orientations count] != 1) return NO;

    NSString *onlyOrientation = [orientations firstObject];
    return [onlyOrientation isEqualToString:
                @"UIInterfaceOrientationLandscapeLeft"] ||
           [onlyOrientation isEqualToString:
                @"UIInterfaceOrientationLandscapeRight"];
}

/* Modern Combat 4 lists Portrait beside both landscape sides but launches
 * LandscapeRight and only ever draws landscape (its rootless GL window turns
 * its own picture). Its UI picks a 1136x640 layout only on a 568-point
 * screen; anywhere else it scales 960x640 overlays by 640/height and draws
 * full-screen fades into one corner. */
static inline BOOL LC32BundleLaunchesLandscapeOnBothSides(NSBundle *bundle) {
    NSDictionary *info = [bundle infoDictionary];
    NSString *initial = [info objectForKey:@"UIInterfaceOrientation"];
    if(![initial isEqualToString:@"UIInterfaceOrientationLandscapeLeft"] &&
            ![initial isEqualToString:
                @"UIInterfaceOrientationLandscapeRight"]) {
        return NO;
    }
    NSArray *orientations = [info objectForKey:
        @"UISupportedInterfaceOrientations~iphone"];
    if(![orientations isKindOfClass:NSArray.class]) {
        orientations = [info objectForKey:
            @"UISupportedInterfaceOrientations"];
    }
    return [orientations isKindOfClass:NSArray.class] &&
        [orientations containsObject:@"UIInterfaceOrientationLandscapeLeft"] &&
        [orientations containsObject:@"UIInterfaceOrientationLandscapeRight"];
}

static inline BOOL LC32BundleUsesFixedLandscapeIPadCanvas(
        NSBundle *bundle, LC32LegacyIPadCanvasKind canvasKind) {
    return canvasKind == LC32LegacyIPadCanvasInferred &&
        LC32BundleUsesLandscapeOnlyIPadPolicy(bundle);
}

/* Pre-iPhone-5 phone applications without 568-point launch art were given a
 * fixed 320x480 logical screen by iOS, even on larger devices.  SDK zero is
 * intentional here: early LC_VERSION_MIN_IPHONEOS commands encode it as
 * "n/a", whereas a missing host getter is filtered by the guest caller.
 * iOS applied the same rule to universal applications on an iPhone, whose
 * iPad half only takes effect on an iPad; pass allowUniversal for a phone
 * host. */
static inline BOOL LC32BundleUsesFixedLandscapePhoneCanvasForHost(
        NSBundle *bundle, uint32_t sdkVersion, BOOL allowUniversal) {
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);
    if(!families.supportsPhone ||
            (families.supportsPad && !allowUniversal) ||
            sdkVersion >= 0x00080000) {
        return NO;
    }
    NSDictionary *info = [bundle infoDictionary];
    /* A bundle with no launch art at all (Alien Space Retro) was letterboxed
     * the same way: only 568-point art opted an application out.
     * Universal bundles that leave the landscape side open (Air Mail, Unity)
     * size themselves from the screen; phone-only ones that do so (Top Gear
     * Stunt School: both landscape sides, 640x960 art only) still hard-code
     * a 480x320 layout and draw mostly off a full-size modern scene. */
    return (LC32BundleContainsPhoneLaunchArt(bundle, info) ||
            !LC32BundleContainsIPadLaunchArt(bundle, info)) &&
        !LC32BundleContainsTallPhoneLaunchArt(bundle, info) &&
        LC32BundleUsesLandscapeOnlyPhonePolicy(bundle) &&
        (LC32BundleDeclaresStableLandscapeSide(bundle) ||
            !families.supportsPad);
}

/* iOS showed pre-iOS-8 phone applications with 568-point launch art, but no
 * iPhone 6 art or launch storyboard, in a 320x568 window on larger iPhones.
 * Universal landscape games such as 9mm otherwise stretch a 16:9 layout over
 * a modern scene, so give them the same fixed canvas at 568 points. Phone-only
 * bundles stay with LC32BundleMayRetainLegacyLandscapePhoneCanvas, which
 * covers games that keep a 480x320 drawable despite their tall launch art. */
static inline BOOL LC32BundleUsesFixedLandscapeTallPhoneCanvasForHost(
        NSBundle *bundle, uint32_t sdkVersion, BOOL phoneHost) {
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);
    if(!phoneHost || !families.supportsPhone || sdkVersion >= 0x00080000) {
        return NO;
    }
    NSDictionary *info = [bundle infoDictionary];
    if(!LC32BundleContainsTallPhoneLaunchArt(bundle, info) ||
            !LC32BundleDeclaresStableLandscapeSide(bundle)) {
        return NO;
    }
    if(families.supportsPad) {
        return LC32BundleUsesLandscapeOnlyPhonePolicy(bundle) ||
            LC32BundleLaunchesLandscapeOnBothSides(bundle);
    }
    /* Phone-only bundles that launch landscape but also list portrait
     * (Tapsonic: all four sides) pick their -568h nibs only for a 568-point
     * screen and otherwise lay out 480x320 in a corner of a modern scene.
     * Landscape-only phone bundles stay with the runtime check in
     * LC32BundleMayRetainLegacyLandscapePhoneCanvas. */
    return !LC32BundleUsesLandscapeOnlyPhonePolicy(bundle) &&
        LC32BundleLaunchesLandscapeOnBothSides(bundle);
}

/* The landscape-only phone bundles left to that runtime check, when UIKit
 * itself runs the pre-iOS-8 rotation (on the device, where LiveContainer
 * reports the guest's SDK). Nothing letterboxes them there: the guest sees
 * the physical screen (393x852). Most size themselves from it (Dead Space,
 * whose widescreen UI patch relies on that), but DJMAX Ray takes its
 * 568-point layout only when the screen is exactly 568 tall and otherwise
 * draws a 480x320 picture into a corner. iOS gave such an application a
 * 320x568 window; the caller applies this only to games opted in through
 * LC32GameProfile.h. */
static inline BOOL LC32BundleUsesNativeTallLandscapePhoneCanvas(
        NSBundle *bundle, uint32_t sdkVersion, BOOL phoneHost) {
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);
    if(!phoneHost || !families.supportsPhone || families.supportsPad ||
            sdkVersion >= 0x00080000) {
        return NO;
    }
    NSDictionary *info = [bundle infoDictionary];
    return LC32BundleContainsTallPhoneLaunchArt(bundle, info) &&
        LC32BundleUsesLandscapeOnlyPhonePolicy(bundle) &&
        LC32BundleDeclaresStableLandscapeSide(bundle);
}

/* The portrait counterpart: a pre-iPhone-5 phone application that declares no
 * landscape-only policy also ran on a fixed 320x480 screen, which iOS
 * letterboxed on taller iPhones. Several (Zenonia 1/3) draw a landscape game
 * sideways into that portrait drawable themselves, so it must stay exactly
 * 320x480 and be scaled whole. */
static inline BOOL LC32BundleUsesFixedPortraitPhoneCanvasForHost(
        NSBundle *bundle, uint32_t sdkVersion, BOOL allowUniversal) {
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);
    if(!families.supportsPhone ||
            (families.supportsPad && !allowUniversal) ||
            sdkVersion >= 0x00080000) {
        return NO;
    }
    NSDictionary *info = [bundle infoDictionary];
    return LC32BundleContainsPhoneLaunchArt(bundle, info) &&
        !LC32BundleContainsTallPhoneLaunchArt(bundle, info) &&
        !LC32BundleUsesLandscapeOnlyPhonePolicy(bundle);
}

static inline BOOL LC32BundleUsesFixedLandscapePhoneCanvas(
        NSBundle *bundle, uint32_t sdkVersion) {
    return LC32BundleUsesFixedLandscapePhoneCanvasForHost(
        bundle, sdkVersion, NO);
}

/* Some pre-iOS-8 phone-only games ship 568-point launch art but continue to
 * create a 480x320 drawable at runtime. Metadata alone cannot distinguish
 * them from normal 568x320 applications, so use this only as a stable gate
 * before checking the loaded controller's exact native bounds. */
static inline BOOL LC32BundleMayRetainLegacyLandscapePhoneCanvas(
        NSBundle *bundle, uint32_t sdkVersion) {
    const LC32SupportedDeviceFamilies families =
        LC32BundleSupportedDeviceFamilies(bundle);
    if(!families.supportsPhone || families.supportsPad ||
            sdkVersion >= 0x00080000) {
        return NO;
    }
    NSDictionary *info = [bundle infoDictionary];
    return LC32BundleContainsTallPhoneLaunchArt(bundle, info) &&
        LC32BundleUsesLandscapeOnlyPhonePolicy(bundle) &&
        LC32BundleDeclaresStableLandscapeSide(bundle);
}

/* LC32_ASPECT picks how pre-iOS-8 phone games are shaped on a phone host.
 *   auto      today's per-case rules (default)
 *   original  the screen iOS itself gave the game on a later iPhone: 320x480
 *             (3:2) without 568-point launch art, else 320x568 (16:9)
 *   wide      320x568 even without tall launch art (screen-relative engines)
 *   fill      no letterboxed phone canvas: the game sees the whole screen
 * iPad canvases (iPad-only bundles) are unaffected. SDK 8+ bundles follow
 * LC32BundleModernCanvasForHost below. */
typedef enum {
    LC32AspectModeAuto,
    LC32AspectModeOriginal,
    LC32AspectModeWide,
    LC32AspectModeFill,
} LC32AspectMode;

static inline LC32AspectMode LC32AspectModeFromString(const char *value) {
    if(!value) return LC32AspectModeAuto;
    if(strcmp(value, "original") == 0 || strcmp(value, "1") == 0)
        return LC32AspectModeOriginal;
    if(strcmp(value, "wide") == 0 || strcmp(value, "16:9") == 0)
        return LC32AspectModeWide;
    if(strcmp(value, "fill") == 0 || strcmp(value, "native") == 0)
        return LC32AspectModeFill;
    return LC32AspectModeAuto;
}

static inline BOOL LC32OrientationNameIsLandscape(id value) {
    return [value isKindOfClass:NSString.class] &&
        [(NSString *)value hasPrefix:@"UIInterfaceOrientationLandscape"];
}

/* Whether a game shows its first screen in landscape: a landscape-only
 * policy, else a declared initial orientation (Air Mail declares an empty
 * one), else the first listed side (Death Rally lists both landscape sides
 * before portrait). */
static inline BOOL LC32BundleLaunchesLandscape(NSBundle *bundle) {
    if(LC32BundleUsesLandscapeOnlyPhonePolicy(bundle)) return YES;
    NSDictionary *info = [bundle infoDictionary];
    for(NSString *key in @[@"UIInterfaceOrientation~iphone",
                           @"UIInterfaceOrientation"]) {
        id initial = [info objectForKey:key];
        if([initial isKindOfClass:NSString.class] &&
                [(NSString *)initial hasPrefix:@"UIInterfaceOrientation"]) {
            return LC32OrientationNameIsLandscape(initial);
        }
    }
    NSArray *orientations = [info objectForKey:
        @"UISupportedInterfaceOrientations~iphone"];
    if(![orientations isKindOfClass:NSArray.class] || ![orientations count]) {
        orientations = [info objectForKey:
            @"UISupportedInterfaceOrientations"];
    }
    return [orientations isKindOfClass:NSArray.class] &&
        [orientations count] != 0 &&
        LC32OrientationNameIsLandscape([orientations objectAtIndex:0]);
}

typedef struct {
    /* NO: the mode does not change this bundle (auto rules apply). */
    BOOL applies;
    /* A fixed phone canvas at all (NO for fill). */
    BOOL letterboxed;
    BOOL landscape;
    double longEdge;
} LC32AspectCanvas;

static inline LC32AspectCanvas LC32BundleAspectCanvasForHost(
        NSBundle *bundle, uint32_t sdkVersion, BOOL phoneHost,
        LC32AspectMode mode) {
    LC32AspectCanvas result = {NO, NO, NO, 480};
    if(mode == LC32AspectModeAuto || !phoneHost ||
            sdkVersion >= 0x00080000 ||
            LC32BundleLegacyIPadCanvasKind(bundle, sdkVersion) !=
                LC32LegacyIPadCanvasNone ||
            !LC32BundleSupportedDeviceFamilies(bundle).supportsPhone) {
        return result;
    }
    result.applies = YES;
    if(mode == LC32AspectModeFill) return result;
    result.letterboxed = YES;
    result.landscape = LC32BundleLaunchesLandscape(bundle);
    result.longEdge = mode == LC32AspectModeWide ||
        LC32BundleContainsTallPhoneLaunchArt(bundle, [bundle infoDictionary])
        ? 568 : 480;
    return result;
}

/* Whether a UILaunchImages array has art for a screen whose long edge is
 * one of the given values (iPhone 6: 667, 6 Plus: 736, X: 812). */
static inline BOOL LC32LaunchImageArrayContainsLongEdge(
        id value, const double *edges, unsigned count) {
    if(![value isKindOfClass:NSArray.class]) return NO;
    for(id entry in (NSArray *)value) {
        if(![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *size = [(NSDictionary *)entry objectForKey:
            @"UILaunchImageSize"];
        double width = 0, height = 0;
        if(![size isKindOfClass:NSString.class] ||
                sscanf([size UTF8String], " { %lf , %lf", &width,
                       &height) != 2) {
            continue;
        }
        const double longEdge = width > height ? width : height;
        for(unsigned i = 0; i < count; i++) {
            if(longEdge > edges[i] - 0.5 && longEdge < edges[i] + 0.5)
                return YES;
        }
    }
    return NO;
}

/* An iPhone-specific UILaunchImages~iphone array replaces the generic one. */
static inline BOOL LC32BundleContainsLaunchArtForLongEdge(
        NSDictionary *info, const double *edges, unsigned count) {
    id images = [info objectForKey:@"UILaunchImages~iphone"];
    if(![images isKindOfClass:NSArray.class] || ![(NSArray *)images count])
        images = [info objectForKey:@"UILaunchImages"];
    return LC32LaunchImageArrayContainsLongEdge(images, edges, count);
}

static inline BOOL LC32BundleHasLaunchStoryboard(NSDictionary *info) {
    for(NSString *key in @[@"UILaunchStoryboardName~iphone",
                           @"UILaunchStoryboardName"]) {
        id name = [info objectForKey:key];
        if([name isKindOfClass:NSString.class] && [(NSString *)name length])
            return YES;
    }
    /* iOS 9 can name the default one in a UILaunchStoryboards dictionary. */
    for(NSString *key in @[@"UILaunchStoryboards~iphone",
                           @"UILaunchStoryboards"]) {
        id storyboards = [info objectForKey:key];
        if(![storyboards isKindOfClass:NSDictionary.class]) continue;
        id name = [(NSDictionary *)storyboards
            objectForKey:@"UIDefaultLaunchStoryboard"];
        if([name isKindOfClass:NSString.class] && [(NSString *)name length])
            return YES;
    }
    return NO;
}

/* iOS 7+ takes launch images from a UILaunchImages array when there is one
 * and ignores the Default-568h file-name convention then. */
static inline BOOL LC32BundleModernTallLaunchArt(
        NSBundle *bundle, NSDictionary *info) {
    for(NSString *key in @[@"UILaunchImages~iphone", @"UILaunchImages"]) {
        id images = [info objectForKey:key];
        if([images isKindOfClass:NSArray.class] && [(NSArray *)images count])
            return LC32LaunchImageArrayContainsTallPhoneArt(images);
    }
    return LC32BundleContainsTallPhoneLaunchArt(bundle, info);
}

/* The screen iOS gave an SDK 8+ phone game on an iPhone X-class phone:
 *   SDK 11+ with a launch storyboard, or iPhone X launch art: full screen
 *   a launch storyboard or iPhone 6 / 6 Plus launch art: 375x667 (414x736
 *     on a phone at least 414 points wide)
 *   568-point launch art: 320x568
 *   otherwise: 320x480
 * original picks that screen; wide never goes below 16:9 (320x568); fill
 * keeps the whole scene and auto keeps today's full-screen behaviour. */
typedef struct {
    /* NO: the mode does not change this bundle (it fills the scene). */
    BOOL applies;
    BOOL letterboxed;
    /* Portrait-ordered canvas size in points. */
    double shortEdge;
    double longEdge;
} LC32ModernCanvas;

static inline LC32ModernCanvas LC32BundleModernCanvasForHost(
        NSBundle *bundle, uint32_t sdkVersion, BOOL phoneHost,
        double hostShortEdge, LC32AspectMode mode) {
    LC32ModernCanvas result = {NO, NO, 0, 0};
    if(mode == LC32AspectModeAuto || !phoneHost ||
            sdkVersion < 0x00080000 ||
            !LC32BundleSupportedDeviceFamilies(bundle).supportsPhone) {
        return result;
    }
    result.applies = YES;
    if(mode == LC32AspectModeFill) return result;
    NSDictionary *info = [bundle infoDictionary];
    const BOOL storyboard = LC32BundleHasLaunchStoryboard(info);
    static const double xEdges[] = {812, 896};
    if((sdkVersion >= 0x000B0000 && storyboard) ||
            LC32BundleContainsLaunchArtForLongEdge(info, xEdges, 2)) {
        return result;
    }
    static const double sixEdges[] = {667};
    static const double plusEdges[] = {736};
    const BOOL plusArt =
        LC32BundleContainsLaunchArtForLongEdge(info, plusEdges, 1);
    result.letterboxed = YES;
    if(storyboard || plusArt ||
            LC32BundleContainsLaunchArtForLongEdge(info, sixEdges, 1)) {
        const BOOL plus = hostShortEdge >= 413.5 && (storyboard || plusArt);
        result.shortEdge = plus ? 414 : 375;
        result.longEdge = plus ? 736 : 667;
    } else {
        result.shortEdge = 320;
        result.longEdge = mode == LC32AspectModeWide ||
            LC32BundleModernTallLaunchArt(bundle, info) ? 568 : 480;
    }
    return result;
}

#endif
