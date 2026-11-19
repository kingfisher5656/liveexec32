#import <MediaPlayer/MediaPlayer.h>
#import <LC32/LC32.h>

/*
 * The generated shim lists only methods MPMusicPlayerController itself
 * implements, and current MediaPlayer implements the skip methods on its
 * concrete subclasses (MPMusicPlayerSystemController/...Application...).
 * A guest call then fell into message forwarding, whose host
 * -forwardInvocation: (MediaPlayer's own) raises "unrecognized selector"
 * even though a direct send works. H.A.W.X.'s iPod-music option skips
 * tracks with these, so send them to the host object directly.
 */
@implementation MPMusicPlayerController (LC32Skip)

#define LC32_MUSIC_PLAYER_VOID_SHIM(name)                                     \
- (void)name {                                                                \
    static uint64_t hostCommand __attribute__((aligned(8)));                  \
    LC32InvokeHostSelector(self.host_self,                                    \
        LC32CachedHostSelector(&hostCommand, _cmd, NO), (uint64_t)0);         \
}

LC32_MUSIC_PLAYER_VOID_SHIM(skipToNextItem)
LC32_MUSIC_PLAYER_VOID_SHIM(skipToPreviousItem)
LC32_MUSIC_PLAYER_VOID_SHIM(skipToBeginning)

#undef LC32_MUSIC_PLAYER_VOID_SHIM

@end
