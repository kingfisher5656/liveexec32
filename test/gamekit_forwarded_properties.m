#import <Foundation/Foundation.h>
#import <GameKit/GameKit.h>
#import <LC32/LC32.h>
#import <objc/message.h>

#include <stdio.h>

/* Local-only GameKit objects (no Game Center sign-in). Modern GameKit serves
 * these properties through GK*Internal forwarding targets; check the guest
 * accessors against direct native calls so guest-only storage cannot pass. */
static unsigned failures;
static unsigned checks;

static void check(BOOL condition, const char *description) {
    checks++;
    if(!condition) failures++;
    printf("%s %s\n", condition ? "PASS" : "FAIL", description);
}

static uint64_t nativeScalar(id receiver, SEL selector) {
    return LC32InvokeHostSelector([receiver host_self],
        LC32GetHostSelector(selector), (uint64_t)0);
}

static id nativeObject(id receiver, SEL selector) {
    return LC32InvokeHostObjectSelector([receiver host_self],
        LC32GetHostSelector(selector), (uint64_t)0);
}

/* An exchange or challenge made with -init has no internal object to
 * forward to, so even native GameKit throws for its properties. */
static BOOL nativeResponds(id receiver, SEL selector) {
    return (BOOL)LC32InvokeHostSelector([receiver host_self],
        LC32GetHostSelector(@selector(respondsToSelector:)),
        LC32GetHostSelector(selector), (uint64_t)0);
}

/* Locally constructed match/challenge objects mostly hold nil; the guest
 * getter must still return exactly what the native object reports. */
static BOOL sameNativeObject(id guestValue, id receiver, SEL selector) {
    return [guestValue host_self] == [nativeObject(receiver, selector) host_self];
}

static void checkObjects(id receiver, const char *className,
                         const SEL *selectors, unsigned count) {
    char description[128];
    for(unsigned i = 0; i < count; i++) {
        if(!nativeResponds(receiver, selectors[i])) {
            printf("SKIP %s %s: native object does not respond\n",
                   className, sel_getName(selectors[i]));
            continue;
        }
        id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selectors[i]);
        snprintf(description, sizeof(description), "%s %s matches native",
                 className, sel_getName(selectors[i]));
        check(sameNativeObject(value, receiver, selectors[i]), description);
    }
}

int main(void) {
    @autoreleasepool {
        /* Corona's gameNetwork.request("setHighScore") sequence. */
        GKScore *score = [[[GKScore alloc]
            initWithCategory:@"org.liveexec32.test.board"] autorelease];
        check(score != nil, "legacy initWithCategory: score initializes");
        score.value = 0x123456789LL;
        check((int64_t)nativeScalar(score, @selector(value)) == 0x123456789LL,
              "guest setValue: reaches the native score (64-bit)");
        check(score.value == 0x123456789LL,
              "guest value getter reads the native score");
        score.context = 0xfedcba9876543210ULL;
        check(nativeScalar(score, @selector(context)) == 0xfedcba9876543210ULL,
              "guest setContext: reaches the native score");
        check(score.context == 0xfedcba9876543210ULL,
              "guest context getter reads the native score");
        check([score.leaderboardIdentifier
                  isEqualToString:@"org.liveexec32.test.board"],
              "leaderboardIdentifier reflects the native initializer");
        check([[score category] isEqualToString:@"org.liveexec32.test.board"],
              "deprecated category reads the leaderboard identifier");
        [score setCategory:@"org.liveexec32.test.other"];
        check([nativeObject(score, @selector(leaderboardIdentifier))
                  isEqualToString:@"org.liveexec32.test.other"],
              "deprecated setCategory: reaches the native score");
        check([score.date host_self] ==
                  [nativeObject(score, @selector(date)) host_self],
              "date matches the native score");
        printf("formattedValue=%s rank=%ld\n",
               [[score.formattedValue description] UTF8String],
               (long)score.rank);

        GKAchievement *achievement = [[[GKAchievement alloc]
            initWithIdentifier:@"org.liveexec32.test.ach"] autorelease];
        achievement.percentComplete = 100;
        /* The exact property reads from Corona's achievement callback. */
        check([[achievement identifier]
                  isEqualToString:@"org.liveexec32.test.ach"],
              "achievement identifier");
        check([achievement isCompleted], "achievement isCompleted");
        check([achievement isHidden] == NO,
              "deprecated achievement isHidden returns without aborting");
        check([achievement respondsToSelector:@selector(showsCompletionBanner)],
              "achievement responds to showsCompletionBanner");

        GKLeaderboard *board = [[[GKLeaderboard alloc] init] autorelease];
        board.identifier = @"org.liveexec32.test.board";
        check([nativeObject(board, @selector(identifier))
                  isEqualToString:@"org.liveexec32.test.board"],
              "leaderboard setIdentifier: reaches the native leaderboard");
        check([[board category] isEqualToString:@"org.liveexec32.test.board"],
              "leaderboard category reads the native identifier");
        board.category = @"org.liveexec32.test.cat";
        check([nativeObject(board, @selector(identifier))
                  isEqualToString:@"org.liveexec32.test.cat"],
              "leaderboard setCategory: reaches the native leaderboard");
        printf("maxRange=%lu title=%s\n", (unsigned long)board.maxRange,
               [[board.title description] UTF8String]);

        /* Multiplayer: the request a game builds before presenting the
         * matchmaker. Every value must land on the native request. */
        GKMatchRequest *request = [[[GKMatchRequest alloc] init] autorelease];
        request.minPlayers = 2;
        request.maxPlayers = 4;
        request.defaultNumberOfPlayers = 3;
        request.playerGroup = 0xabcd;
        request.playerAttributes = 0xffff0000u;
        request.inviteMessage = @"org.liveexec32.test.invite";
        check(nativeScalar(request, @selector(minPlayers)) == 2,
              "match request setMinPlayers: reaches the native request");
        check(nativeScalar(request, @selector(maxPlayers)) == 4,
              "match request setMaxPlayers: reaches the native request");
        check(nativeScalar(request, @selector(defaultNumberOfPlayers)) == 3,
              "match request setDefaultNumberOfPlayers: reaches native");
        check(nativeScalar(request, @selector(playerGroup)) == 0xabcd,
              "match request setPlayerGroup: reaches the native request");
        check((uint32_t)nativeScalar(request, @selector(playerAttributes)) ==
                  0xffff0000u,
              "match request setPlayerAttributes: reaches native");
        check(request.minPlayers == 2 && request.maxPlayers == 4 &&
                  request.defaultNumberOfPlayers == 3 &&
                  request.playerGroup == 0xabcd &&
                  request.playerAttributes == 0xffff0000u,
              "match request scalar getters read the native request");
        /* Current native GameKit ignores the obsolete inviteMessage
         * (its own getter returns nil after the setter), so only require
         * that the guest reports what the native request holds. */
        check(sameNativeObject(request.inviteMessage, request,
                               @selector(inviteMessage)),
              "match request inviteMessage matches native");
        GKMatchRequest *requestCopy = [[request copy] autorelease];
        check(requestCopy.maxPlayers == 4 && requestCopy.playerGroup == 0xabcd,
              "copied match request keeps the native values");

        GKLeaderboardSet *set = [[[GKLeaderboardSet alloc] init] autorelease];
        set.identifier = @"org.liveexec32.test.set";
        check([nativeObject(set, @selector(identifier))
                  isEqualToString:@"org.liveexec32.test.set"],
              "leaderboard set setIdentifier: reaches the native set");
        check([set.identifier isEqualToString:@"org.liveexec32.test.set"],
              "leaderboard set identifier reads the native set");
        const SEL setSelectors[] = {
            @selector(title), @selector(groupIdentifier)};
        checkObjects(set, "GKLeaderboardSet", setSelectors, 2);

        GKTurnBasedParticipant *participant =
            [[[GKTurnBasedParticipant alloc] init] autorelease];
        participant.matchOutcome = GKTurnBasedMatchOutcomeWon;
        check(nativeScalar(participant, @selector(matchOutcome)) ==
                  GKTurnBasedMatchOutcomeWon,
              "participant setMatchOutcome: reaches the native participant");
        check(participant.matchOutcome == GKTurnBasedMatchOutcomeWon,
              "participant matchOutcome reads the native participant");
        const SEL participantSelectors[] = {@selector(timeoutDate)};
        checkObjects(participant, "GKTurnBasedParticipant",
                     participantSelectors, 1);

        GKTurnBasedMatch *match = [[[GKTurnBasedMatch alloc] init] autorelease];
        const SEL matchSelectors[] = {
            @selector(matchID), @selector(creationDate), @selector(matchData)};
        checkObjects(match, "GKTurnBasedMatch", matchSelectors, 3);

        GKTurnBasedExchange *exchange =
            [[[GKTurnBasedExchange alloc] init] autorelease];
        const SEL exchangeSelectors[] = {
            @selector(exchangeID), @selector(data), @selector(sendDate),
            @selector(timeoutDate), @selector(completionDate)};
        checkObjects(exchange, "GKTurnBasedExchange", exchangeSelectors, 5);

        GKTurnBasedExchangeReply *reply =
            [[[GKTurnBasedExchangeReply alloc] init] autorelease];
        const SEL replySelectors[] = {
            @selector(data), @selector(replyDate)};
        checkObjects(reply, "GKTurnBasedExchangeReply", replySelectors, 2);

        GKChallenge *challenge = [[[GKChallenge alloc] init] autorelease];
        if(nativeResponds(challenge, @selector(state))) {
            check((NSInteger)challenge.state ==
                      (NSInteger)nativeScalar(challenge, @selector(state)),
                  "challenge state matches native");
        } else {
            printf("SKIP GKChallenge state: native object does not respond\n");
        }
        const SEL challengeSelectors[] = {
            @selector(issueDate), @selector(completionDate),
            @selector(message)};
        checkObjects(challenge, "GKChallenge", challengeSelectors, 3);

        GKInvite *invite = [[[GKInvite alloc] init] autorelease];
        if(nativeResponds(invite, @selector(playerGroup))) {
            check(invite.playerGroup ==
                      (NSUInteger)nativeScalar(invite, @selector(playerGroup)) &&
                  invite.playerAttributes ==
                      (uint32_t)nativeScalar(invite, @selector(playerAttributes)),
                  "invite playerGroup/playerAttributes match native");
        } else {
            printf("SKIP GKInvite playerGroup: native object does not respond\n");
        }

        GKLocalPlayer *localPlayer = [GKLocalPlayer localPlayer];
        check(localPlayer.isUnderage ==
                  (BOOL)nativeScalar(localPlayer, @selector(isUnderage)),
              "local player isUnderage matches native");
        const SEL playerSelectors[] = {
            @selector(alias), @selector(guestIdentifier)};
        checkObjects(localPlayer, "GKLocalPlayer", playerSelectors, 2);
        printf("alias=%s\n", [[localPlayer.alias description] UTF8String]);
    }
    printf("%u/%u forwarded-property checks passed\n",
           checks - failures, checks);
    return failures ? 1 : 0;
}
