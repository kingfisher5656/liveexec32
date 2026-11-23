#import <Foundation/Foundation+LC32.h>

#import <objc/message.h>

extern BOOL LC32NSThreadNativeModeEnabled(void);
extern BOOL LC32NSThreadIsCurrentThread(NSThread *thread);
extern uint64_t LC32NSThreadHostThread(NSThread *thread);
extern BOOL LC32NSThreadQueuePerformBeforeStart(NSThread *thread, id target,
    SEL selector, id object, BOOL wait, NSArray *modes);
extern BOOL LC32NSThreadQueueNativePerform(NSThread *thread, id target,
    SEL selector, id object, NSArray *modes);

static NSArray *LC32CommonRunLoopModes(void) {
    return [NSArray arrayWithObject:NSRunLoopCommonModes];
}

@implementation NSObject (LC32ThreadPerforming)

- (void)performSelector:(SEL)selector
               onThread:(NSThread *)thread
             withObject:(id)object
          waitUntilDone:(BOOL)wait
                  modes:(NSArray<NSString *> *)modes {
    if(!selector || !thread || modes.count == 0) return;

    /*
     * Keep same-thread delivery tied to a guest request.  Forwarding this
     * case through native -performSelector:onThread: with the original target
     * installs a host run-loop source whose target is only a mirror of the
     * guest object.  In particular, YTApiaryDeviceAuthenticator queues work
     * back to its current thread with waitUntilDone:NO; the native NSThread
     * source never re-entered the guest, so performQueuedRequest: was never
     * run.  A guest LC32PendingThreadPerform does re-enter the guest.
     *
     * Use the native perform source rather than a zero-delay timer: iOS runs
     * a queued same-thread perform before its run loop waits again in one of
     * the perform's modes, so a common-mode perform precedes the next
     * CADisplayLink frame.  A timer races that frame.  Paladog! parses its database, hands the rows over with
     * performSelectorOnMainThread:waitUntilDone:NO, and reads them in the
     * next frame; when the frame won, objectAtIndex: threw on the empty list
     * and the game stayed on its loading screen.
     */
    if(LC32NSThreadIsCurrentThread(thread)) {
        if(wait) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                self, selector, object);
        } else if(!LC32NSThreadQueueNativePerform(
                thread, self, selector, object, modes)) {
            [self performSelector:selector withObject:object afterDelay:0
                          inModes:modes];
        }
        return;
    }

    if(!LC32NSThreadNativeModeEnabled()) {
        CRSetCrashLogMessage(
            "cross-thread performSelector requires native guest threads");
        return;
    }

    if(LC32NSThreadQueuePerformBeforeStart(
            thread, self, selector, object, wait, modes)) return;

    const uint64_t hostThread = LC32NSThreadHostThread(thread);
    if(!hostThread) {
        CRSetCrashLogMessage(
            "performSelector target NSThread has no native thread");
        return;
    }

    static uint64_t hostSelector __attribute__((aligned(8)));
    LC32InvokeHostSelector(
        self.host_self,
        LC32CachedHostSelector(&hostSelector, _cmd, NO),
        LC32GetHostSelector(selector), hostThread, [object host_self],
        (uint64_t)wait, [modes host_self], (uint64_t)0);
}

- (void)performSelector:(SEL)selector
               onThread:(NSThread *)thread
             withObject:(id)object
          waitUntilDone:(BOOL)wait {
    [self performSelector:selector onThread:thread withObject:object
            waitUntilDone:wait modes:LC32CommonRunLoopModes()];
}

- (void)performSelectorOnMainThread:(SEL)selector
                         withObject:(id)object
                      waitUntilDone:(BOOL)wait
                              modes:(NSArray<NSString *> *)modes {
    [self performSelector:selector onThread:[NSThread mainThread]
               withObject:object waitUntilDone:wait modes:modes];
}

- (void)performSelectorOnMainThread:(SEL)selector
                         withObject:(id)object
                      waitUntilDone:(BOOL)wait {
    [self performSelector:selector onThread:[NSThread mainThread]
               withObject:object waitUntilDone:wait
                    modes:LC32CommonRunLoopModes()];
}

- (void)performSelectorInBackground:(SEL)selector withObject:(id)object {
    [NSThread detachNewThreadSelector:selector toTarget:self withObject:object];
}

@end
