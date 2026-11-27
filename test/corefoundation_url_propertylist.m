#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int failures;

static void check(const char *name, BOOL condition) {
    printf("%s: %s\n", name, condition ? "PASS" : "FAIL");
    failures += !condition;
}

static void testAbsoluteURLBytes(void) {
    CFURLRef base = CFURLCreateWithString(kCFAllocatorDefault,
        CFSTR("https://example.test/a/"), NULL);
    const char relative[] = "../b?q=one%20two";
    CFURLRef absolute = CFURLCreateAbsoluteURLWithBytes(kCFAllocatorDefault,
        (const UInt8 *)relative, sizeof(relative) - 1,
        kCFStringEncodingUTF8, base, false);
    const UInt8 bounded[] = {'c', 'h', 'i', 'l', 'd', 'x'};
    CFURLRef exact = CFURLCreateAbsoluteURLWithBytes(kCFAllocatorDefault,
        bounded, 5, kCFStringEncodingUTF8, base, false);
    const char sameScheme[] = "https:child";
    CFURLRef strict = CFURLCreateAbsoluteURLWithBytes(kCFAllocatorDefault,
        (const UInt8 *)sameScheme, sizeof(sameScheme) - 1,
        kCFStringEncodingUTF8, base, false);
    CFURLRef compatible = CFURLCreateAbsoluteURLWithBytes(kCFAllocatorDefault,
        (const UInt8 *)sameScheme, sizeof(sameScheme) - 1,
        kCFStringEncodingUTF8, base, true);
    const UInt8 latin1[] = {'c', 'a', 'f', 0xe9};
    CFURLRef encoded = CFURLCreateAbsoluteURLWithBytes(kCFAllocatorDefault,
        latin1, sizeof(latin1), kCFStringEncodingISOLatin1, base, false);
    if(base) CFRelease(base);

    check("url-absolute-bytes-relative-owned", absolute &&
        [(NSString *)CFURLGetString(absolute)
            isEqualToString:@"https://example.test/b?q=one%20two"] &&
        !CFURLGetBaseURL(absolute));
    check("url-absolute-bytes-exact-length", exact &&
        [(NSString *)CFURLGetString(exact)
            isEqualToString:@"https://example.test/a/child"]);
    check("url-absolute-bytes-strict", strict &&
        [(NSString *)CFURLGetString(strict) isEqualToString:@"https:child"]);
    check("url-absolute-bytes-compatible", compatible &&
        [(NSString *)CFURLGetString(compatible)
            isEqualToString:@"https://example.test/a/child"]);
    check("url-absolute-bytes-encoding", encoded &&
        [[(NSURL *)encoded absoluteString] hasSuffix:@"/caf%C3%A9"]);
    if(absolute) CFRelease(absolute);
    if(exact) CFRelease(exact);
    if(strict) CFRelease(strict);
    if(compatible) CFRelease(compatible);
    if(encoded) CFRelease(encoded);
}

static void testURLAccessResources(void) {
    /* Breakpad pattern: read /System/Library/CoreServices/SystemVersion.plist
     * with an uninitialized resourceData out-parameter and parse it. */
    CFURLRef sysVerURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
        CFSTR("/System/Library/CoreServices/SystemVersion.plist"),
        kCFURLPOSIXPathStyle, false);
    CFDataRef sysVerData = (CFDataRef)(uintptr_t)0xdeadbeef;
    SInt32 err = -999;
    Boolean ok = CFURLCreateDataAndPropertiesFromResource(
        kCFAllocatorDefault, sysVerURL, &sysVerData, NULL, NULL, &err);
    CFPropertyListRef sysVerPlist = ok && sysVerData
        ? CFPropertyListCreateFromXMLData(kCFAllocatorDefault, sysVerData,
              kCFPropertyListImmutable, NULL)
        : NULL;
    CFStringRef productVersion = sysVerPlist &&
        CFGetTypeID(sysVerPlist) == CFDictionaryGetTypeID()
        ? (CFStringRef)CFDictionaryGetValue(
              (CFDictionaryRef)sysVerPlist, CFSTR("ProductVersion"))
        : NULL;
    check("url-access-system-version-read", ok && err == 0 && sysVerData &&
        CFDataGetLength(sysVerData) > 0 && productVersion &&
        CFStringGetLength(productVersion) > 0);
    if(sysVerPlist) CFRelease(sysVerPlist);
    if(sysVerData && sysVerData != (CFDataRef)(uintptr_t)0xdeadbeef)
        CFRelease(sysVerData);
    if(sysVerURL) CFRelease(sysVerURL);

    /* Write, read data + properties, read directory, and destroy resource. */
    NSString *baseDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"lc32-urlaccess-%d", (int)getpid()]];
    CFURLRef dirURL = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault, (CFStringRef)baseDir, kCFURLPOSIXPathStyle, true);
    CFDataRef emptyData = CFDataCreate(kCFAllocatorDefault, NULL, 0);
    err = -999;
    ok = CFURLWriteDataAndPropertiesToResource(dirURL, emptyData, NULL, &err);
    check("url-access-write-dir", ok && err == 0);
    err = 0;
    ok = CFURLWriteDataAndPropertiesToResource(dirURL, emptyData, NULL, &err);
    check("url-access-write-dir-exists-fails", !ok && err != 0);
    if(emptyData) CFRelease(emptyData);

    NSString *filePath = [baseDir stringByAppendingPathComponent:@"sample.bin"];
    CFURLRef fileURL = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault, (CFStringRef)filePath, kCFURLPOSIXPathStyle, false);
    const UInt8 payload[] = "HornCFURLAccess";
    CFDataRef writeData = CFDataCreate(
        kCFAllocatorDefault, payload, (CFIndex)(sizeof(payload) - 1));
    SInt32 modeVal = 0640;
    CFNumberRef modeNum = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberSInt32Type, &modeVal);
    CFMutableDictionaryRef writeProps = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(writeProps, kCFURLFilePOSIXMode, modeNum);
    err = -999;
    ok = CFURLWriteDataAndPropertiesToResource(
        fileURL, writeData, writeProps, &err);
    check("url-access-write-file", ok && err == 0);
    if(modeNum) CFRelease(modeNum);
    if(writeProps) CFRelease(writeProps);
    if(writeData) CFRelease(writeData);

    /* Unsupported property write must fail instead of succeeding silently. */
    CFMutableDictionaryRef badProps = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(badProps, CFSTR("BogusWriteKey"), kCFBooleanTrue);
    err = 0;
    ok = CFURLWriteDataAndPropertiesToResource(fileURL, NULL, badProps, &err);
    check("url-access-write-unknown-prop-fails",
        !ok && err == kCFURLUnknownPropertyKeyError);
    if(badProps) CFRelease(badProps);

    CFDataRef readData = (CFDataRef)(uintptr_t)0xdeadbeef;
    CFDictionaryRef readProps = (CFDictionaryRef)(uintptr_t)0xdeadbeef;
    err = -999;
    ok = CFURLCreateDataAndPropertiesFromResource(
        kCFAllocatorDefault, fileURL, &readData, &readProps, NULL, &err);
    const BOOL gotReadData = readData &&
        readData != (CFDataRef)(uintptr_t)0xdeadbeef;
    const BOOL gotReadProps = readProps &&
        readProps != (CFDictionaryRef)(uintptr_t)0xdeadbeef;
    SInt64 propLen = -1;
    CFNumberRef lenNum = gotReadProps
        ? (CFNumberRef)CFDictionaryGetValue(readProps, kCFURLFileLength) : NULL;
    if(lenNum) CFNumberGetValue(lenNum, kCFNumberSInt64Type, &propLen);
    SInt32 propMode = 0;
    CFNumberRef readMode = gotReadProps
        ? (CFNumberRef)CFDictionaryGetValue(readProps, kCFURLFilePOSIXMode)
        : NULL;
    if(readMode) CFNumberGetValue(readMode, kCFNumberSInt32Type, &propMode);
    check("url-access-read-file-and-props", ok && err == 0 && gotReadData &&
        CFDataGetLength(readData) == (CFIndex)(sizeof(payload) - 1) &&
        memcmp(CFDataGetBytePtr(readData), payload, sizeof(payload) - 1) == 0 &&
        gotReadProps &&
        CFDictionaryGetValue(readProps, kCFURLFileExists) == kCFBooleanTrue &&
        propLen == (SInt64)(sizeof(payload) - 1) &&
        (propMode & 0777) == 0640);
    if(gotReadData) CFRelease(readData);
    if(gotReadProps) CFRelease(readProps);

    /* Partial property failure still returns true for a readable file. */
    const void *partialKeys[2] = { kCFURLFileLength, CFSTR("BogusReadKey") };
    CFArrayRef desiredPartial = CFArrayCreate(
        kCFAllocatorDefault, partialKeys, 2, &kCFTypeArrayCallBacks);
    CFDataRef partialData = (CFDataRef)(uintptr_t)0xdeadbeef;
    CFDictionaryRef partialProps = (CFDictionaryRef)(uintptr_t)0xdeadbeef;
    err = 0;
    ok = CFURLCreateDataAndPropertiesFromResource(kCFAllocatorDefault, fileURL,
        &partialData, &partialProps, desiredPartial, &err);
    const BOOL gotPartialData = partialData &&
        partialData != (CFDataRef)(uintptr_t)0xdeadbeef;
    const BOOL gotPartialProps = partialProps &&
        partialProps != (CFDictionaryRef)(uintptr_t)0xdeadbeef;
    check("url-access-partial-prop-keeps-read", ok &&
        err == kCFURLUnknownPropertyKeyError && gotPartialData &&
        gotPartialProps && CFDictionaryGetCount(partialProps) == 1 &&
        CFDictionaryGetValue(partialProps, kCFURLFileLength) != NULL);
    if(gotPartialData) CFRelease(partialData);
    if(gotPartialProps) CFRelease(partialProps);
    if(desiredPartial) CFRelease(desiredPartial);

    /* Directory contents via CFURLCreatePropertyFromResource and resource API. */
    err = -999;
    CFArrayRef dirContents = (CFArrayRef)CFURLCreatePropertyFromResource(
        kCFAllocatorDefault, dirURL, kCFURLFileDirectoryContents, &err);
    check("url-access-dir-contents", dirContents && err == 0 &&
        CFGetTypeID(dirContents) == CFArrayGetTypeID() &&
        CFArrayGetCount(dirContents) == 1);
    if(dirContents) CFRelease(dirContents);

    /* Missing file must zero-initialize resourceData even on failure. */
    NSString *missingPath = [baseDir stringByAppendingPathComponent:@"missing"];
    CFURLRef missingURL = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault, (CFStringRef)missingPath,
        kCFURLPOSIXPathStyle, false);
    CFDataRef missingData = (CFDataRef)(uintptr_t)0xdeadbeef;
    CFDictionaryRef missingProps = (CFDictionaryRef)(uintptr_t)0xdeadbeef;
    err = 0;
    ok = CFURLCreateDataAndPropertiesFromResource(
        kCFAllocatorDefault, missingURL, &missingData, &missingProps, NULL, &err);
    const BOOL gotMissingProps = missingProps &&
        missingProps != (CFDictionaryRef)(uintptr_t)0xdeadbeef;
    check("url-access-missing-clears-outparam", !ok &&
        err == kCFURLResourceNotFoundError && missingData == NULL &&
        gotMissingProps &&
        CFDictionaryGetValue(missingProps, kCFURLFileExists) == kCFBooleanFalse);
    if(gotMissingProps) CFRelease(missingProps);
    if(missingURL) CFRelease(missingURL);

    /* Scheme-less relative URLs must be rejected with improper arguments. */
    CFURLRef relURL = CFURLCreateWithString(
        kCFAllocatorDefault, CFSTR("relative.txt"), NULL);
    CFDataRef relData = (CFDataRef)(uintptr_t)0xdeadbeef;
    err = 0;
    ok = CFURLCreateDataAndPropertiesFromResource(
        kCFAllocatorDefault, relURL, &relData, NULL, NULL, &err);
    check("url-access-schemeless-rejected", !ok &&
        err == kCFURLImproperArgumentsError && relData == NULL);
    if(relURL) CFRelease(relURL);

    /* Non-file scheme fails cleanly with kCFURLUnknownSchemeError. */
    CFURLRef ftpURL = CFURLCreateWithString(
        kCFAllocatorDefault, CFSTR("ftp://example.invalid/file"), NULL);
    CFDataRef ftpData = (CFDataRef)(uintptr_t)0xdeadbeef;
    err = 0;
    ok = CFURLCreateDataAndPropertiesFromResource(
        kCFAllocatorDefault, ftpURL, &ftpData, NULL, NULL, &err);
    check("url-access-nonfile-read", !ok && err == kCFURLUnknownSchemeError &&
        ftpData == NULL);
    err = 0;
    ok = CFURLDestroyResource(ftpURL, &err);
    check("url-access-nonfile-destroy", !ok && err == kCFURLUnknownSchemeError);
    if(ftpURL) CFRelease(ftpURL);

    /* Type-mismatched destroy (directory URL on a file) must fail without deleting. */
    CFURLRef fileAsDirURL = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault, (CFStringRef)filePath, kCFURLPOSIXPathStyle, true);
    err = 0;
    ok = CFURLDestroyResource(fileAsDirURL, &err);
    check("url-access-destroy-type-mismatch", !ok && err != 0);
    if(fileAsDirURL) CFRelease(fileAsDirURL);

    /* Destroy file, then destroy directory, then confirm missing. */
    err = -999;
    ok = CFURLDestroyResource(fileURL, &err);
    check("url-access-destroy-file", ok && err == 0);
    err = -999;
    ok = CFURLDestroyResource(dirURL, &err);
    check("url-access-destroy-dir", ok && err == 0);
    err = 0;
    ok = CFURLDestroyResource(fileURL, &err);
    check("url-access-destroy-missing", !ok && err == kCFURLResourceNotFoundError);

    if(fileURL) CFRelease(fileURL);
    if(dirURL) CFRelease(dirURL);
}

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    testAbsoluteURLBytes();
    testURLAccessResources();

    CFURLRef base = CFURLCreateWithString(kCFAllocatorDefault,
        CFSTR("https://example.test/a/"), NULL);
    CFURLRef relative = CFURLCreateWithString(kCFAllocatorDefault,
        CFSTR("../b?q=one%20two"), base);
    check("url-create-with-string", base && relative &&
        [[(NSURL *)relative absoluteString]
            isEqualToString:@"https://example.test/b?q=one%20two"]);

    const UInt8 latin1URL[] = {
        'h', 't', 't', 'p', ':', '/', '/', 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        '.', 't', 'e', 's', 't', '/', 'c', 'a', 'f', 0xe9,
    };
    CFURLRef bytesURL = CFURLCreateWithBytes(kCFAllocatorDefault,
        latin1URL, sizeof(latin1URL), kCFStringEncodingISOLatin1, NULL);
    NSString *bytesAbsolute = [(NSURL *)bytesURL absoluteString];
    check("url-create-with-bytes-encoding", bytesURL &&
        [bytesAbsolute hasSuffix:@"/caf%C3%A9"]);

    CFStringRef decodedAll =
        CFURLCreateStringByReplacingPercentEscapes(kCFAllocatorDefault,
            CFSTR("one%20two%2Fthree"), CFSTR(""));
    CFStringRef decodedSelective =
        CFURLCreateStringByReplacingPercentEscapes(kCFAllocatorDefault,
            CFSTR("one%20two%2Fthree"), CFSTR("/"));
    CFStringRef decodedLatin1 =
        CFURLCreateStringByReplacingPercentEscapesUsingEncoding(
            kCFAllocatorDefault, (CFStringRef)@"caf%E9", CFSTR(""),
            kCFStringEncodingISOLatin1);
    check("url-percent-decode-all",
        [(NSString *)decodedAll isEqualToString:@"one two/three"]);
    check("url-percent-decode-preserve",
        [(NSString *)decodedSelective isEqualToString:@"one two%2Fthree"]);
    check("url-percent-decode-encoding",
        [(NSString *)decodedLatin1 isEqualToString:@"caf\u00e9"]);

    CFMutableStringRef whitespace = CFStringCreateMutableCopy(
        kCFAllocatorDefault, 0, CFSTR(" \t\r\ninside \n"));
    CFStringTrimWhitespace(whitespace);
    check("string-trim-whitespace",
        [(NSString *)whitespace isEqualToString:@"inside"]);

    NSDictionary *leaf = [NSDictionary dictionaryWithObject:@"value"
                                                       forKey:@"key"];
    NSArray *source = [NSArray arrayWithObject:leaf];
    CFPropertyListRef immutable = CFPropertyListCreateDeepCopy(
        kCFAllocatorDefault, (CFPropertyListRef)source,
        kCFPropertyListImmutable);
    CFPropertyListRef mutableContainers = CFPropertyListCreateDeepCopy(
        kCFAllocatorDefault, (CFPropertyListRef)source,
        kCFPropertyListMutableContainers);
    CFPropertyListRef mutableLeaves = CFPropertyListCreateDeepCopy(
        kCFAllocatorDefault, (CFPropertyListRef)source,
        kCFPropertyListMutableContainersAndLeaves);

    BOOL immutableContent = [(NSArray *)immutable isEqual:source];
    [(NSMutableArray *)mutableContainers addObject:@"extra"];
    NSMutableDictionary *copiedLeaf =
        [(NSMutableArray *)mutableContainers objectAtIndex:0];
    [copiedLeaf setObject:@"changed" forKey:@"key"];
    NSMutableString *copiedString =
        [[(NSMutableArray *)mutableLeaves objectAtIndex:0]
            objectForKey:@"key"];
    [copiedString appendString:@"!"];
    check("property-list-deep-copy-content", immutableContent);
    check("property-list-deep-copy-containers",
        [(NSMutableArray *)mutableContainers count] == 2 &&
        [[copiedLeaf objectForKey:@"key"] isEqualToString:@"changed"] &&
        [[leaf objectForKey:@"key"] isEqualToString:@"value"]);
    check("property-list-deep-copy-leaves",
        [copiedString isEqualToString:@"value!"] &&
        [[leaf objectForKey:@"key"] isEqualToString:@"value"]);

    if(base) CFRelease(base);
    if(relative) CFRelease(relative);
    if(bytesURL) CFRelease(bytesURL);
    if(decodedAll) CFRelease(decodedAll);
    if(decodedSelective) CFRelease(decodedSelective);
    if(decodedLatin1) CFRelease(decodedLatin1);
    if(whitespace) CFRelease(whitespace);
    if(immutable) CFRelease(immutable);
    if(mutableContainers) CFRelease(mutableContainers);
    if(mutableLeaves) CFRelease(mutableLeaves);

    [pool drain];
    return failures != 0;
}
