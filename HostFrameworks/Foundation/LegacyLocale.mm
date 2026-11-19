@import Foundation;
#import <objc/runtime.h>
#import "../LC32/host_selector_hooks.h"
#include "../LC32/LiveExec32Shared.h"

/* Before iOS 9, +[NSLocale preferredLanguages] returned bare language
 * identifiers ("ko", "en", "zh-Hans"); iOS 9 added the region ("ko-KR").
 * Old games compare the first entry literally: Wild Frontier picks its Korean
 * data only for isEqualToString:@"ko" and otherwise falls back to English. Give
 * guests linked against an older SDK (or none recorded) the legacy form:
 * language plus any four-letter script subtag. */

static NSString *LC32LegacyLanguageIdentifier(NSString *identifier) {
    if(![identifier isKindOfClass:NSString.class]) return identifier;
    NSArray<NSString *> *parts = [[identifier stringByReplacingOccurrencesOfString:@"_"
        withString:@"-"] componentsSeparatedByString:@"-"];
    if(parts.count < 2 || parts[0].length == 0) return identifier;
    if(parts[1].length == 4)
        return [NSString stringWithFormat:@"%@-%@", parts[0], parts[1]];
    return parts[0];
}

@implementation NSLocale (LC32LegacyLocale)
+ (NSArray<NSString *> *)lc32_guestPreferredLanguages {
    using Getter = NSArray *(*)(id, SEL);
    NSArray *languages = ((Getter)LC32NativeHostMethod(self,
        @selector(preferredLanguages)))(self, @selector(preferredLanguages));
    if(LC32GetGuestExecutableSDKVersion() >= 0x00090000 ||
            ![languages isKindOfClass:NSArray.class])
        return languages;
    NSMutableArray *legacy = [NSMutableArray arrayWithCapacity:languages.count];
    for(NSString *identifier in languages) {
        NSString *converted = LC32LegacyLanguageIdentifier(identifier);
        if(converted && ![legacy containsObject:converted])
            [legacy addObject:converted];
    }
    static bool logged;
    if(!logged) {
        logged = true;
        fprintf(stderr, "LC32: legacy preferredLanguages %s -> %s\n",
            [[languages componentsJoinedByString:@","] UTF8String],
            [[legacy componentsJoinedByString:@","] UTF8String]);
    }
    return legacy;
}
@end

@interface LC32LegacyLocaleHooks : NSObject
@end

@implementation LC32LegacyLocaleHooks
+ (void)load {
    Class locale = objc_getClass("NSLocale");
    if(!locale) return;
    LC32RegisterHostSelectorHook(object_getClass(locale),
        @selector(preferredLanguages),
        {@selector(lc32_guestPreferredLanguages), nullptr});
}
@end
