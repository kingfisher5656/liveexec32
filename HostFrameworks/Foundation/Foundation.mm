@import Foundation;
#import "bridge.h"
#import "MachPort.h"
#include "filesystem.h"
#include "../../GuestFrameworks/Foundation/LC32FoundationBridge.h"

#include <cstring>

namespace {

NSString *LC32GuestHomeDirectory() {
    const char *path = getenv("LC32_GUEST_HOME");
    if(path && path[0]) return [NSString stringWithUTF8String:path];
    return NSHomeDirectory();
}

NSArray<NSString *> *LC32UserSearchPaths(NSSearchPathDirectory directory,
                                         BOOL expandTilde) {
    NSArray<NSString *> *suffixes = nil;
    switch(directory) {
        case NSApplicationDirectory: suffixes = @[@"Applications"]; break;
        case NSDemoApplicationDirectory:
            suffixes = @[@"Applications/Demos"]; break;
        case NSDeveloperApplicationDirectory:
            suffixes = @[@"Developer/Applications"]; break;
        case NSAdminApplicationDirectory:
            suffixes = @[@"Applications/Utilities"]; break;
        case NSLibraryDirectory: suffixes = @[@"Library"]; break;
        case NSDeveloperDirectory: suffixes = @[@"Developer"]; break;
        case NSDocumentationDirectory:
            suffixes = @[@"Library/Documentation"]; break;
        case NSDocumentDirectory: suffixes = @[@"Documents"]; break;
        case NSCachesDirectory: suffixes = @[@"Library/Caches"]; break;
        case NSApplicationSupportDirectory:
            suffixes = @[@"Library/Application Support"]; break;
        case NSAutosavedInformationDirectory:
            suffixes = @[@"Library/Autosave Information"]; break;
        case NSDesktopDirectory: suffixes = @[@"Desktop"]; break;
        case NSDownloadsDirectory: suffixes = @[@"Downloads"]; break;
        case NSInputMethodsDirectory:
            suffixes = @[@"Library/Input Methods"]; break;
        case NSMoviesDirectory: suffixes = @[@"Movies"]; break;
        case NSMusicDirectory: suffixes = @[@"Music"]; break;
        case NSPicturesDirectory: suffixes = @[@"Pictures"]; break;
        case NSSharedPublicDirectory: suffixes = @[@"Public"]; break;
        case NSPreferencePanesDirectory:
            suffixes = @[@"Library/PreferencePanes"]; break;
        case static_cast<NSSearchPathDirectory>(23):
            suffixes = @[@"Library/Application Scripts"]; break;
        case NSAllApplicationsDirectory:
            suffixes = @[
                @"Applications",
                @"Applications/Utilities",
                @"Developer/Applications",
                @"Applications/Demos",
            ];
            break;
        case NSAllLibrariesDirectory:
            suffixes = @[@"Library", @"Developer"];
            break;
        default: break;
    }
    if(!suffixes) return nil;
    NSString *base = expandTilde ? LC32GuestHomeDirectory() : @"~";
    NSMutableArray<NSString *> *result =
        [NSMutableArray arrayWithCapacity:suffixes.count];
    for(NSString *suffix in suffixes) {
        [result addObject:[base stringByAppendingPathComponent:suffix]];
    }
    return result;
}

} // namespace

__BEGIN_DECLS

void LC32MountFoundationTemporaryDirectory() {
    // Foundation can cache a temp directory outside the selected guest home
    // (notably LiveContainer's own container on the simulator). POSIX users of
    // NSTemporaryDirectory must reach the same files as native Foundation.
    NSString *directory = [NSTemporaryDirectory() stringByStandardizingPath];
    const char *path = directory.fileSystemRepresentation;
    if(path && path[0] == '/') {
        sharedHandle.fs->addMountpoint(path, path);
    }
}

u32 LC32_Foundation_AllocateMachPortPeer(void) {
    return LC32GuestObjectForOwnedHostObject((CFTypeRef)LC32AllocateMachPortPeer());
}

u32 LC32_Foundation_NSTemporaryDirectory() {
    return NSTemporaryDirectory().guest_self;
}

u32 LC32_Foundation_NSHomeDirectory() {
    return LC32GuestHomeDirectory().guest_self;
}

u32 LC32_Foundation_NSClassFromString(u32 low, u32 high, u32) {
    NSString *name = reinterpret_cast<NSString *>(
        static_cast<uintptr_t>(low | (static_cast<u64>(high) << 32)));
    return name ? guest_objc_getClass(name.UTF8String) : 0;
}

u32 LC32_Foundation_NSSelectorFromString(u32 low, u32 high, u32) {
    NSString *name = reinterpret_cast<NSString *>(
        static_cast<uintptr_t>(low | (static_cast<u64>(high) << 32)));
    return name ? guest_sel_registerName(name.UTF8String) : 0;
}

u32 LC32_Foundation_NSSearchPathForDirectoriesInDomains(
        u32 directoryValue, u32 domainMaskValue, u32 stack) {
    const BOOL expandTilde =
        Dynarmic_current_user_callbacks()->MemoryRead32(stack) != 0;
    const NSSearchPathDirectory directory =
        static_cast<NSSearchPathDirectory>(directoryValue);
    const NSSearchPathDomainMask domainMask =
        static_cast<NSSearchPathDomainMask>(domainMaskValue);

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if(domainMask & NSUserDomainMask) {
        NSArray<NSString *> *userPaths =
            LC32UserSearchPaths(directory, expandTilde);
        if(userPaths) [paths addObjectsFromArray:userPaths];
    }
    const NSSearchPathDomainMask remaining =
        domainMask & ~NSUserDomainMask;
    if(remaining) {
        [paths addObjectsFromArray:
            NSSearchPathForDirectoriesInDomains(
                directory, remaining, expandTilde)];
    }
    if(paths.count == 0 && (domainMask & NSUserDomainMask)) {
        [paths addObjectsFromArray:
            NSSearchPathForDirectoriesInDomains(
                directory, NSUserDomainMask, expandTilde)];
    }
    return paths.guest_self;
}

u32 LC32_Foundation_CreateDelayedTimer(u32 guestCall, u32, u32) {
    LC32FoundationDelayedTimerCall call = {};
    if(!guestCall ||
       Dynarmic_mem_1read(guestCall, sizeof(call),
           reinterpret_cast<char *>(&call)) != 0 ||
       call.version != LC32FoundationDelayedTimerABIVersion ||
       call.slotCount != LC32FoundationDelayedTimerSlotCount) {
        return 0;
    }

    id target = reinterpret_cast<id>(static_cast<uintptr_t>(
        call.slots[LC32FoundationDelayedTimerTargetSlot]));
    SEL selector = reinterpret_cast<SEL>(static_cast<uintptr_t>(
        call.slots[LC32FoundationDelayedTimerSelectorSlot]));
    NSTimeInterval interval;
    static_assert(sizeof(interval) == sizeof(uint64_t));
    memcpy(&interval,
        &call.slots[LC32FoundationDelayedTimerIntervalSlot],
        sizeof(interval));
    if(!target || !selector) return 0;

    NSTimer *timer = [NSTimer timerWithTimeInterval:interval
        target:target selector:selector userInfo:nil repeats:NO];
    return timer.guest_self;
}

__END_DECLS
