#import <GameKit/GameKit.h>
#import <LC32/LC32.h>

/*
 * Some games built with early Apple LLVM versions set BLOCK_HAS_SIGNATURE on
 * these callbacks while leaving the descriptor's signature pointer null.
 * GameKit already specifies each callback ABI, so capture the legacy block in
 * a current-compiler wrapper whose descriptor the generic host bridge can
 * parse.  Invoking the captured block in guest code does not inspect its
 * descriptor, and the wrapper's copy helper preserves its normal lifetime.
 */

@implementation GKAchievement (LC32LegacyBlockCompatibility)

- (void)reportAchievementWithCompletionHandler:
        (void (^)(NSError *error))completionHandler {
    void (^typedHandler)(NSError *) = nil;
    if(completionHandler) {
        typedHandler = ^(NSError *error) {
            completionHandler(error);
        };
    }

    /* Modern GameKit replaces the deprecated instance API with this batch
     * class method.  Preserve the legacy one-achievement behavior. */
    [GKAchievement reportAchievements:@[self]
                 withCompletionHandler:typedHandler];
}

@end

@implementation GKLeaderboard (LC32LegacyPropertyCompatibility)

- (NSString *)category {
    return self.identifier;
}

- (void)setCategory:(NSString *)category {
    self.identifier = category;
}

@end

@implementation GKLocalPlayer (LC32LegacyBlockCompatibility)

- (void)authenticateWithCompletionHandler:
        (void (^)(NSError *error))completionHandler {
    void (^typedHandler)(NSError *) = nil;
    if(completionHandler) {
        /* Modern GameKit runs this deprecated call through authenticateHandler,
         * which can fire again later, also with a nil error (for instance while
         * a sign-in view is pending).  The legacy contract is one callback, and
         * a nil error promises an authenticated local player with a playerID.
         * This guest reports isAuthenticated NO, so games that trust the nil
         * error then read a nil playerID (BioShock: +stringWithString: nil).
         * Deliver once, and report a host "success" the guest cannot back up
         * as Game Center being unavailable. */
        __block BOOL delivered = NO;
        typedHandler = ^(NSError *error) {
            if(delivered) return;
            delivered = YES;
            if(!error && ![self isAuthenticated]) {
                error = [NSError errorWithDomain:GKErrorDomain
                                            code:GKErrorNotSupported
                                        userInfo:nil];
            }
            completionHandler(error);
        };
    }

    static uint64_t hostCommand __attribute__((aligned(8)));
    LC32InvokeHostSelector(
        self.host_self, LC32CachedHostSelector(&hostCommand, _cmd, NO),
        [typedHandler host_self], (uint64_t)0);
}

@end

@implementation GKMatchmaker (LC32LegacyBlockCompatibility)

- (void)setInviteHandler:
        (void (^)(GKInvite *acceptedInvite,
                  NSArray *playerIDsToInvite))inviteHandler {
    void (^typedHandler)(GKInvite *, NSArray *) = nil;
    if(inviteHandler) {
        typedHandler = ^(GKInvite *acceptedInvite,
                         NSArray *playerIDsToInvite) {
            inviteHandler(acceptedInvite, playerIDsToInvite);
        };
    }

    static uint64_t hostCommand __attribute__((aligned(8)));
    LC32InvokeHostSelector(
        self.host_self, LC32CachedHostSelector(&hostCommand, _cmd, NO),
        [typedHandler host_self], (uint64_t)0);
}

@end

@implementation GKVoiceChat (LC32LegacyBlockCompatibility)

- (void)setPlayerStateUpdateHandler:
        (void (^)(NSString *playerID,
                  GKVoiceChatPlayerState state))playerStateUpdateHandler {
    void (^typedHandler)(NSString *, GKVoiceChatPlayerState) = nil;
    if(playerStateUpdateHandler) {
        typedHandler = ^(NSString *playerID, GKVoiceChatPlayerState state) {
            playerStateUpdateHandler(playerID, state);
        };
    }

    static uint64_t hostCommand __attribute__((aligned(8)));
    LC32InvokeHostSelector(
        self.host_self, LC32CachedHostSelector(&hostCommand, _cmd, NO),
        [typedHandler host_self], (uint64_t)0);
}

@end
