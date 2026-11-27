#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSString *source = @"A\u00e9B";
    unsigned char bytes[16] = {};
    NSUInteger usedLength = NSUIntegerMax;
    NSRange remainingRange = NSMakeRange(NSNotFound, NSNotFound);

    BOOL converted = [source
        getBytes:bytes
        maxLength:sizeof(bytes)
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:0
        range:NSMakeRange(0, source.length)
        remainingRange:&remainingRange];
    const unsigned char expected[] = {'A', 0xc3, 0xa9, 'B'};
    BOOL passed = converted && usedLength == sizeof(expected) &&
        memcmp(bytes, expected, sizeof(expected)) == 0 &&
        NSEqualRanges(remainingRange, NSMakeRange(source.length, 0));
    printf("string-get-bytes: %s\n", passed ? "PASS" : "FAIL");

    /* Oversized range.length (e.g. passing buffer capacity 0x1ff as length on
     * a shorter path, as Paladog's GetBaseDir does) clamps to available units
     * for both heap-backed and runtime-created short tagged host strings. */
    NSString *longPath = [NSString stringWithFormat:@"%@/Documents/",
        @"/var/mobile/Containers/Data/Application/TEST"];
    unsigned char pathBuf[512];
    memset(pathBuf, 0xaa, sizeof(pathBuf));
    usedLength = NSUIntegerMax;
    remainingRange = NSMakeRange(NSNotFound, NSNotFound);
    BOOL longOvershoot = [longPath
        getBytes:pathBuf
        maxLength:511
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:NSStringEncodingConversionAllowLossy
        range:NSMakeRange(0, 511)
        remainingRange:&remainingRange];
    BOOL longOvershootPassed = longOvershoot && usedLength == longPath.length &&
        memcmp(pathBuf, [longPath UTF8String], longPath.length) == 0 &&
        pathBuf[longPath.length] == 0xaa &&
        NSEqualRanges(remainingRange, NSMakeRange(longPath.length, 0));
    printf("string-get-bytes-overshoot-long: %s\n",
        longOvershootPassed ? "PASS" : "FAIL");

    NSString *shortString = [NSString stringWithFormat:@"%s", "abc"];
    unsigned char shortBuf[16];
    memset(shortBuf, 0xaa, sizeof(shortBuf));
    usedLength = NSUIntegerMax;
    remainingRange = NSMakeRange(NSNotFound, NSNotFound);
    BOOL shortOvershoot = [shortString
        getBytes:shortBuf
        maxLength:15
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:NSStringEncodingConversionAllowLossy
        range:NSMakeRange(0, 511)
        remainingRange:&remainingRange];
    BOOL shortOvershootPassed = shortOvershoot && usedLength == 3 &&
        memcmp(shortBuf, "abc", 3) == 0 && shortBuf[3] == 0xaa &&
        NSEqualRanges(remainingRange, NSMakeRange(3, 0));
    printf("string-get-bytes-overshoot-short: %s\n",
        shortOvershootPassed ? "PASS" : "FAIL");

    usedLength = NSUIntegerMax;
    remainingRange = NSMakeRange(NSNotFound, NSNotFound);
    BOOL nullQuery = [shortString
        getBytes:NULL
        maxLength:0
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:0
        range:NSMakeRange(0, 511)
        remainingRange:&remainingRange];
    BOOL nullQueryPassed = nullQuery && usedLength == 3 &&
        NSEqualRanges(remainingRange, NSMakeRange(3, 0));
    printf("string-get-bytes-null-zero-max: %s\n",
        nullQueryPassed ? "PASS" : "FAIL");

    usedLength = NSUIntegerMax;
    remainingRange = NSMakeRange(NSNotFound, NSNotFound);
    BOOL zeroCap = [shortString
        getBytes:shortBuf
        maxLength:0
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:0
        range:NSMakeRange(0, 511)
        remainingRange:&remainingRange];
    BOOL zeroCapPassed = zeroCap && usedLength == 0 &&
        shortBuf[0] == 0xaa &&
        NSEqualRanges(remainingRange, NSMakeRange(0, 3));
    printf("string-get-bytes-nonnull-zero-max: %s\n",
        zeroCapPassed ? "PASS" : "FAIL");

    unsigned char partialBuf[4];
    memset(partialBuf, 0xaa, sizeof(partialBuf));
    usedLength = NSUIntegerMax;
    remainingRange = NSMakeRange(NSNotFound, NSNotFound);
    BOOL partialOvershoot = [[NSString stringWithFormat:@"%s", "abcdef"]
        getBytes:partialBuf
        maxLength:2
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:0
        range:NSMakeRange(2, 100)
        remainingRange:&remainingRange];
    BOOL partialPassed = partialOvershoot && usedLength == 2 &&
        memcmp(partialBuf, "cd", 2) == 0 && partialBuf[2] == 0xaa &&
        NSEqualRanges(remainingRange, NSMakeRange(4, 2));
    printf("string-get-bytes-overshoot-partial: %s\n",
        partialPassed ? "PASS" : "FAIL");

    usedLength = NSUIntegerMax;
    BOOL pastEnd = [shortString
        getBytes:shortBuf
        maxLength:15
        usedLength:&usedLength
        encoding:NSUTF8StringEncoding
        options:0
        range:NSMakeRange(4, 1)
        remainingRange:NULL];
    BOOL pastEndPassed = !pastEnd;
    printf("string-get-bytes-past-end: %s\n",
        pastEndPassed ? "PASS" : "FAIL");

    passed = passed && longOvershootPassed && shortOvershootPassed &&
        nullQueryPassed && zeroCapPassed && partialPassed && pastEndPassed;

    [pool drain];
    return !passed;
}
