@import Foundation;
@import Security;

#include "bridge.h"
#include "../../GuestFrameworks/Security/LC32SecurityBridge.h"

#include <cstddef>
#include <cstdint>

extern "C" CFDictionaryRef SecTrustCopyInfo(SecTrustRef trust)
    __attribute__((weak_import));

namespace {

static_assert(sizeof(LC32SecurityCall) == 32,
              "Security bridge ABI must remain ARM32-compatible");
static_assert(offsetof(LC32SecurityCall, slots) == 16,
              "Security bridge slot offset changed");

bool ReadSecurityCall(u32 guestAddress, LC32SecurityCall &call) {
    if(!guestAddress ||
       static_cast<uint64_t>(guestAddress) + sizeof(call) >
           static_cast<uint64_t>(UINT32_MAX) + 1 ||
       Dynarmic_mem_1read(guestAddress, sizeof(call),
           reinterpret_cast<char *>(&call)) != 0) {
        return false;
    }
    return call.version == LC32SecurityABIVersion &&
        call.slotCount <= LC32SecurityMaxSlots && call.reserved == 0;
}

bool WriteSecurityStatus(u32 guestAddress, OSStatus status) {
    const uint64_t statusAddress = static_cast<uint64_t>(guestAddress) +
        offsetof(LC32SecurityCall, status);
    if(statusAddress + sizeof(int32_t) >
       static_cast<uint64_t>(UINT32_MAX) + 1) {
        return false;
    }
    int32_t value = status;
    return Dynarmic_mem_1write(static_cast<u32>(statusAddress),
        sizeof(value), reinterpret_cast<char *>(&value)) == 0;
}

bool RequireSlots(const LC32SecurityCall &call, uint32_t count) {
    return call.slotCount == count;
}

template<typename T>
T SlotHostObject(const LC32SecurityCall &call, size_t index) {
    return reinterpret_cast<T>(
        static_cast<uintptr_t>(call.slots[index]));
}

class SecurityHostCallQuiescence {
public:
    SecurityHostCallQuiescence()
        : active(Dynarmic_guest_host_call_quiescence_begin()) {}

    ~SecurityHostCallQuiescence() {
        if(active) Dynarmic_guest_host_call_quiescence_end();
    }

    SecurityHostCallQuiescence(const SecurityHostCallQuiescence &) = delete;
    SecurityHostCallQuiescence &operator=(
        const SecurityHostCallQuiescence &) = delete;

private:
    bool active;
};

/*
 * Guests run under LiveContainer's (or the bare simulator app's) entitlements,
 * not their own. Their keychain calls can then fail with
 * errSecMissingEntitlement, and old games that keep a device ID in the
 * keychain mint a new one every launch. Gamevil games (Zenonia 5) refuse
 * their own saves once that ID changes, then loop forever on the rejected
 * data. Keep generic/internet password items the host keychain will not
 * hold in a private per-container plist, so they persist like the keychain.
 */
NSString *FallbackKeychainPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Preferences/LC32Keychain.plist"];
}

NSMutableArray *FallbackKeychainItems(void) {
    static NSMutableArray *items;
    if(!items) {
        NSArray *stored = [NSArray arrayWithContentsOfFile:
            FallbackKeychainPath()];
        items = stored ? [stored mutableCopy] : [NSMutableArray new];
    }
    return items;
}

void SaveFallbackKeychain(void) {
    NSString *path = FallbackKeychainPath();
    [NSFileManager.defaultManager
        createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    [FallbackKeychainItems() writeToFile:path atomically:YES];
}

bool FallbackSupportsClass(NSDictionary *dictionary) {
    id itemClass = dictionary[(id)kSecClass];
    return [itemClass isEqual:(id)kSecClassGenericPassword] ||
        [itemClass isEqual:(id)kSecClassInternetPassword];
}

/* Item attributes are the plist-safe keys that are not search, return,
 * use or value parameters; the access group is ignored on purpose. */
bool FallbackIsItemAttribute(NSString *key, id value) {
    if(![key isKindOfClass:NSString.class] ||
            [key isEqualToString:(NSString *)kSecAttrAccessGroup] ||
            [key isEqualToString:(NSString *)kSecValueData] ||
            [key hasPrefix:@"m_"] || [key hasPrefix:@"r_"] ||
            [key hasPrefix:@"u_"] || [key hasPrefix:@"v_"]) return false;
    return [value isKindOfClass:NSString.class] ||
        [value isKindOfClass:NSData.class] ||
        [value isKindOfClass:NSNumber.class] ||
        [value isKindOfClass:NSDate.class];
}

bool FallbackItemMatches(NSDictionary *item, NSDictionary *query) {
    for(NSString *key in query) {
        id value = query[key];
        if((FallbackIsItemAttribute(key, value) ||
                [key isEqualToString:(NSString *)kSecClass]) &&
                ![item[key] isEqual:value]) return false;
    }
    return true;
}

NSArray *FallbackMatches(NSDictionary *query) {
    NSMutableArray *matches = [NSMutableArray array];
    for(NSDictionary *item in FallbackKeychainItems()) {
        if(FallbackItemMatches(item, query)) [matches addObject:item];
    }
    return matches;
}

id FallbackResultForItem(NSDictionary *item, NSDictionary *query) {
    const bool wantsData = [query[(id)kSecReturnData] boolValue];
    const bool wantsAttributes = [query[(id)kSecReturnAttributes] boolValue];
    if(wantsAttributes) {
        NSMutableDictionary *result = [[item mutableCopy] autorelease];
        if(!wantsData) [result removeObjectForKey:(id)kSecValueData];
        return result;
    }
    return wantsData ? item[(id)kSecValueData] : nil;
}

OSStatus FallbackCopyMatching(NSDictionary *query, CFTypeRef *result) {
    if(!FallbackSupportsClass(query)) return errSecItemNotFound;
    NSArray *matches = FallbackMatches(query);
    if(!matches.count) return errSecItemNotFound;
    if(!result) return errSecSuccess;
    id value;
    if([query[(id)kSecMatchLimit] isEqual:(id)kSecMatchLimitAll]) {
        NSMutableArray *all = [NSMutableArray array];
        for(NSDictionary *item in matches) {
            id one = FallbackResultForItem(item, query);
            if(one) [all addObject:one];
        }
        value = all;
    } else {
        value = FallbackResultForItem(matches.firstObject, query);
    }
    *result = value ? CFRetain((CFTypeRef)value) : nullptr;
    return errSecSuccess;
}

OSStatus FallbackAdd(NSDictionary *attributes) {
    if(!FallbackSupportsClass(attributes)) return errSecMissingEntitlement;
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    for(NSString *key in attributes) {
        id value = attributes[key];
        if(FallbackIsItemAttribute(key, value) ||
                [key isEqualToString:(NSString *)kSecClass] ||
                ([key isEqualToString:(NSString *)kSecValueData] &&
                 [value isKindOfClass:NSData.class])) {
            item[key] = value;
        }
    }
    NSMutableDictionary *identity = [NSMutableDictionary dictionary];
    for(NSString *key in @[(id)kSecClass, (id)kSecAttrAccount,
            (id)kSecAttrService, (id)kSecAttrServer]) {
        if(item[key]) identity[key] = item[key];
    }
    if(FallbackMatches(identity).count) return errSecDuplicateItem;
    [FallbackKeychainItems() addObject:item];
    SaveFallbackKeychain();
    return errSecSuccess;
}

OSStatus FallbackUpdate(NSDictionary *query, NSDictionary *attributes) {
    if(!FallbackSupportsClass(query)) return errSecItemNotFound;
    NSMutableArray *items = FallbackKeychainItems();
    bool updated = false;
    for(NSUInteger index = 0; index < items.count; ++index) {
        if(!FallbackItemMatches(items[index], query)) continue;
        NSMutableDictionary *item = [[items[index] mutableCopy] autorelease];
        for(NSString *key in attributes) {
            id value = attributes[key];
            if(FallbackIsItemAttribute(key, value) ||
                    ([key isEqualToString:(NSString *)kSecValueData] &&
                     [value isKindOfClass:NSData.class])) {
                item[key] = value;
            }
        }
        items[index] = item;
        updated = true;
    }
    if(!updated) return errSecItemNotFound;
    SaveFallbackKeychain();
    return errSecSuccess;
}

OSStatus FallbackDelete(NSDictionary *query) {
    if(!FallbackSupportsClass(query)) return errSecItemNotFound;
    NSArray *matches = FallbackMatches(query);
    if(!matches.count) return errSecItemNotFound;
    [FallbackKeychainItems() removeObjectsInArray:matches];
    SaveFallbackKeychain();
    return errSecSuccess;
}

OSStatus CallItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    SecurityHostCallQuiescence quiescence;
    OSStatus status = SecItemAdd(attributes, result);
    NSDictionary *dictionary = (NSDictionary *)attributes;
    if(status == errSecMissingEntitlement &&
            dictionary[(id)kSecAttrAccessGroup]) {
        /* The guest's own team access group (Gamevil's
         * "D2E48J33S9.gamevilGames") is never ours to use. */
        NSMutableDictionary *withoutGroup =
            [[dictionary mutableCopy] autorelease];
        [withoutGroup removeObjectForKey:(id)kSecAttrAccessGroup];
        status = SecItemAdd((CFDictionaryRef)withoutGroup, result);
    }
    if(status == errSecMissingEntitlement) {
        if(result) *result = nullptr;
        status = FallbackAdd(dictionary);
    }
    return status;
}

OSStatus CallItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    SecurityHostCallQuiescence quiescence;
    OSStatus status = SecItemCopyMatching(query, result);
    if(status == errSecMissingEntitlement ||
            status == errSecItemNotFound) {
        const OSStatus fallback =
            FallbackCopyMatching((NSDictionary *)query, result);
        if(fallback == errSecSuccess ||
                status == errSecMissingEntitlement) status = fallback;
    }
    return status;
}

OSStatus CallItemDelete(CFDictionaryRef query) {
    SecurityHostCallQuiescence quiescence;
    const OSStatus status = SecItemDelete(query);
    const OSStatus fallback = FallbackDelete((NSDictionary *)query);
    return status == errSecSuccess || fallback == errSecSuccess
        ? errSecSuccess
        : status == errSecMissingEntitlement ? fallback : status;
}

OSStatus CallItemUpdate(CFDictionaryRef query,
                        CFDictionaryRef attributes) {
    SecurityHostCallQuiescence quiescence;
    const OSStatus status = SecItemUpdate(query, attributes);
    if(status != errSecMissingEntitlement &&
            status != errSecItemNotFound) return status;
    const OSStatus fallback = FallbackUpdate((NSDictionary *)query,
        (NSDictionary *)attributes);
    return fallback == errSecSuccess || status == errSecMissingEntitlement
        ? fallback : status;
}

CFDictionaryRef CallTrustCopyInfo(SecTrustRef trust) {
    SecurityHostCallQuiescence quiescence;
    return SecTrustCopyInfo(trust);
}

u32 FinishOwnedResult(OSStatus &status, CFTypeRef nativeResult) {
    if(status != errSecSuccess) {
        if(nativeResult) CFRelease(nativeResult);
        return 0;
    }
    if(!nativeResult) return 0;

    const u32 guestResult =
        LC32GuestObjectForOwnedHostObject(nativeResult);
    if(!guestResult) status = errSecAllocate;
    return guestResult;
}

} // namespace

__BEGIN_DECLS

u32 LC32_Security_Dispatch(u32 opcodeValue, u32 guestCall, u32) {
    LC32SecurityCall call = {};
    if(!ReadSecurityCall(guestCall, call)) return 0;

    OSStatus status = errSecParam;
    u32 guestResult = 0;
    @autoreleasepool {
        switch(static_cast<LC32SecurityOpcode>(opcodeValue)) {
            case LC32SecurityOpItemAdd: {
                if(!RequireSlots(call, 2)) break;
                CFTypeRef nativeResult = nullptr;
                status = CallItemAdd(
                    SlotHostObject<CFDictionaryRef>(call, 0),
                    call.slots[1] ? &nativeResult : nullptr);
                guestResult = FinishOwnedResult(status, nativeResult);
                break;
            }
            case LC32SecurityOpItemCopyMatching: {
                if(!RequireSlots(call, 2)) break;
                CFTypeRef nativeResult = nullptr;
                status = CallItemCopyMatching(
                    SlotHostObject<CFDictionaryRef>(call, 0),
                    call.slots[1] ? &nativeResult : nullptr);
                guestResult = FinishOwnedResult(status, nativeResult);
                break;
            }
            case LC32SecurityOpItemDelete:
                if(RequireSlots(call, 1)) {
                    status = CallItemDelete(
                        SlotHostObject<CFDictionaryRef>(call, 0));
                }
                break;
            case LC32SecurityOpItemUpdate:
                if(RequireSlots(call, 2)) {
                    status = CallItemUpdate(
                        SlotHostObject<CFDictionaryRef>(call, 0),
                        SlotHostObject<CFDictionaryRef>(call, 1));
                }
                break;
            case LC32SecurityOpTrustCopyInfo: {
                if(!RequireSlots(call, 1)) break;
                if(!SecTrustCopyInfo) {
                    status = errSecUnimplemented;
                    break;
                }
                status = errSecSuccess;
                CFDictionaryRef nativeResult = CallTrustCopyInfo(
                    SlotHostObject<SecTrustRef>(call, 0));
                guestResult = FinishOwnedResult(status, nativeResult);
                break;
            }
            case LC32SecurityOpCertificateCreateWithData: {
                if(!RequireSlots(call, 1)) break;
                CFDataRef data = SlotHostObject<CFDataRef>(call, 0);
                if(!data || CFGetTypeID(data) != CFDataGetTypeID()) break;
                status = errSecSuccess;
                SecCertificateRef nativeResult =
                    SecCertificateCreateWithData(kCFAllocatorDefault, data);
                guestResult = FinishOwnedResult(status, nativeResult);
                break;
            }
            case LC32SecurityOpCertificateCopyData: {
                if(!RequireSlots(call, 1)) break;
                SecCertificateRef certificate =
                    SlotHostObject<SecCertificateRef>(call, 0);
                if(!certificate || CFGetTypeID(certificate) !=
                        SecCertificateGetTypeID()) break;
                status = errSecSuccess;
                CFDataRef nativeResult = SecCertificateCopyData(certificate);
                guestResult = FinishOwnedResult(status, nativeResult);
                break;
            }
        }
    }

    /*
     * If this write unexpectedly fails, the guest-side call retains its
     * initialized errSecUnimplemented status and releases guestResult before
     * returning.  That keeps the native Create/Copy ownership balanced.
     */
    (void)WriteSecurityStatus(guestCall, status);
    return guestResult;
}

__END_DECLS
