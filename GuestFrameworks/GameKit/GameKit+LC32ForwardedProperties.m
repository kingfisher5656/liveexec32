#import <GameKit/GameKit.h>
#import <LC32/LC32.h>

/*
 * Modern GameKit implements these SDK properties on GK*Internal objects and
 * reaches them through -forwardingTargetForSelector:. They are absent from the
 * native class method lists, so the generator emits no shim; the primary
 * implementations declare them @dynamic and these accessors message the
 * native object, whose own runtime forwarding then finds the internal object.
 *
 * Guest message forwarding cannot be used instead: its fast path asks the
 * native object for a forwarding target and receives a GK*Internal object
 * that has no guest class, so the selector reaches a plain NSObject proxy
 * (Corona's achievement callback aborted on -[NSObject isHidden]).
 */

/* Shared by many selectors, so the host selector is resolved per call
 * rather than through a single LC32CachedHostSelector slot. */
static id LC32GKGetHostObject(id self, SEL _cmd) {
    return LC32ReturnBorrowedGuestObject(LC32InvokeHostObjectSelector(
        [self host_self], LC32GetHostSelector(_cmd), (uint64_t)0));
}

static uint64_t LC32GKGetHostScalar(id self, SEL _cmd) {
    return LC32InvokeHostSelector([self host_self],
        LC32GetHostSelector(_cmd), (uint64_t)0);
}

static void LC32GKSetHostScalar(id self, SEL _cmd, uint64_t value) {
    (void)LC32InvokeHostSelector([self host_self],
        LC32GetHostSelector(_cmd), value, (uint64_t)0);
}

@implementation GKScore (LC32ForwardedProperties)

- (int64_t)value {
    return (int64_t)LC32GKGetHostScalar(self, _cmd);
}

- (void)setValue:(int64_t)value {
    LC32GKSetHostScalar(self, _cmd, (uint64_t)value);
}

- (NSString *)formattedValue {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)leaderboardIdentifier {
    return LC32GKGetHostObject(self, _cmd);
}

- (void)setLeaderboardIdentifier:(NSString *)leaderboardIdentifier {
    LC32GKSetHostScalar(self, _cmd, [leaderboardIdentifier host_self]);
}

- (uint64_t)context {
    return LC32GKGetHostScalar(self, _cmd);
}

- (void)setContext:(uint64_t)context {
    LC32GKSetHostScalar(self, _cmd, context);
}

- (NSDate *)date {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSInteger)rank {
    return (NSInteger)LC32GKGetHostScalar(self, _cmd);
}

/* Deprecated in the iOS 7 SDK; Corona-era clients still read it from
 * loaded leaderboard scores. */
- (NSString *)category {
    return self.leaderboardIdentifier;
}

- (void)setCategory:(NSString *)category {
    self.leaderboardIdentifier = category;
}

@end

@implementation GKAchievement (LC32ForwardedProperties)

/* Deprecated getter (GKAchievementDescription owns it now). */
- (BOOL)isHidden {
    return (BOOL)LC32GKGetHostScalar(self, _cmd);
}

@end

@implementation GKLeaderboard (LC32ForwardedProperties)

- (NSString *)identifier {
    return LC32GKGetHostObject(self, _cmd);
}

- (void)setIdentifier:(NSString *)identifier {
    LC32GKSetHostScalar(self, _cmd, [identifier host_self]);
}

- (NSString *)title {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSUInteger)maxRange {
    return (NSUInteger)LC32GKGetHostScalar(self, _cmd);
}

- (NSString *)groupIdentifier {
    return LC32GKGetHostObject(self, _cmd);
}

@end

@implementation GKAchievementDescription (LC32ForwardedProperties)

- (NSString *)identifier {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)groupIdentifier {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)title {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)achievedDescription {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)unachievedDescription {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSInteger)maximumPoints {
    return (NSInteger)LC32GKGetHostScalar(self, _cmd);
}

- (BOOL)isHidden {
    return (BOOL)LC32GKGetHostScalar(self, _cmd);
}

- (BOOL)isReplayable {
    return (BOOL)LC32GKGetHostScalar(self, _cmd);
}

@end

@implementation GKLeaderboardSet (LC32ForwardedProperties)

- (NSString *)title {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)groupIdentifier {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)identifier {
    return LC32GKGetHostObject(self, _cmd);
}

- (void)setIdentifier:(NSString *)identifier {
    LC32GKSetHostScalar(self, _cmd, [identifier host_self]);
}

@end

@implementation GKMatchRequest (LC32ForwardedProperties)

- (NSUInteger)minPlayers {
    return (NSUInteger)LC32GKGetHostScalar(self, _cmd);
}

- (void)setMinPlayers:(NSUInteger)minPlayers {
    LC32GKSetHostScalar(self, _cmd, minPlayers);
}

- (NSUInteger)maxPlayers {
    return (NSUInteger)LC32GKGetHostScalar(self, _cmd);
}

- (void)setMaxPlayers:(NSUInteger)maxPlayers {
    LC32GKSetHostScalar(self, _cmd, maxPlayers);
}

- (NSUInteger)playerGroup {
    return (NSUInteger)LC32GKGetHostScalar(self, _cmd);
}

- (void)setPlayerGroup:(NSUInteger)playerGroup {
    LC32GKSetHostScalar(self, _cmd, playerGroup);
}

- (uint32_t)playerAttributes {
    return (uint32_t)LC32GKGetHostScalar(self, _cmd);
}

- (void)setPlayerAttributes:(uint32_t)playerAttributes {
    LC32GKSetHostScalar(self, _cmd, playerAttributes);
}

- (NSString *)inviteMessage {
    return LC32GKGetHostObject(self, _cmd);
}

- (void)setInviteMessage:(NSString *)inviteMessage {
    LC32GKSetHostScalar(self, _cmd, [inviteMessage host_self]);
}

- (NSUInteger)defaultNumberOfPlayers {
    return (NSUInteger)LC32GKGetHostScalar(self, _cmd);
}

- (void)setDefaultNumberOfPlayers:(NSUInteger)defaultNumberOfPlayers {
    LC32GKSetHostScalar(self, _cmd, defaultNumberOfPlayers);
}

@end

@implementation GKInvite (LC32ForwardedProperties)

- (NSUInteger)playerGroup {
    return (NSUInteger)LC32GKGetHostScalar(self, _cmd);
}

- (uint32_t)playerAttributes {
    return (uint32_t)LC32GKGetHostScalar(self, _cmd);
}

@end

@implementation GKChallenge (LC32ForwardedProperties)

- (GKChallengeState)state {
    return (GKChallengeState)LC32GKGetHostScalar(self, _cmd);
}

- (NSDate *)issueDate {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSDate *)completionDate {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)message {
    return LC32GKGetHostObject(self, _cmd);
}

@end

@implementation GKTurnBasedMatch (LC32ForwardedProperties)

- (NSString *)matchID {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSDate *)creationDate {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSData *)matchData {
    return LC32GKGetHostObject(self, _cmd);
}

@end

@implementation GKTurnBasedParticipant (LC32ForwardedProperties)

- (GKTurnBasedMatchOutcome)matchOutcome {
    return (GKTurnBasedMatchOutcome)LC32GKGetHostScalar(self, _cmd);
}

- (void)setMatchOutcome:(GKTurnBasedMatchOutcome)matchOutcome {
    LC32GKSetHostScalar(self, _cmd, (uint64_t)(int64_t)matchOutcome);
}

- (NSDate *)timeoutDate {
    return LC32GKGetHostObject(self, _cmd);
}

@end

@implementation GKTurnBasedExchange (LC32ForwardedProperties)

- (NSString *)exchangeID {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSData *)data {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSDate *)sendDate {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSDate *)timeoutDate {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSDate *)completionDate {
    return LC32GKGetHostObject(self, _cmd);
}

@end

@implementation GKTurnBasedExchangeReply (LC32ForwardedProperties)

- (NSData *)data {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSDate *)replyDate {
    return LC32GKGetHostObject(self, _cmd);
}

@end

@implementation GKPlayer (LC32ForwardedProperties)

- (NSString *)alias {
    return LC32GKGetHostObject(self, _cmd);
}

- (NSString *)guestIdentifier {
    return LC32GKGetHostObject(self, _cmd);
}

@end

@implementation GKLocalPlayer (LC32ForwardedProperties)

- (BOOL)isUnderage {
    return (BOOL)LC32GKGetHostScalar(self, _cmd);
}

@end
