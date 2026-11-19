#import <Foundation/Foundation.h>
#import <LC32/LC32.h>
#import <objc/runtime.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * NSMethodSignature's C-string accessors are not generated guest shims, so a
 * guest call fell through to forwarding and aborted (PlayHaven's PHInvocation
 * walks every argument with -getArgumentTypeAtIndex: and
 * NSGetSizeAndAlignment).  Apple returns pointers that stay valid while the
 * signature lives.  Type encodings form a small, code-bounded set, so intern
 * guest copies for the life of the process: the pointers then outlive every
 * signature and stay valid on any thread.
 */
typedef struct LC32InternedType {
    struct LC32InternedType *next;
    uint32_t hash;
    char text[];
} LC32InternedType;

enum { LC32InternedTypeBuckets = 128 };
static LC32InternedType *gLC32InternedTypes[LC32InternedTypeBuckets];
static pthread_mutex_t gLC32InternedTypesLock = PTHREAD_MUTEX_INITIALIZER;

static const char *LC32InternTypeString(const char *text) {
    uint32_t hash = 2166136261u;
    for(const unsigned char *p = (const unsigned char *)text; *p; ++p)
        hash = (hash ^ *p) * 16777619u;
    LC32InternedType **bucket =
        &gLC32InternedTypes[hash % LC32InternedTypeBuckets];

    pthread_mutex_lock(&gLC32InternedTypesLock);
    for(LC32InternedType *entry = *bucket; entry; entry = entry->next) {
        if(entry->hash == hash && strcmp(entry->text, text) == 0) {
            pthread_mutex_unlock(&gLC32InternedTypesLock);
            return entry->text;
        }
    }
    const size_t length = strlen(text);
    LC32InternedType *entry = malloc(sizeof(*entry) + length + 1);
    if(entry) {
        entry->hash = hash;
        memcpy(entry->text, text, length + 1);
        entry->next = *bucket;
        *bucket = entry;
    }
    pthread_mutex_unlock(&gLC32InternedTypesLock);
    return entry ? entry->text : NULL;
}

static const char *LC32MethodSignatureType(NSMethodSignature *signature,
        SEL selector, uint64_t *cache, NSUInteger index, BOOL indexed) {
    const uint64_t hostSelector = LC32CachedHostSelector(cache, selector, NO);
    const uint64_t string = indexed
        ? LC32InvokeHostSelector(signature.host_self, hostSelector,
              (uint64_t)index, (uint64_t)0)
        : LC32InvokeHostSelector(signature.host_self, hostSelector,
              (uint64_t)0);
    if(!string) return NULL;

    char stackBuffer[256];
    uint32_t required = LC32CopyHostCString(
        string, stackBuffer, sizeof(stackBuffer));
    if(!required) return NULL;
    if(required <= sizeof(stackBuffer)) return LC32InternTypeString(stackBuffer);

    char *heapBuffer = malloc(required);
    if(!heapBuffer) return NULL;
    const char *result =
        LC32CopyHostCString(string, heapBuffer, required) == required
        ? LC32InternTypeString(heapBuffer) : NULL;
    free(heapBuffer);
    return result;
}

@implementation NSMethodSignature (LC32TypeStrings)

- (const char *)methodReturnType {
    static uint64_t hostSelector __attribute__((aligned(8)));
    return LC32MethodSignatureType(self, _cmd, &hostSelector, 0, NO);
}

- (const char *)getArgumentTypeAtIndex:(NSUInteger)index {
    if(index >= self.numberOfArguments) {
        [NSException raise:NSInvalidArgumentException
                    format:@"-[NSMethodSignature getArgumentTypeAtIndex:]: "
                            "index (%lu) out of bounds [0, %lu]",
                           (unsigned long)index,
                           (unsigned long)self.numberOfArguments - 1];
    }
    static uint64_t hostSelector __attribute__((aligned(8)));
    return LC32MethodSignatureType(self, _cmd, &hostSelector, index, YES);
}

@end

/*
 * NSGetSizeAndAlignment (a CoreFoundation export since iOS 4) was missing, so a
 * caller died in the lazy binder.  Sizes must be the ARM32 guest's, not the
 * host's: callers use them to walk guest va_lists and guest buffers.  iOS
 * ARMv6/ARMv7 aligns 64-bit scalars (and long double, which is a double) to
 * four bytes.
 */
static const char *LC32SkipTypeQualifiers(const char *p) {
    while(*p && strchr("rnNoORVA", *p)) ++p;
    return p;
}

static const char *LC32SkipTypeOffset(const char *p) {
    if(*p == '+' || *p == '-') ++p;
    while(*p >= '0' && *p <= '9') ++p;
    return p;
}

static const char *LC32ARM32TypeLayout(const char *p, unsigned depth,
        uint32_t *size, uint32_t *alignment);

/* Parses `{name=fields}` or `(name=fields)`; `open` is already consumed. */
static const char *LC32ARM32AggregateLayout(const char *p, char close,
        unsigned depth, uint32_t *size, uint32_t *alignment) {
    unsigned nesting = 0;
    /* C++ template names may contain nested aggregate punctuation. */
    while(*p && (nesting || (*p != '=' && *p != close))) {
        if(*p == '<') ++nesting;
        else if(*p == '>' && nesting) --nesting;
        ++p;
    }
    *size = 0;
    *alignment = 1;
    if(*p == close) return p + 1; /* opaque: no layout */
    if(*p++ != '=') return NULL;

    uint32_t total = 0, maxAlignment = 1;
    while(*p && *p != close) {
        if(*p == '"') { /* field name */
            const char *end = strchr(p + 1, '"');
            if(!end) return NULL;
            p = end + 1;
            continue;
        }
        uint32_t fieldSize = 0, fieldAlignment = 1;
        p = LC32ARM32TypeLayout(p, depth + 1, &fieldSize, &fieldAlignment);
        if(!p) return NULL;
        if(fieldAlignment > maxAlignment) maxAlignment = fieldAlignment;
        if(close == '}') {
            total = (total + fieldAlignment - 1) & ~(fieldAlignment - 1);
            total += fieldSize;
        } else if(fieldSize > total) {
            total = fieldSize;
        }
    }
    if(*p++ != close) return NULL;
    *size = (total + maxAlignment - 1) & ~(maxAlignment - 1);
    *alignment = maxAlignment;
    return p;
}

static const char *LC32ARM32TypeLayout(const char *p, unsigned depth,
        uint32_t *size, uint32_t *alignment) {
    if(depth > 32) return NULL;
    p = LC32SkipTypeQualifiers(p);
    const char kind = *p++;
    switch(kind) {
        case 'c': case 'C': case 'B':
            *size = 1; *alignment = 1; return p;
        case 's': case 'S':
            *size = 2; *alignment = 2; return p;
        case 'i': case 'I': case 'l': case 'L': case 'f':
        case '*': case '#': case ':':
            *size = 4; *alignment = 4; return p;
        case 'q': case 'Q': case 'd': case 'D':
            *size = 8; *alignment = 4; return p;
        case 'v': case '?':
            *size = 0; *alignment = 1; return p;
        case '@':
            *size = 4; *alignment = 4;
            if(*p == '?') return p + 1; /* block */
            if(*p == '"') {
                /* A quoted class name is followed by another field name,
                 * the aggregate's end, or the string's end; a quoted string
                 * followed by a type is instead the next field's name. */
                const char *end = strchr(p + 1, '"');
                if(end && (end[1] == '"' || end[1] == '}' ||
                        end[1] == ')' || end[1] == '\0'))
                    return end + 1;
            }
            return p;
        case '^': {
            uint32_t pointeeSize, pointeeAlignment;
            p = LC32ARM32TypeLayout(p, depth + 1,
                &pointeeSize, &pointeeAlignment);
            *size = 4; *alignment = 4;
            return p;
        }
        case 'b': { /* bitfield: round its bits up to whole bytes */
            uint32_t bits = 0;
            while(*p >= '0' && *p <= '9') bits = bits * 10 + (uint32_t)(*p++ - '0');
            *size = (bits + 7) / 8; *alignment = 1;
            return p;
        }
        case 'j': { /* _Complex */
            uint32_t elementSize, elementAlignment;
            p = LC32ARM32TypeLayout(p, depth + 1,
                &elementSize, &elementAlignment);
            *size = elementSize * 2; *alignment = elementAlignment;
            return p;
        }
        case '[': {
            uint32_t count = 0;
            while(*p >= '0' && *p <= '9') count = count * 10 + (uint32_t)(*p++ - '0');
            uint32_t elementSize, elementAlignment;
            p = LC32ARM32TypeLayout(p, depth + 1,
                &elementSize, &elementAlignment);
            if(!p || *p++ != ']') return NULL;
            *size = elementSize * count; *alignment = elementAlignment;
            return p;
        }
        case '{':
            return LC32ARM32AggregateLayout(p, '}', depth, size, alignment);
        case '(':
            return LC32ARM32AggregateLayout(p, ')', depth, size, alignment);
        default:
            return NULL;
    }
}

const char *NSGetSizeAndAlignment(const char *typePtr, NSUInteger *sizep,
        NSUInteger *alignp) {
    if(!typePtr) return NULL;
    /* Accept a method encoding's leading offset and skip the trailing one,
     * so the usual `while(*types) types = NSGetSizeAndAlignment(...)` loop
     * walks full method type strings. */
    const char *type = LC32SkipTypeOffset(typePtr);
    uint32_t size = 0, alignment = 1;
    const char *next = LC32ARM32TypeLayout(type, 0, &size, &alignment);
    if(!next) {
        fprintf(stderr, "LC32: NSGetSizeAndAlignment cannot parse '%s'\n",
            typePtr);
        [NSException raise:NSInvalidArgumentException
                    format:@"NSGetSizeAndAlignment(): unsupported type "
                            "encoding spec '%s'", typePtr];
    }
    if(sizep) *sizep = size;
    if(alignp) *alignp = alignment;
    return LC32SkipTypeOffset(next);
}
