#import <LC32/LC32.h>
#import <CoreFoundation/CoreFoundation+LC32.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

const CFAllocatorRef kCFAllocatorDefault = NULL;

// Set CF version to iOS 10.3.3
double kCFCoreFoundationVersionNumber = (double)1349.7;

@interface NSObject (LC32OpaqueCFOwnership)
- (void)LC32_releaseGuestOwnershipOnly;
@end

@implementation __NSCFType
- (BOOL)isEqual:(id)other {
    if(self == other) return YES;
    return other && LC32_CF_CALL(LC32CoreFoundationOpEqual,
        self.host_self, [other host_self]);
}

- (NSUInteger)hash {
    return (NSUInteger)LC32_CF_CALL(LC32CoreFoundationOpHash, self.host_self);
}

- (NSString *)description {
    return [(NSString *)LC32_CF_CALL(LC32CoreFoundationOpCopyDescription,
        self.host_self) autorelease];
}

- (instancetype)retain {
    return (id)LC32_CF_CALL(LC32CoreFoundationOpRetain, self.host_self);
}

- (oneway void)release {
    const uint64_t host = self.host_self;
    // Remove guest ownership (and the mapping if final) before consuming the
    // paired native +1. Opaque CF objects have no native-owned guest pin.
    [self LC32_releaseGuestOwnershipOnly];
    LC32_CF_CALL(LC32CoreFoundationOpRelease, host);
}
@end

@implementation __NSCFString
@end
@implementation __NSCFConstantString

/*
 * Compiler-emitted CF/NSString literals live in Mach-O __cfstring storage;
 * they are not heap objects.  NSObject's LC32 ownership bridge must never
 * forward a final release for one of them or the guest runtime will try to
 * free an address inside the image.
 */
- (instancetype)retain {
    return self;
}

- (oneway void)release {
}

- (instancetype)autorelease {
    return self;
}

- (NSUInteger)retainCount {
    return NSUIntegerMax;
}

- (BOOL)_tryRetain {
    return YES;
}

- (BOOL)_isDeallocating {
    return NO;
}

- (BOOL)allowsWeakReference {
    return YES;
}

- (BOOL)retainWeakReference {
    return YES;
}

@end
// clang doesn't support alias on darwin, but we can use this truck
__asm__(" \n \
.section	__DATA,__objc_data \n \
.global ___CFConstantStringClassReference \n \
___CFConstantStringClassReference = _OBJC_CLASS_$___NSCFConstantString \
");

// For convenience, most CF functions are shims of Objective-C
CFURLRef CFURLCreateWithFileSystemPath(CFAllocatorRef allocator, CFStringRef filePath, CFURLPathStyle pathStyle, Boolean isDirectory) {
    (void)allocator;
    if(!filePath) return NULL;
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateWithFileSystemPath,
        LC32_CF_HOST(filePath), LC32_CF_U32(pathStyle),
        LC32_CF_U32(isDirectory));
}

CFURLRef CFURLCreateWithFileSystemPathRelativeToBase(
        CFAllocatorRef allocator, CFStringRef filePath,
        CFURLPathStyle pathStyle, Boolean isDirectory, CFURLRef baseURL) {
    (void)allocator;
    if(!filePath) return NULL;
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateWithFileSystemPathRelativeToBase,
        LC32_CF_HOST(filePath), LC32_CF_U32(pathStyle),
        LC32_CF_U32(isDirectory), LC32_CF_HOST(baseURL));
}

CFURLRef CFURLCreateFromFileSystemRepresentation(
        CFAllocatorRef allocator, const UInt8 *buffer,
        CFIndex bufferLength, Boolean isDirectory) {
    (void)allocator;
    if(bufferLength < 0 || (bufferLength && !buffer)) return NULL;
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateFromFileSystemRepresentation,
        LC32_CF_U32((uintptr_t)buffer), LC32_CF_U32(bufferLength),
        LC32_CF_U32(isDirectory));
}

CFURLRef CFURLCreateFromFileSystemRepresentationRelativeToBase(
        CFAllocatorRef allocator, const UInt8 *buffer,
        CFIndex bufferLength, Boolean isDirectory, CFURLRef baseURL) {
    (void)allocator;
    if(bufferLength < 0 || (bufferLength && !buffer)) return NULL;
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateFromFileSystemRepresentationRelativeToBase,
        LC32_CF_U32((uintptr_t)buffer), LC32_CF_U32(bufferLength),
        LC32_CF_U32(isDirectory), LC32_CF_HOST(baseURL));
}

CFURLRef CFURLCreateWithString(CFAllocatorRef allocator,
                               CFStringRef URLString,
                               CFURLRef baseURL) {
    (void)allocator;
    if(!URLString) return NULL;
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateWithString,
        LC32_CF_HOST(URLString), LC32_CF_HOST(baseURL));
}

CFURLRef CFURLCreateWithBytes(CFAllocatorRef allocator,
                              const UInt8 *URLBytes, CFIndex length,
                              CFStringEncoding encoding,
                              CFURLRef baseURL) {
    (void)allocator;
    if(length < 0 || (uint64_t)length > INT32_MAX ||
       (length && !URLBytes)) return NULL;
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateWithBytes,
        LC32_CF_U32((uintptr_t)URLBytes), LC32_CF_U32(length),
        LC32_CF_U32(encoding), LC32_CF_HOST(baseURL));
}

CFURLRef CFURLCreateAbsoluteURLWithBytes(CFAllocatorRef allocator,
        const UInt8 *relativeURLBytes, CFIndex length,
        CFStringEncoding encoding, CFURLRef baseURL,
        Boolean useCompatibilityMode) {
    (void)allocator;
    if(length < 0 || (length && !relativeURLBytes)) return NULL;
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateAbsoluteURLWithBytes,
        LC32_CF_U32((uintptr_t)relativeURLBytes), LC32_CF_U32(length),
        LC32_CF_U32(encoding), LC32_CF_HOST(baseURL),
        LC32_CF_U32(useCompatibilityMode));
}

CFStringRef CFURLCopyPathExtension(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyPathExtension,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyFileSystemPath(CFURLRef url,
                                    CFURLPathStyle pathStyle) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyFileSystemPath,
        LC32_CF_HOST(url), LC32_CF_U32(pathStyle)) : NULL;
}

CFTypeID CFURLGetTypeID(void) {
    return (CFTypeID)LC32_CF_CALL0(
        LC32CoreFoundationOpURLGetTypeID);
}

CFStringRef CFURLGetString(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLGetString,
        LC32_CF_HOST(url)) : NULL;
}

CFURLRef CFURLGetBaseURL(CFURLRef url) {
    return url ? (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLGetBaseURL,
        LC32_CF_HOST(url)) : NULL;
}

Boolean CFURLCanBeDecomposed(CFURLRef url) {
    return url && LC32_CF_CALL(
        LC32CoreFoundationOpURLCanBeDecomposed,
        LC32_CF_HOST(url));
}

CFURLRef CFURLCopyAbsoluteURL(CFURLRef url) {
    return url ? (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyAbsoluteURL,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyScheme(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyScheme,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyHostName(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyHostName,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyNetLocation(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyNetLocation,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyPath(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyPath,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyStrictPath(CFURLRef url, Boolean *isAbsolute) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyStrictPath,
        LC32_CF_HOST(url), LC32_CF_U32((uintptr_t)isAbsolute)) : NULL;
}

CFStringRef CFURLCopyResourceSpecifier(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyResourceSpecifier,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyUserName(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyUserName,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyPassword(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyPassword,
        LC32_CF_HOST(url)) : NULL;
}

CFStringRef CFURLCopyQueryString(
        CFURLRef url, CFStringRef charactersToLeaveEscaped) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyQueryString,
        LC32_CF_HOST(url), LC32_CF_HOST(charactersToLeaveEscaped)) : NULL;
}

CFStringRef CFURLCopyParameterString(
        CFURLRef url, CFStringRef charactersToLeaveEscaped) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyParameterString,
        LC32_CF_HOST(url), LC32_CF_HOST(charactersToLeaveEscaped)) : NULL;
}

CFStringRef CFURLCopyFragment(
        CFURLRef url, CFStringRef charactersToLeaveEscaped) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyFragment,
        LC32_CF_HOST(url), LC32_CF_HOST(charactersToLeaveEscaped)) : NULL;
}

CFStringRef CFURLCopyLastPathComponent(CFURLRef url) {
    return url ? (CFStringRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyLastPathComponent,
        LC32_CF_HOST(url)) : NULL;
}

SInt32 CFURLGetPortNumber(CFURLRef url) {
    return url ? (SInt32)LC32_CF_CALL(
        LC32CoreFoundationOpURLGetPortNumber,
        LC32_CF_HOST(url)) : -1;
}

Boolean CFURLHasDirectoryPath(CFURLRef url) {
    return url && LC32_CF_CALL(
        LC32CoreFoundationOpURLHasDirectoryPath,
        LC32_CF_HOST(url));
}

CFURLRef CFURLCreateCopyAppendingPathComponent(
        CFAllocatorRef allocator, CFURLRef url,
        CFStringRef pathComponent, Boolean isDirectory) {
    (void)allocator;
    return url && pathComponent ? (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateCopyAppendingPathComponent,
        LC32_CF_HOST(url), LC32_CF_HOST(pathComponent),
        LC32_CF_U32(isDirectory)) : NULL;
}

CFURLRef CFURLCreateCopyDeletingLastPathComponent(
        CFAllocatorRef allocator, CFURLRef url) {
    (void)allocator;
    return url ? (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateCopyDeletingLastPathComponent,
        LC32_CF_HOST(url)) : NULL;
}

CFURLRef CFURLCreateCopyAppendingPathExtension(
        CFAllocatorRef allocator, CFURLRef url, CFStringRef extension) {
    (void)allocator;
    return url && extension ? (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateCopyAppendingPathExtension,
        LC32_CF_HOST(url), LC32_CF_HOST(extension)) : NULL;
}

CFURLRef CFURLCreateCopyDeletingPathExtension(
        CFAllocatorRef allocator, CFURLRef url) {
    (void)allocator;
    return url ? (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateCopyDeletingPathExtension,
        LC32_CF_HOST(url)) : NULL;
}

Boolean CFURLGetFileSystemRepresentation(
        CFURLRef url, Boolean resolveAgainstBase,
        UInt8 *buffer, CFIndex maxBufferLength) {
    if(!url || maxBufferLength < 0 ||
       (maxBufferLength && !buffer)) return false;
    return LC32_CF_CALL(
        LC32CoreFoundationOpURLGetFileSystemRepresentation,
        LC32_CF_HOST(url), LC32_CF_U32(resolveAgainstBase),
        LC32_CF_U32((uintptr_t)buffer),
        LC32_CF_U32(maxBufferLength));
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/*
 * Deprecated CFURLAccess file resource helpers (Zenonia 1-4 size resource
 * reads with CFURLCreatePropertyFromResource; Breakpad in games like Horn
 * reads /System/Library/CoreServices/SystemVersion.plist with
 * CFURLCreateDataAndPropertiesFromResource; WhiteRaccoon calls
 * CFURLDestroyResource). Only file URLs were supported on iOS, so answer
 * through guest POSIX calls on the URL's translated file-system path.
 */
static SInt32 LC32CFURLErrorFromErrno(int err) {
    switch(err) {
        case ENOENT:
        case ENOTDIR:
            return kCFURLResourceNotFoundError;
        case EACCES:
        case EPERM:
        case EROFS:
            return kCFURLResourceAccessViolationError;
        default:
            return kCFURLUnknownError;
    }
}

static Boolean LC32CFURLGetFilePath(CFURLRef url, char path[PATH_MAX],
                                    SInt32 *errorCode) {
    if(!url) {
        if(errorCode) *errorCode = kCFURLImproperArgumentsError;
        return false;
    }
    CFURLRef absolute = CFURLCopyAbsoluteURL(url);
    CFStringRef scheme = absolute ? CFURLCopyScheme(absolute) : NULL;
    if(absolute) CFRelease(absolute);
    if(!scheme) {
        if(errorCode) *errorCode = kCFURLImproperArgumentsError;
        return false;
    }
    const CFComparisonResult cmp = CFStringCompare(
        scheme, CFSTR("file"), kCFCompareCaseInsensitive);
    CFRelease(scheme);
    if(cmp != kCFCompareEqualTo) {
        if(errorCode) *errorCode = kCFURLUnknownSchemeError;
        return false;
    }
    if(!CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, PATH_MAX)) {
        if(errorCode) *errorCode = kCFURLUnknownError;
        return false;
    }
    return true;
}

static CFArrayRef LC32CFURLCopyDirectoryContents(CFAllocatorRef allocator,
                                                 const char *path,
                                                 SInt32 *errorCode) {
    DIR *dir = opendir(path);
    if(!dir) {
        if(errorCode) *errorCode = LC32CFURLErrorFromErrno(errno);
        return NULL;
    }
    CFMutableArrayRef contents = CFArrayCreateMutable(
        allocator, 0, &kCFTypeArrayCallBacks);
    if(!contents) {
        closedir(dir);
        if(errorCode) *errorCode = kCFURLUnknownError;
        return NULL;
    }
    const size_t baseLen = strlen(path);
    const BOOL needsSlash = baseLen == 0 || path[baseLen - 1] != '/';
    struct dirent *entry = NULL;
    int readErrno = 0;
    for(;;) {
        errno = 0;
        entry = readdir(dir);
        if(!entry) {
            readErrno = errno;
            break;
        }
        if(strcmp(entry->d_name, ".") == 0 ||
           strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        char childPath[PATH_MAX];
        const int written = snprintf(childPath, sizeof(childPath),
            needsSlash ? "%s/%s" : "%s%s", path, entry->d_name);
        if(written < 0 || (size_t)written >= sizeof(childPath)) continue;
        Boolean isDirectory = false;
        if(entry->d_type == DT_DIR) {
            isDirectory = true;
        } else if(entry->d_type == DT_UNKNOWN || entry->d_type == DT_LNK) {
            struct stat childInfo;
            if(stat(childPath, &childInfo) == 0 &&
               S_ISDIR(childInfo.st_mode)) {
                isDirectory = true;
            }
        }
        CFURLRef childURL = CFURLCreateFromFileSystemRepresentation(
            allocator, (const UInt8 *)childPath, (CFIndex)written,
            isDirectory);
        if(childURL) {
            CFArrayAppendValue(contents, childURL);
            CFRelease(childURL);
        }
    }
    closedir(dir);
    if(readErrno != 0) {
        CFRelease(contents);
        if(errorCode) *errorCode = LC32CFURLErrorFromErrno(readErrno);
        return NULL;
    }
    return contents;
}

static CFTypeRef LC32CFURLCopyFileProperty(
        CFAllocatorRef allocator, const char *path, BOOL exists,
        int statErrno, const struct stat *info, CFStringRef property,
        SInt32 *errorCode) {
    if(!property) {
        if(errorCode) *errorCode = kCFURLImproperArgumentsError;
        return NULL;
    }
    if(CFEqual(property, kCFURLFileExists))
        return CFRetain(exists ? kCFBooleanTrue : kCFBooleanFalse);
    if(!exists) {
        if(errorCode) *errorCode = LC32CFURLErrorFromErrno(statErrno);
        return NULL;
    }
    if(CFEqual(property, kCFURLFileLength)) {
        const SInt64 length = info->st_size;
        return CFNumberCreate(allocator, kCFNumberSInt64Type, &length);
    }
    if(CFEqual(property, kCFURLFilePOSIXMode)) {
        const SInt32 mode = info->st_mode;
        return CFNumberCreate(allocator, kCFNumberSInt32Type, &mode);
    }
    if(CFEqual(property, kCFURLFileOwnerID)) {
        const SInt32 owner = info->st_uid;
        return CFNumberCreate(allocator, kCFNumberSInt32Type, &owner);
    }
    if(CFEqual(property, kCFURLFileLastModificationTime)) {
        return CFDateCreate(allocator, (CFAbsoluteTime)info->st_mtimespec.tv_sec -
            kCFAbsoluteTimeIntervalSince1970 +
            info->st_mtimespec.tv_nsec / 1.0e9);
    }
    if(CFEqual(property, kCFURLFileDirectoryContents)) {
        if(!S_ISDIR(info->st_mode)) {
            if(errorCode) *errorCode = kCFURLPropertyKeyUnavailableError;
            return NULL;
        }
        return LC32CFURLCopyDirectoryContents(allocator, path, errorCode);
    }
    if(errorCode) *errorCode = kCFURLUnknownPropertyKeyError;
    return NULL;
}

static CFDataRef LC32CFURLReadFileData(CFAllocatorRef allocator,
                                       const char *path,
                                       const struct stat *info,
                                       SInt32 *errorCode) {
    if(!S_ISREG(info->st_mode)) {
        if(errorCode) *errorCode = kCFURLUnknownError;
        return NULL;
    }
    const int fd = open(path, O_RDONLY | O_NONBLOCK);
    if(fd < 0) {
        if(errorCode) *errorCode = LC32CFURLErrorFromErrno(errno);
        return NULL;
    }
    const size_t maxBytes = 256u * 1024u * 1024u;
    struct stat fdInfo;
    if(fstat(fd, &fdInfo) != 0) {
        const int fstatErrno = errno;
        close(fd);
        if(errorCode) *errorCode = LC32CFURLErrorFromErrno(fstatErrno);
        return NULL;
    }
    if(!S_ISREG(fdInfo.st_mode)) {
        close(fd);
        if(errorCode) *errorCode = kCFURLUnknownError;
        return NULL;
    }
    size_t capacity = 4096;
    if(fdInfo.st_size > 0) {
        if((uint64_t)fdInfo.st_size > maxBytes) {
            close(fd);
            if(errorCode) *errorCode = kCFURLUnknownError;
            return NULL;
        }
        capacity = (size_t)fdInfo.st_size < maxBytes
            ? (size_t)fdInfo.st_size + 1 : maxBytes;
    }
    UInt8 *buffer = malloc(capacity);
    if(!buffer) {
        close(fd);
        if(errorCode) *errorCode = kCFURLUnknownError;
        return NULL;
    }
    size_t total = 0;
    Boolean readOK = true;
    for(;;) {
        if(total == capacity) {
            if(capacity == maxBytes) {
                UInt8 extra = 0;
                ssize_t probe = read(fd, &extra, 1);
                if(probe < 0 && errno == EINTR) continue;
                if(probe != 0) {
                    if(errorCode) *errorCode = kCFURLUnknownError;
                    readOK = false;
                }
                break;
            }
            const size_t nextCapacity = capacity > maxBytes / 2
                ? maxBytes : capacity * 2;
            UInt8 *resized = realloc(buffer, nextCapacity);
            if(!resized) {
                if(errorCode) *errorCode = kCFURLUnknownError;
                readOK = false;
                break;
            }
            buffer = resized;
            capacity = nextCapacity;
        }
        const ssize_t n = read(fd, buffer + total, capacity - total);
        if(n < 0) {
            if(errno == EINTR) continue;
            if(errorCode) *errorCode = LC32CFURLErrorFromErrno(errno);
            readOK = false;
            break;
        }
        if(n == 0) break;
        total += (size_t)n;
    }
    close(fd);

    CFDataRef data = NULL;
    if(readOK) {
        data = CFDataCreate(allocator, total ? buffer : NULL, (CFIndex)total);
        if(!data && errorCode) *errorCode = kCFURLUnknownError;
    }
    free(buffer);
    return data;
}

Boolean CFURLCreateDataAndPropertiesFromResource(
        CFAllocatorRef alloc, CFURLRef url, CFDataRef *resourceData,
        CFDictionaryRef *properties, CFArrayRef desiredProperties,
        SInt32 *errorCode) {
    if(resourceData) *resourceData = NULL;
    if(properties) *properties = NULL;
    if(errorCode) *errorCode = 0;

    char path[PATH_MAX];
    SInt32 err = 0;
    if(!LC32CFURLGetFilePath(url, path, &err)) {
        if(errorCode) *errorCode = err;
        return false;
    }
    if(!resourceData && !properties) return true;

    struct stat info;
    errno = 0;
    const BOOL exists = stat(path, &info) == 0;
    const int statErrno = exists ? 0 : errno;
    Boolean ok = true;

    if(resourceData) {
        if(!exists) {
            err = LC32CFURLErrorFromErrno(statErrno);
            ok = false;
        } else {
            SInt32 dataErr = 0;
            *resourceData = LC32CFURLReadFileData(alloc, path, &info, &dataErr);
            if(!*resourceData) {
                ok = false;
                err = dataErr ? dataErr : kCFURLUnknownError;
            }
        }
    }

    if(properties) {
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
            alloc, 0, &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        if(!dict) {
            ok = false;
            if(err == 0) err = kCFURLUnknownError;
        } else if(desiredProperties) {
            const CFIndex count = CFArrayGetCount(desiredProperties);
            for(CFIndex i = 0; i < count; i++) {
                CFStringRef key = (CFStringRef)CFArrayGetValueAtIndex(
                    desiredProperties, i);
                SInt32 propErr = 0;
                CFTypeRef value = LC32CFURLCopyFileProperty(
                    alloc, path, exists, statErrno, &info, key, &propErr);
                if(value) {
                    CFDictionarySetValue(dict, key, value);
                    CFRelease(value);
                } else {
                    if(err == 0) err = propErr ? propErr : kCFURLUnknownError;
                }
            }
        } else {
            CFDictionarySetValue(dict, kCFURLFileExists,
                exists ? kCFBooleanTrue : kCFBooleanFalse);
            if(exists) {
                const CFStringRef defaultKeys[] = {
                    kCFURLFileLength,
                    kCFURLFilePOSIXMode,
                    kCFURLFileOwnerID,
                    kCFURLFileLastModificationTime,
                };
                for(size_t i = 0;
                    i < sizeof(defaultKeys) / sizeof(defaultKeys[0]); i++) {
                    SInt32 propErr = 0;
                    CFTypeRef value = LC32CFURLCopyFileProperty(
                        alloc, path, exists, statErrno, &info,
                        defaultKeys[i], &propErr);
                    if(value) {
                        CFDictionarySetValue(dict, defaultKeys[i], value);
                        CFRelease(value);
                    }
                }
                if(S_ISDIR(info.st_mode)) {
                    SInt32 dirErr = 0;
                    CFArrayRef contents = LC32CFURLCopyDirectoryContents(
                        alloc, path, &dirErr);
                    if(contents) {
                        CFDictionarySetValue(
                            dict, kCFURLFileDirectoryContents, contents);
                        CFRelease(contents);
                    } else if(err == 0) {
                        err = dirErr ? dirErr : kCFURLUnknownError;
                    }
                }
            }
        }
        *properties = dict;
    }

    if(errorCode) *errorCode = err;
    return ok;
}

static Boolean LC32CFURLWriteFileProperties(const char *path,
                                            CFDictionaryRef propertiesToWrite,
                                            SInt32 *errorCode) {
    const CFIndex count = CFDictionaryGetCount(propertiesToWrite);
    if(count <= 0) return true;
    const void **keys = malloc((size_t)count * sizeof(*keys));
    const void **values = malloc((size_t)count * sizeof(*values));
    if(!keys || !values) {
        free(keys);
        free(values);
        if(errorCode) *errorCode = kCFURLUnknownError;
        return false;
    }
    CFDictionaryGetKeysAndValues(propertiesToWrite, keys, values);
    Boolean ok = true;
    SInt32 err = 0;
    for(CFIndex i = 0; i < count; i++) {
        CFTypeRef key = (CFTypeRef)keys[i];
        CFTypeRef value = (CFTypeRef)values[i];
        if(!key) {
            ok = false;
            if(err == 0) err = kCFURLImproperArgumentsError;
            continue;
        }
        if(CFEqual(key, kCFURLFilePOSIXMode)) {
            mode_t mode = 0;
            Boolean valid = false;
            if(value && CFGetTypeID(value) == CFNumberGetTypeID()) {
                SInt32 numMode = 0;
                if(CFNumberGetValue((CFNumberRef)value,
                       kCFNumberSInt32Type, &numMode)) {
                    mode = (mode_t)numMode;
                    valid = true;
                }
            } else if(value && CFGetTypeID(value) == CFDataGetTypeID()) {
                const CFIndex dataLen = CFDataGetLength((CFDataRef)value);
                if(dataLen == (CFIndex)sizeof(mode_t)) {
                    const UInt8 *raw = CFDataGetBytePtr((CFDataRef)value);
                    if(raw) {
                        memcpy(&mode, raw, sizeof(mode_t));
                        valid = true;
                    }
                } else if(dataLen == (CFIndex)sizeof(SInt32)) {
                    const UInt8 *raw = CFDataGetBytePtr((CFDataRef)value);
                    if(raw) {
                        SInt32 numMode = 0;
                        memcpy(&numMode, raw, sizeof(numMode));
                        mode = (mode_t)numMode;
                        valid = true;
                    }
                }
            }
            if(!valid) {
                ok = false;
                if(err == 0) err = kCFURLImproperArgumentsError;
            } else if(chmod(path, mode) != 0) {
                ok = false;
                if(err == 0) err = LC32CFURLErrorFromErrno(errno);
            }
        } else if(CFEqual(key, kCFURLFileExists) ||
                  CFEqual(key, kCFURLFileDirectoryContents) ||
                  CFEqual(key, kCFURLFileLength) ||
                  CFEqual(key, kCFURLFileLastModificationTime) ||
                  CFEqual(key, kCFURLFileOwnerID)) {
            ok = false;
            if(err == 0) err = kCFURLPropertyKeyUnavailableError;
        } else {
            ok = false;
            if(err == 0) err = kCFURLUnknownPropertyKeyError;
        }
    }
    free(keys);
    free(values);
    if(!ok && errorCode && *errorCode == 0) *errorCode = err;
    return ok;
}

Boolean CFURLWriteDataAndPropertiesToResource(
        CFURLRef url, CFDataRef dataToWrite,
        CFDictionaryRef propertiesToWrite, SInt32 *errorCode) {
    if(errorCode) *errorCode = 0;
    char path[PATH_MAX];
    SInt32 err = 0;
    if(!LC32CFURLGetFilePath(url, path, &err)) {
        if(errorCode) *errorCode = err;
        return false;
    }

    Boolean ok = true;
    if(dataToWrite) {
        const CFIndex length = CFDataGetLength(dataToWrite);
        if(length < 0) {
            err = kCFURLImproperArgumentsError;
            ok = false;
        } else if(CFURLHasDirectoryPath(url)) {
            if(mkdir(path, 0777) != 0) {
                err = LC32CFURLErrorFromErrno(errno);
                ok = false;
            }
        } else {
            const UInt8 *bytes = length > 0
                ? CFDataGetBytePtr(dataToWrite) : NULL;
            if(length > 0 && !bytes) {
                err = kCFURLUnknownError;
                ok = false;
            } else {
                const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
                if(fd < 0) {
                    err = LC32CFURLErrorFromErrno(errno);
                    ok = false;
                } else {
                    size_t remaining = (size_t)length;
                    while(remaining > 0) {
                        const ssize_t written = write(fd, bytes, remaining);
                        if(written < 0) {
                            if(errno == EINTR) continue;
                            err = LC32CFURLErrorFromErrno(errno);
                            ok = false;
                            break;
                        }
                        bytes += written;
                        remaining -= (size_t)written;
                    }
                    if(close(fd) != 0 && ok) {
                        err = LC32CFURLErrorFromErrno(errno);
                        ok = false;
                    }
                }
            }
        }
    }

    if(ok && propertiesToWrite) {
        ok = LC32CFURLWriteFileProperties(path, propertiesToWrite, &err);
    }

    if(errorCode) *errorCode = err;
    return ok;
}

Boolean CFURLDestroyResource(CFURLRef url, SInt32 *errorCode) {
    if(errorCode) *errorCode = 0;
    char path[PATH_MAX];
    SInt32 err = 0;
    if(!LC32CFURLGetFilePath(url, path, &err)) {
        if(errorCode) *errorCode = err;
        return false;
    }
    const int rc = CFURLHasDirectoryPath(url) ? rmdir(path) : unlink(path);
    if(rc != 0) {
        if(errorCode) *errorCode = LC32CFURLErrorFromErrno(errno);
        return false;
    }
    return true;
}

CFTypeRef CFURLCreatePropertyFromResource(
        CFAllocatorRef allocator, CFURLRef url, CFStringRef property,
        SInt32 *errorCode) {
    if(errorCode) *errorCode = 0;
    if(!url || !property) {
        if(errorCode) *errorCode = kCFURLImproperArgumentsError;
        return NULL;
    }
    char path[PATH_MAX];
    SInt32 err = 0;
    if(!LC32CFURLGetFilePath(url, path, &err)) {
        if(errorCode) *errorCode = err;
        return NULL;
    }
    struct stat info;
    errno = 0;
    const BOOL exists = stat(path, &info) == 0;
    const int statErrno = exists ? 0 : errno;
    CFTypeRef value = LC32CFURLCopyFileProperty(
        allocator, path, exists, statErrno, &info, property, &err);
    if(!value && errorCode) *errorCode = err;
    return value;
}

#pragma clang diagnostic pop

CFIndex CFURLGetBytes(CFURLRef url, UInt8 *buffer,
                      CFIndex bufferLength) {
    if(!url || bufferLength < 0) return -1;
    return (CFIndex)(int32_t)LC32_CF_CALL(
        LC32CoreFoundationOpURLGetBytes,
        LC32_CF_HOST(url), LC32_CF_U32((uintptr_t)buffer),
        LC32_CF_U32(bufferLength));
}

CFRange CFURLGetByteRangeForComponent(
        CFURLRef url, CFURLComponentType component,
        CFRange *rangeIncludingSeparators) {
    CFRange result = CFRangeMake(kCFNotFound, 0);
    if(!url) {
        if(rangeIncludingSeparators)
            *rangeIncludingSeparators = result;
        return result;
    }
    if(!LC32_CF_CALL(
            LC32CoreFoundationOpURLGetByteRangeForComponent,
            LC32_CF_HOST(url), LC32_CF_U32(component),
            LC32_CF_U32((uintptr_t)&result),
            LC32_CF_U32((uintptr_t)rangeIncludingSeparators))) {
        result = CFRangeMake(kCFNotFound, 0);
        if(rangeIncludingSeparators)
            *rangeIncludingSeparators = result;
    }
    return result;
}

Boolean CFURLSetResourcePropertyForKey(
        CFURLRef url, CFStringRef key, CFTypeRef propertyValue,
        CFErrorRef *error) {
    if(!url || !key) {
        if(error) *error = NULL;
        return false;
    }
    return LC32_CF_CALL(
        LC32CoreFoundationOpURLSetResourcePropertyForKey,
        LC32_CF_HOST(url), LC32_CF_HOST(key),
        LC32_CF_HOST(propertyValue), LC32_CF_U32((uintptr_t)error));
}

Boolean CFURLCopyResourcePropertyForKey(
        CFURLRef url, CFStringRef key, void *propertyValueTypeRefPtr,
        CFErrorRef *error) {
    if(!url || !key || !propertyValueTypeRefPtr) {
        if(error) *error = NULL;
        return false;
    }
    return LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyResourcePropertyForKey,
        LC32_CF_HOST(url), LC32_CF_HOST(key),
        LC32_CF_U32((uintptr_t)propertyValueTypeRefPtr),
        LC32_CF_U32((uintptr_t)error));
}

CFDictionaryRef CFURLCopyResourcePropertiesForKeys(
        CFURLRef url, CFArrayRef keys, CFErrorRef *error) {
    if(!url || !keys) {
        if(error) *error = NULL;
        return NULL;
    }
    return (CFDictionaryRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCopyResourcePropertiesForKeys,
        LC32_CF_HOST(url), LC32_CF_HOST(keys),
        LC32_CF_U32((uintptr_t)error));
}

Boolean CFURLSetResourcePropertiesForKeys(
        CFURLRef url, CFDictionaryRef keyedPropertyValues,
        CFErrorRef *error) {
    if(!url || !keyedPropertyValues) {
        if(error) *error = NULL;
        return false;
    }
    return LC32_CF_CALL(
        LC32CoreFoundationOpURLSetResourcePropertiesForKeys,
        LC32_CF_HOST(url), LC32_CF_HOST(keyedPropertyValues),
        LC32_CF_U32((uintptr_t)error));
}

Boolean CFURLResourceIsReachable(CFURLRef url, CFErrorRef *error) {
    if(!url) {
        if(error) *error = NULL;
        return false;
    }
    return LC32_CF_CALL(
        LC32CoreFoundationOpURLResourceIsReachable,
        LC32_CF_HOST(url), LC32_CF_U32((uintptr_t)error));
}

CFURLRef CFURLCreateFilePathURL(
        CFAllocatorRef allocator, CFURLRef url, CFErrorRef *error) {
    (void)allocator;
    if(!url) {
        if(error) *error = NULL;
        return NULL;
    }
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateFilePathURL,
        LC32_CF_HOST(url), LC32_CF_U32((uintptr_t)error));
}

CFURLRef CFURLCreateFileReferenceURL(
        CFAllocatorRef allocator, CFURLRef url, CFErrorRef *error) {
    (void)allocator;
    if(!url) {
        if(error) *error = NULL;
        return NULL;
    }
    return (CFURLRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateFileReferenceURL,
        LC32_CF_HOST(url), LC32_CF_U32((uintptr_t)error));
}

CFDataRef CFURLCreateData(CFAllocatorRef allocator, CFURLRef url,
                          CFStringEncoding encoding,
                          Boolean escapeWhitespace) {
    (void)allocator;
    return url ? (CFDataRef)LC32_CF_CALL(
        LC32CoreFoundationOpURLCreateData,
        LC32_CF_HOST(url), LC32_CF_U32(encoding),
        LC32_CF_U32(escapeWhitespace)) : NULL;
}

Boolean CFURLIsFileReferenceURL(CFURLRef url) {
    return url && LC32_CF_CALL(
        LC32CoreFoundationOpURLIsFileReferenceURL,
        LC32_CF_HOST(url));
}

void CFURLClearResourcePropertyCacheForKey(CFURLRef url, CFStringRef key) {
    if(url && key) {
        (void)LC32_CF_CALL(
            LC32CoreFoundationOpURLClearResourcePropertyCacheForKey,
            LC32_CF_HOST(url), LC32_CF_HOST(key));
    }
}

void CFURLClearResourcePropertyCache(CFURLRef url) {
    if(url) {
        (void)LC32_CF_CALL(
            LC32CoreFoundationOpURLClearResourcePropertyCache,
            LC32_CF_HOST(url));
    }
}

void CFURLSetTemporaryResourcePropertyForKey(
        CFURLRef url, CFStringRef key, CFTypeRef propertyValue) {
    if(url && key) {
        (void)LC32_CF_CALL(
            LC32CoreFoundationOpURLSetTemporaryResourcePropertyForKey,
            LC32_CF_HOST(url), LC32_CF_HOST(key),
            LC32_CF_HOST(propertyValue));
    }
}

Boolean CFURLStartAccessingSecurityScopedResource(CFURLRef url) {
    return url && LC32_CF_CALL(
        LC32CoreFoundationOpURLStartAccessingSecurityScopedResource,
        LC32_CF_HOST(url));
}

void CFURLStopAccessingSecurityScopedResource(CFURLRef url) {
    if(url) {
        (void)LC32_CF_CALL(
            LC32CoreFoundationOpURLStopAccessingSecurityScopedResource,
            LC32_CF_HOST(url));
    }
}

void CFRelease(CFTypeRef ref) {
    [(id)ref release];
}

CFTypeRef CFRetain(CFTypeRef ref) {
    return [(id)ref retain];
}

__attribute__((constructor)) void __CFInitialize() {
    // Since we cannot link against Foundation, we have to change superclass at runtime
    // Actually, internal CF does this aswel
    class_setSuperclass(objc_getClass("__NSCFString"), objc_getClass("NSMutableString"));
}
