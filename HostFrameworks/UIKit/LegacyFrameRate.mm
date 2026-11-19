/*
 * Frame-rate limiting for ARM32 guests.
 *
 * LiveContainer sets CADisableMinimumFrameDurationOnPhone, so on ProMotion
 * phones a guest CADisplayLink with the legacy default frameInterval of 1
 * fires at 120 Hz. Every pre-iOS-10 game was written for a 60 Hz display:
 * it either does its per-frame work twice as often (twice the CPU, GPU and
 * bridge load for no visible gain) or runs its fixed-step logic too fast.
 *
 * Guest display links therefore get the legacy meaning back: frameInterval N
 * is 60/N frames per second, and duration is a 60 Hz refresh period. Guest
 * presentRenderbuffer: calls are also paced, which caps render loops driven
 * by NSTimer or a private thread that never wait for the display.
 *
 * LC32_MAX_FPS (host environment) overrides the 60 fps cap (a lower value
 * also applies on 60 Hz screens); 0 disables both limits. Native (non-guest) CADisplayLink and EAGL users are untouched: the
 * hooks only apply to calls crossing the guest bridge.
 */
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include "../LC32/lc32_profile.h"
#include <mach/mach_time.h>
#include <math.h>
#include <mutex>
#include <stdlib.h>
#include <unordered_map>
#import "../LC32/host_selector_hooks.h"
#include "../../include/LC32GameProfile.h"

/* A no-op display link whose only job is to ask ProMotion for a high refresh
 * rate. Guest render threads that present without a display link (9mm) give
 * the system no rate hint, so the panel would otherwise stay at 60 Hz. */
@interface LC32HighRefreshRequest : NSObject
- (void)tick:(CADisplayLink *)link;
@end
@implementation LC32HighRefreshRequest
- (void)tick:(CADisplayLink *)link {}
@end

namespace {

constexpr double LegacyDisplayRate = 60.0;

double ConfiguredMaxFramesPerSecond() {
    static const double value = [] {
        const char *text = getenv("LC32_MAX_FPS");
        // Games whose render loop is uncapped and time-based may present
        // faster than the legacy rate (LC32GameProfile.h).
        if(!text || !*text)
            return LC32GameProfileMaxFramesPerSecond(LegacyDisplayRate);
        char *end = nullptr;
        const double parsed = strtod(text, &end);
        if(end == text || !isfinite(parsed) || parsed < 0) {
            return LegacyDisplayRate;
        }
        return parsed;
    }();
    return value;
}

bool FrameRateLimitEnabled() {
    return ConfiguredMaxFramesPerSecond() > 0;
}

/* Only ProMotion displays run faster than the legacy rate by default. */
bool DisplayExceedsLegacyRate() {
    // A plain property read: guest worker threads may create display links,
    // and waiting for the main thread from them could deadlock.
    static const bool value =
        UIScreen.mainScreen.maximumFramesPerSecond > LegacyDisplayRate;
    return value;
}

char GuestFrameIntervalKey;
char GuestPreferredFramesKey;

NSInteger StoredInteger(id object, const void *key, NSInteger fallback) {
    NSNumber *value = objc_getAssociatedObject(object, key);
    return value ? value.integerValue : fallback;
}

void StoreInteger(id object, const void *key, NSInteger value) {
    objc_setAssociatedObject(object, key, @(value),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

double GuestLinkFramesPerSecond(CADisplayLink *link) {
    const NSInteger preferred =
        StoredInteger(link, &GuestPreferredFramesKey, 0);
    double rate = preferred > 0
        ? (double)preferred
        : LegacyDisplayRate /
            (double)MAX((NSInteger)1,
                StoredInteger(link, &GuestFrameIntervalKey, 1));
    return MIN(rate, ConfiguredMaxFramesPerSecond());
}

bool GuestLinkIsLimited(CADisplayLink *link) {
    return link != nil && FrameRateLimitEnabled() &&
        (DisplayExceedsLegacyRate() ||
            ConfiguredMaxFramesPerSecond() < LegacyDisplayRate);
}

void ApplyGuestLinkRate(CADisplayLink *link) {
    if(!GuestLinkIsLimited(link)) return;
    if(@available(iOS 15.0, *)) {
        const float rate = (float)GuestLinkFramesPerSecond(link);
        link.preferredFrameRateRange = CAFrameRateRangeMake(rate, rate, rate);
        if(getenv("LC32_FPS_LOG")) {
            fprintf(stderr, "LC32: guest display link %p limited to %.1f fps\n",
                (__bridge void *)link, rate);
        }
    }
}

void GuestDisplayLinkAdded(id receiver, const uint64_t *) {
    ApplyGuestLinkRate((CADisplayLink *)receiver);
}

/*
 * Presentation pacing. Each (context, renderbuffer) pair advances its own
 * deadline by one frame per present. A present that arrives clearly early
 * sleeps until shortly before its slot; vsync-driven presents arrive on time
 * and never sleep. After a stall the deadline resynchronises instead of
 * allowing a catch-up burst.
 */
struct PresentKey {
    const void *context;
    GLint renderbuffer;
    bool operator==(const PresentKey &other) const {
        return context == other.context &&
            renderbuffer == other.renderbuffer;
    }
};

struct PresentKeyHash {
    size_t operator()(const PresentKey &key) const {
        return std::hash<const void *>()(key.context) ^
            (std::hash<GLint>()(key.renderbuffer) << 1);
    }
};

std::mutex presentMutex;
std::unordered_map<PresentKey, uint64_t, PresentKeyHash> presentDeadlines;

uint64_t NanosecondsToTicks(uint64_t nanoseconds) {
    static mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        return info;
    }();
    return nanoseconds * timebase.denom / timebase.numer;
}

/* LC32_FPS_LOG=1 prints the guest's present rate every five seconds. */
void LogGuestPresentRate() {
    static const bool enabled = getenv("LC32_FPS_LOG") != nullptr;
    if(!enabled) return;
    static std::mutex logMutex;
    static uint64_t windowStart = 0;
    static unsigned presents = 0;
    const std::lock_guard<std::mutex> lock(logMutex);
    const uint64_t now = mach_absolute_time();
    if(windowStart == 0) windowStart = now;
    ++presents;
    const uint64_t window = NanosecondsToTicks(5000000000ULL);
    if(now - windowStart >= window) {
        fprintf(stderr, "LC32: guest presents %.1f fps\n",
            presents / (5.0 * (double)(now - windowStart) / window));
        windowStart = now;
        presents = 0;
    }
}

void RequestHighRefreshRate(double rate) {
    static std::once_flag requested;
    std::call_once(requested, [rate] {
        if(@available(iOS 15.0, *)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                const float maximum = (float)MIN(rate,
                    (double)UIScreen.mainScreen.maximumFramesPerSecond);
                CADisplayLink *link = [CADisplayLink
                    displayLinkWithTarget:[LC32HighRefreshRequest new]
                                 selector:@selector(tick:)];
                link.preferredFrameRateRange = CAFrameRateRangeMake(
                    (float)LegacyDisplayRate, maximum, maximum);
                [link addToRunLoop:NSRunLoop.mainRunLoop
                           forMode:NSRunLoopCommonModes];
                fprintf(stderr, "LC32: requested %.0f Hz display refresh\n",
                    maximum);
            });
        }
    });
}

void PaceGuestPresent(EAGLContext *context) {
    LogGuestPresentRate();
    if(!FrameRateLimitEnabled()) return;
    const double rate = ConfiguredMaxFramesPerSecond();
    if(rate > LegacyDisplayRate && DisplayExceedsLegacyRate()) {
        RequestHighRefreshRate(rate);
    }
    const uint64_t interval = NanosecondsToTicks(
        (uint64_t)llround(1e9 / rate));
    // Ordinary display-link jitter must not cost a frame.
    const uint64_t tolerance = NanosecondsToTicks(2000000);

    GLint renderbuffer = 0;
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
    const PresentKey key{(__bridge const void *)context, renderbuffer};

    uint64_t wakeAt = 0;
    {
        const std::lock_guard<std::mutex> lock(presentMutex);
        const uint64_t now = mach_absolute_time();
        auto found = presentDeadlines.find(key);
        if(found == presentDeadlines.end()) {
            if(presentDeadlines.size() > 64) presentDeadlines.clear();
            presentDeadlines.emplace(key, now + interval);
            return;
        }
        uint64_t &deadline = found->second;
        if(deadline + interval < now) {
            deadline = now + interval;
            return;
        }
        if(deadline > now + tolerance) wakeAt = deadline - tolerance;
        deadline += interval;
    }
    if(wakeAt != 0) mach_wait_until(wakeAt);
}

} // namespace

@interface CADisplayLink (LC32GuestFrameRate)
- (void)lc32_guestSetFrameInterval:(NSInteger)interval;
- (NSInteger)lc32_guestFrameInterval;
- (void)lc32_guestSetPreferredFramesPerSecond:(NSInteger)rate;
- (NSInteger)lc32_guestPreferredFramesPerSecond;
- (CFTimeInterval)lc32_guestDuration;
@end

@implementation CADisplayLink (LC32GuestFrameRate)

+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(addToRunLoop:forMode:),
        {nullptr, GuestDisplayLinkAdded});
    LC32RegisterHostSelectorHook(self, @selector(setFrameInterval:),
        {@selector(lc32_guestSetFrameInterval:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(frameInterval),
        {@selector(lc32_guestFrameInterval), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(setPreferredFramesPerSecond:),
        {@selector(lc32_guestSetPreferredFramesPerSecond:), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(preferredFramesPerSecond),
        {@selector(lc32_guestPreferredFramesPerSecond), nullptr});
    LC32RegisterHostSelectorHook(self, @selector(duration),
        {@selector(lc32_guestDuration), nullptr});
}

- (void)lc32_guestSetFrameInterval:(NSInteger)interval {
    if(!GuestLinkIsLimited(self)) {
        const SEL original = @selector(setFrameInterval:);
        ((void (*)(id, SEL, NSInteger))LC32NativeHostMethod(self, original))(
            self, original, interval);
        return;
    }
    // Native frameInterval counts 120 Hz refreshes here; keep the guest's
    // 60 Hz meaning in the rate range instead.
    StoreInteger(self, &GuestFrameIntervalKey, MAX((NSInteger)1, interval));
    ApplyGuestLinkRate(self);
}

- (NSInteger)lc32_guestFrameInterval {
    if(GuestLinkIsLimited(self)) {
        return StoredInteger(self, &GuestFrameIntervalKey, 1);
    }
    const SEL original = @selector(frameInterval);
    return ((NSInteger (*)(id, SEL))LC32NativeHostMethod(self, original))(
        self, original);
}

- (void)lc32_guestSetPreferredFramesPerSecond:(NSInteger)rate {
    if(!GuestLinkIsLimited(self)) {
        const SEL original = @selector(setPreferredFramesPerSecond:);
        ((void (*)(id, SEL, NSInteger))LC32NativeHostMethod(self, original))(
            self, original, rate);
        return;
    }
    StoreInteger(self, &GuestPreferredFramesKey, MAX((NSInteger)0, rate));
    ApplyGuestLinkRate(self);
}

- (NSInteger)lc32_guestPreferredFramesPerSecond {
    if(GuestLinkIsLimited(self)) {
        return StoredInteger(self, &GuestPreferredFramesKey, 0);
    }
    const SEL original = @selector(preferredFramesPerSecond);
    return ((NSInteger (*)(id, SEL))LC32NativeHostMethod(self, original))(
        self, original);
}

- (CFTimeInterval)lc32_guestDuration {
    const SEL original = @selector(duration);
    const CFTimeInterval native =
        ((CFTimeInterval (*)(id, SEL))LC32NativeHostMethod(self, original))(
            self, original);
    // Legacy games compute their step as duration * frameInterval.
    if(GuestLinkIsLimited(self)) return MAX(native, 1.0 / LegacyDisplayRate);
    return native;
}

@end

@interface EAGLContext (LC32GuestFramePacing)
- (BOOL)lc32_guestPresentRenderbuffer:(NSUInteger)target;
@end

@implementation EAGLContext (LC32GuestFramePacing)

+ (void)load {
    LC32RegisterHostSelectorHook(self, @selector(presentRenderbuffer:),
        {@selector(lc32_guestPresentRenderbuffer:), nullptr});
}

- (BOOL)lc32_guestPresentRenderbuffer:(NSUInteger)target {
    // Drain what presenting autoreleases (drawables, command buffers): on a
    // guest pthread the host pool otherwise lives as long as the thread.
    @autoreleasepool {
    const uint64_t paceStart = LC32ProfileNow();
    PaceGuestPresent(self);
    const uint64_t presentStart = LC32ProfileNow();
    const SEL original = @selector(presentRenderbuffer:);
    const BOOL result = ((BOOL (*)(id, SEL, NSUInteger))LC32NativeHostMethod(
        self, original))(self, original, target);
    if(LC32ProfileActive)
        LC32ProfileAddPresent(presentStart - paceStart,
            mach_absolute_time() - presentStart);
    return result;
    }
}

@end
