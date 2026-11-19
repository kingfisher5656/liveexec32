#import "LC32EnvFile.h"

typedef struct {
    BOOL isEntry;
    BOOL enabled;
    NSRange keyRange;
    NSRange valueRange;
} LC32EnvLine;

static BOOL LC32IsKeyCharacter(unichar c) {
    return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

static BOOL LC32IsSpace(unichar c) {
    return c == ' ' || c == '\t' || c == '\r';
}

/* Mirrors LoadUserEnvironmentFile: text after '#' is a comment, and key and
 * value are trimmed. A switched-off entry is '#' directly followed by the
 * key, the form LiveExec32.env.example uses. */
static LC32EnvLine LC32ParseLine(NSString *line) {
    LC32EnvLine result = {NO, NO, {0, 0}, {0, 0}};
    const NSUInteger length = line.length;
    NSUInteger i = 0;
    while(i < length && LC32IsSpace([line characterAtIndex:i])) i++;
    BOOL enabled = YES;
    if(i < length && [line characterAtIndex:i] == '#') {
        enabled = NO;
        while(i < length && [line characterAtIndex:i] == '#') i++;
    }
    if(length - i < 6 || ![[line substringWithRange:NSMakeRange(i, 5)]
            isEqualToString:@"LC32_"]) {
        return result;
    }
    const NSUInteger keyStart = i;
    i += 5;
    while(i < length && LC32IsKeyCharacter([line characterAtIndex:i])) i++;
    const NSUInteger keyEnd = i;
    if(keyEnd == keyStart + 5) return result;
    while(i < length && LC32IsSpace([line characterAtIndex:i])) i++;
    if(i >= length || [line characterAtIndex:i] != '=') return result;
    i++;
    while(i < length && LC32IsSpace([line characterAtIndex:i])) i++;
    NSUInteger valueEnd = i;
    while(valueEnd < length && [line characterAtIndex:valueEnd] != '#') valueEnd++;
    while(valueEnd > i && LC32IsSpace([line characterAtIndex:valueEnd - 1])) valueEnd--;
    result.isEntry = YES;
    result.enabled = enabled;
    result.keyRange = NSMakeRange(keyStart, keyEnd - keyStart);
    result.valueRange = NSMakeRange(i, valueEnd - i);
    return result;
}

static NSString *LC32FormatLine(NSString *key, NSString *value, BOOL enabled) {
    return [NSString stringWithFormat:@"%@%@=%@", enabled ? @"" : @"#", key, value];
}

@implementation LC32EnvFile {
    NSMutableArray<NSString *> *_lines;
}

+ (NSString *)defaultPathForExecutable:(NSString *)executablePath {
    /*
     * Inside LiveContainer the runtime looks next to the Applications folder
     * that holds the game (and the LiveExec32 launcher), so write there:
     * On My iPhone > LiveContainer in the Files app.
     */
    if(getenv("LC_HOME_PATH") != NULL) {
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        NSString *bundlePath = NSBundle.mainBundle.bundlePath;
        if(bundlePath.length) [candidates addObject:bundlePath];
        if(executablePath.length) [candidates addObject:executablePath];
        for(NSString *candidate in candidates) {
            NSRange range = [candidate rangeOfString:@"/Applications/"
                options:NSBackwardsSearch];
            if(range.location != NSNotFound && range.location > 0) {
                return [[candidate substringToIndex:range.location]
                    stringByAppendingPathComponent:@"LiveExec32.env"];
            }
        }
    }
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if(!documents) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:@"LiveExec32.env"];
}

+ (BOOL)isValidKey:(NSString *)key {
    if(key.length < 6 || ![key hasPrefix:@"LC32_"]) return NO;
    for(NSUInteger i = 5; i < key.length; i++) {
        if(!LC32IsKeyCharacter([key characterAtIndex:i])) return NO;
    }
    return YES;
}

+ (BOOL)isValidValue:(NSString *)value {
    // '#' would start a comment and a line break would end the entry.
    return [value rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"#\n\r"]].location
        == NSNotFound;
}

- (instancetype)initWithPath:(NSString *)path {
    if((self = [super init])) {
        _path = [path copy];
        [self reload];
    }
    return self;
}

- (void)reload {
    NSString *text = [NSString stringWithContentsOfFile:_path
        encoding:NSUTF8StringEncoding error:nil];
    _lines = [NSMutableArray array];
    if(text.length) {
        [_lines addObjectsFromArray:[text componentsSeparatedByString:@"\n"]];
        // A trailing newline leaves one empty element; save adds it back.
        if([_lines.lastObject length] == 0) [_lines removeLastObject];
    }
}

- (BOOL)save:(NSError **)error {
    if(_lines.count == 0) {
        [_lines addObject:@"# LiveExec32 settings, read when a 32-bit app starts."];
        [_lines addObject:@"# Edited by the LiveExec32 app. Lines are LC32_NAME=value;"];
        [_lines addObject:@"# a # in front switches a line off."];
    }
    NSString *text = [[_lines componentsJoinedByString:@"\n"]
        stringByAppendingString:@"\n"];
    return [text writeToFile:_path atomically:YES
        encoding:NSUTF8StringEncoding error:error];
}

- (NSArray<NSString *> *)keys {
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    for(NSString *line in _lines) {
        LC32EnvLine parsed = LC32ParseLine(line);
        if(parsed.isEntry) [keys addObject:[line substringWithRange:parsed.keyRange]];
    }
    return keys.array;
}

/* Index of the line the runtime uses (first enabled), else the first
 * switched-off line, else NSNotFound. */
- (NSUInteger)primaryIndexForKey:(NSString *)key enabled:(BOOL *)enabled {
    NSUInteger disabledIndex = NSNotFound;
    for(NSUInteger i = 0; i < _lines.count; i++) {
        LC32EnvLine parsed = LC32ParseLine(_lines[i]);
        if(!parsed.isEntry ||
                ![[_lines[i] substringWithRange:parsed.keyRange] isEqualToString:key]) {
            continue;
        }
        if(parsed.enabled) {
            if(enabled) *enabled = YES;
            return i;
        }
        if(disabledIndex == NSNotFound) disabledIndex = i;
    }
    if(enabled) *enabled = NO;
    return disabledIndex;
}

- (BOOL)hasKey:(NSString *)key {
    return [self primaryIndexForKey:key enabled:NULL] != NSNotFound;
}

- (BOOL)isEnabled:(NSString *)key {
    BOOL enabled = NO;
    [self primaryIndexForKey:key enabled:&enabled];
    return enabled;
}

- (NSString *)valueForKey:(NSString *)key {
    NSUInteger index = [self primaryIndexForKey:key enabled:NULL];
    if(index == NSNotFound) return nil;
    return [_lines[index] substringWithRange:LC32ParseLine(_lines[index]).valueRange];
}

- (void)setValue:(NSString *)value forKey:(NSString *)key enabled:(BOOL)enabled {
    NSUInteger index = [self primaryIndexForKey:key enabled:NULL];
    NSString *line = LC32FormatLine(key, value, enabled);
    if(index == NSNotFound) {
        [_lines addObject:line];
        return;
    }
    _lines[index] = line;
    // Only one line per key stays enabled, so the file says what is used.
    for(NSUInteger i = 0; i < _lines.count; i++) {
        if(i == index) continue;
        LC32EnvLine parsed = LC32ParseLine(_lines[i]);
        if(parsed.isEntry && parsed.enabled &&
                [[_lines[i] substringWithRange:parsed.keyRange] isEqualToString:key]) {
            _lines[i] = [@"#" stringByAppendingString:_lines[i]];
        }
    }
}

- (void)disableKey:(NSString *)key {
    for(NSUInteger i = 0; i < _lines.count; i++) {
        LC32EnvLine parsed = LC32ParseLine(_lines[i]);
        if(parsed.isEntry && parsed.enabled &&
                [[_lines[i] substringWithRange:parsed.keyRange] isEqualToString:key]) {
            _lines[i] = LC32FormatLine(key,
                [_lines[i] substringWithRange:parsed.valueRange], NO);
        }
    }
}

- (void)removeKey:(NSString *)key {
    NSIndexSet *matches = [_lines indexesOfObjectsPassingTest:
        ^BOOL(NSString *line, NSUInteger index, BOOL *stop) {
            LC32EnvLine parsed = LC32ParseLine(line);
            return parsed.isEntry &&
                [[line substringWithRange:parsed.keyRange] isEqualToString:key];
        }];
    [_lines removeObjectsAtIndexes:matches];
}

@end
