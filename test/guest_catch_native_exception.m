#import <Foundation/Foundation.h>
#include <stdio.h>

static int failures;

static void check(const char *name, int ok) {
    printf("guest-catch: %s %s\n", ok ? "ok  " : "FAIL", name);
    if(!ok) failures++;
}

/* Grabatron's initWindow: nil date added to a native mutable array. */
static int addNilInsideTry(void) {
    NSMutableArray *array = [[NSMutableArray alloc] init];
    int caught = 0;
    @try {
        [array addObject:nil];
        printf("guest-catch: addObject:nil returned\n");
    } @catch(NSException *exception) {
        caught = [[exception name] isEqualToString:NSInvalidArgumentException];
        printf("guest-catch: caught %s: %s\n",
            [[exception name] UTF8String], [[exception reason] UTF8String]);
    }
    [array release];
    return caught;
}

static void throwFromDeeperFrame(void) {
    [[NSArray array] objectAtIndex:5];
}

static int unwindThroughFrames(void) {
    @try {
        throwFromDeeperFrame();
    } @catch(id exception) {
        return [[exception name] isEqualToString:NSRangeException];
    }
    return 0;
}

static int raiseFromFoundation(void) {
    @try {
        [NSException raise:@"LC32TestException" format:@"value %d", 42];
    } @catch(NSException *exception) {
        return [[exception reason] isEqualToString:@"value 42"];
    } @finally {
        printf("guest-catch: finally ran\n");
    }
    return 0;
}

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    check("addObject:nil caught by @catch(NSException *)", addNilInsideTry());
    check("objectAtIndex: caught across guest frames", unwindThroughFrames());
    check("+raise:format: caught", raiseFromFoundation());
    check("normal call after catches", [[NSArray arrayWithObject:@"x"] count] == 1);
    [pool drain];
    printf("guest-catch: %s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
    return failures;
}
