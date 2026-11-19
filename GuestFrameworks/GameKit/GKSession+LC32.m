#import <GameKit/GameKit.h>
#import <LC32/LC32.h>

/*
 * The generator skips -setDataReceiveHandler:withContext: because of its
 * void * argument, so guests fell into message forwarding and aborted
 * (H.A.W.X. calls it from Net_CreateBluetoothController at launch).
 *
 * The context is an opaque token that GameKit only hands back through
 * -receiveData:fromPeer:inSession:context:.  Pass the guest pointer to the
 * host zero-extended; the host-to-guest bridge returns a 32-bit ^v unchanged
 * when it calls the handler's guest-installed method.
 */
@implementation GKSession (LC32DataReceiveHandler)

- (void)setDataReceiveHandler:(id)handler withContext:(void *)context {
    static uint64_t hostCommand __attribute__((aligned(8)));
    LC32InvokeHostSelector(
        self.host_self, LC32CachedHostSelector(&hostCommand, _cmd, NO),
        [handler host_self], (uint64_t)(uintptr_t)context, (uint64_t)0);
}

@end
