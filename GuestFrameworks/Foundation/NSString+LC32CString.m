#import <Foundation/Foundation+LC32.h>
#import <CoreFoundation/CoreFoundation.h>

#include <stdint.h>
#include <string.h>

@implementation NSString (LC32CString)

- (BOOL)getCString:(char *)buffer
          maxLength:(NSUInteger)maximumLength
           encoding:(NSStringEncoding)encoding {
    /*
     * The generated selector bridge cannot pass an ARM32 output pointer to
     * native Foundation.  CoreFoundation already stages the destination in
     * guest memory, including the terminating NUL required by this method.
     */
    if(!buffer || maximumLength == 0 || maximumLength > INT32_MAX)
        return NO;
    const CFStringEncoding cfEncoding =
        CFStringConvertNSStringEncodingToEncoding(encoding);
    if(cfEncoding == kCFStringEncodingInvalidId) return NO;
    return CFStringGetCString((CFStringRef)self, buffer,
                              (CFIndex)maximumLength, cfEncoding);
}

- (const char *)UTF8String {
    uint32_t required = LC32CopyHostStringUTF8(self.host_self, NULL, 0);
    if(!required) return NULL;
    char *bytes = LC32GetAssociatedGuestBuffer(self, required);
    if(!bytes) return NULL;
    return LC32CopyHostStringUTF8(self.host_self, bytes, required) == required
        ? bytes : NULL;
}

- (const char *)cStringUsingEncoding:(NSStringEncoding)encoding {
    uint32_t required = LC32CopyHostStringBytes(
        self.host_self, (uint32_t)encoding, NULL, 0);
    if(!required) return NULL;
    char *bytes = LC32GetAssociatedGuestBuffer(self, required);
    if(!bytes) return NULL;
    return LC32CopyHostStringBytes(
        self.host_self, (uint32_t)encoding, bytes, required) == required
        ? bytes : NULL;
}

- (const char *)cString {
    /* This deprecated API uses the process's default C-string encoding,
     * not necessarily UTF-8. Reuse the guest-owned buffer adapter rather
     * than forwarding a native char pointer into ARM32 address space. */
    return [self cStringUsingEncoding:[NSString defaultCStringEncoding]];
}

/*
 * Pre-iOS 2 C-string API in the default C-string encoding. The generated
 * bridge skips these because native Foundation cannot write into an ARM32
 * buffer, so a call fell into forwarding and aborted on the char * argument
 * (N.O.V.A. getCString:s -[UIDevice uniqueIdentifier] on its online thread).
 * Convert through CF's staged bytes instead. Unconvertible characters become
 * '?' rather than raising NSCharacterConversionException: these games never
 * catch it, and lossy output beats a crash.
 */
static CFStringEncoding LC32DefaultCStringCFEncoding(void) {
    return CFStringConvertNSStringEncodingToEncoding(
        [NSString defaultCStringEncoding]);
}

- (void)getCString:(char *)buffer
         maxLength:(NSUInteger)maximumLength
             range:(NSRange)range
    remainingRange:(NSRangePointer)remainingRange {
    const NSUInteger length = self.length;
    if(range.location > length || range.length > length - range.location) {
        [NSException raise:NSRangeException
                    format:@"-[NSString getCString:maxLength:range:"
                           "remainingRange:]: range {%lu, %lu} out of "
                           "bounds; string length %lu",
                           (unsigned long)range.location,
                           (unsigned long)range.length,
                           (unsigned long)length];
    }
    if(!buffer || range.length > INT32_MAX) {
        if(remainingRange) *remainingRange = range;
        return;
    }
    const CFStringEncoding encoding = LC32DefaultCStringCFEncoding();
    const CFRange cfRange =
        CFRangeMake((CFIndex)range.location, (CFIndex)range.length);
    /* Native CF stages maxBufferLength bytes on the host, so never pass the
     * unbounded NSMaximumStringLength of -getCString: through. */
    CFIndex required = 0;
    CFStringGetBytes((CFStringRef)self, cfRange, encoding, '?', false,
                     NULL, 0, &required);
    CFIndex capacity = (CFIndex)(maximumLength > INT32_MAX
        ? INT32_MAX : maximumLength);
    if(required < capacity) capacity = required;
    CFIndex used = 0;
    const CFIndex converted = capacity > 0
        ? CFStringGetBytes((CFStringRef)self, cfRange, encoding, '?', false,
                           (UInt8 *)buffer, capacity, &used)
        : 0;
    if(used < 0 || used > capacity) used = 0;
    buffer[used] = '\0';
    if(remainingRange) {
        const NSUInteger done = converted > 0 &&
            (NSUInteger)converted <= range.length ? (NSUInteger)converted : 0;
        *remainingRange =
            NSMakeRange(range.location + done, range.length - done);
    }
}

- (void)getCString:(char *)buffer maxLength:(NSUInteger)maximumLength {
    [self getCString:buffer
           maxLength:maximumLength
               range:NSMakeRange(0, self.length)
      remainingRange:NULL];
}

- (void)getCString:(char *)buffer {
    [self getCString:buffer maxLength:NSMaximumStringLength];
}

- (const char *)lossyCString {
    NSData *data = [self dataUsingEncoding:[NSString defaultCStringEncoding]
                      allowLossyConversion:YES];
    if(!data) return NULL;
    const NSUInteger size = data.length;
    if(size >= UINT32_MAX) return NULL;
    char *bytes = LC32GetAssociatedGuestBuffer(self, (uint32_t)size + 1);
    if(!bytes) return NULL;
    if(size) [data getBytes:bytes length:size];
    bytes[size] = '\0';
    return bytes;
}

- (const char *)fileSystemRepresentation {
    /* Darwin paths are UTF-8.  Keep the bytes in guest-owned associated
     * storage so POSIX calls can safely consume the returned pointer. */
    return self.UTF8String;
}

- (BOOL)getFileSystemRepresentation:(char *)buffer
                           maxLength:(NSUInteger)maximumLength {
    if(!buffer) return NO;
    const char *source = self.fileSystemRepresentation;
    if(!source) return NO;
    const size_t required = strlen(source) + 1;
    if(required > maximumLength) return NO;
    memcpy(buffer, source, required);
    return YES;
}

@end

@implementation NSFileManager (LC32PathRepresentation)

- (const char *)fileSystemRepresentationWithPath:(NSString *)path {
    return path.fileSystemRepresentation;
}

- (BOOL)getFileSystemRepresentation:(char *)buffer
                           maxLength:(NSUInteger)maximumLength
                            withPath:(NSString *)path {
    return [path getFileSystemRepresentation:buffer maxLength:maximumLength];
}

@end
