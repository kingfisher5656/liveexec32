#pragma once
/*
 * Per-game quality profile for ARM32 guests.
 *
 * Some legacy engines gate their best rendering path on hardware they could
 * recognise at the time (a PowerVR GL_VERSION, a Retina scale of at most 2,
 * a 60 Hz display). Every Apple-GPU device outperforms those, so for known
 * bundles the host reports the capabilities that unlock the high path.
 *
 * Each field has an environment override (see LC32GameProfile* helpers) so a
 * value can be tried on another game, or turned off, without a rebuild.
 */
#include <atomic>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

struct LC32GameProfile {
    const char *bundleIdentifier;
    /* Appended to GL_VERSION; Glitch-engine games look for "IMGSGX<n>" and
     * enable 2x MSAA and full-resolution post effects for n > 542. */
    const char *glVersionTag;
    /* Highest UIScreen.scale reported on a fixed phone canvas (default 2). */
    double canvasScale;
    /* Present-rate cap when LC32_MAX_FPS is unset (default 60). */
    double maxFramesPerSecond;
    /* Give a phone-only landscape bundle with 568-point launch art the fixed
     * 320x568 canvas under native legacy rotation (see
     * LC32BundleUsesNativeTallLandscapePhoneCanvas). */
    bool tallPhoneCanvas;
    /* The landscape-only root controller's view is the GL view itself and the
     * engine draws a landscape picture without turning it, relying on UIKit
     * to turn and resize that root (as iOS 6+ does for every such root; see
     * LC32LegacyPhoneCanvasGeometryMode). Gives it the landscape canvas. */
    bool landscapeGLRoot;
};

inline const LC32GameProfile *LC32CurrentGameProfile() {
    static const LC32GameProfile profiles[] = {
        /* 9mm (Gameloft Glitch): uncapped render thread, variable timestep;
         * ran at scale 3 on device before the fixed canvas existed. */
        { "com.gameloft.9mm", " IMGSGX543", 3.0, 120.0, false },
        /* DJMAX Ray: lays out for 568 points only on a screen exactly 568
         * tall; elsewhere it draws a 480x320 picture into a corner. */
        { "com.neowizInternet.game.djmaxray", nullptr, 0, 0, true },
        /* RAGE HD (SDK 4.2): EAGLView root of a landscape-only controller,
         * drawn with a 480x320 projection; the portrait canvas showed its
         * menu sideways and squeezed. */
        { "com.idsoftware.ragehd", nullptr, 0, 0, false, true },
    };
    static const LC32GameProfile none = {};
    static std::atomic<const LC32GameProfile *> cached{nullptr};
    if(const LC32GameProfile *known = cached.load(std::memory_order_acquire))
        return known == &none ? nullptr : known;
    /* NSBundle.mainBundle is the guest .app under LiveContainer (and in the
     * simulator harness). Retry until it is available. */
    using Send = id (*)(id, SEL);
    using SendString = const char *(*)(id, SEL);
    id bundleClass = reinterpret_cast<id>(objc_getClass("NSBundle"));
    id bundle = bundleClass ? reinterpret_cast<Send>(objc_msgSend)(
        bundleClass, sel_registerName("mainBundle")) : nil;
    id identifier = bundle ? reinterpret_cast<Send>(objc_msgSend)(
        bundle, sel_registerName("bundleIdentifier")) : nil;
    const char *value = identifier ? reinterpret_cast<SendString>(
        objc_msgSend)(identifier, sel_registerName("UTF8String")) : nullptr;
    if(!value) return nullptr;
    const LC32GameProfile *found = &none;
    for(const auto &profile : profiles) {
        if(strcmp(value, profile.bundleIdentifier) == 0) {
            found = &profile;
            break;
        }
    }
    cached.store(found, std::memory_order_release);
    return found == &none ? nullptr : found;
}

/* Returns the parsed variable, or `fallback` when unset/unparsable. */
inline double LC32GameProfileNumberFromEnv(const char *name, double fallback) {
    const char *text = getenv(name);
    if(!text || !*text) return fallback;
    char *end = nullptr;
    const double parsed = strtod(text, &end);
    return end == text ? fallback : parsed;
}

/* LC32_GL_VERSION_TAG=<text> forces a tag; set but empty disables it. */
inline const char *LC32GameProfileGLVersionTag() {
    if(const char *forced = getenv("LC32_GL_VERSION_TAG"))
        return *forced ? forced : nullptr;
    const LC32GameProfile *profile = LC32CurrentGameProfile();
    return profile ? profile->glVersionTag : nullptr;
}

/* LC32_CANVAS_SCALE=<n> sets the fixed-canvas scale cap. */
inline double LC32GameProfileCanvasScale() {
    const LC32GameProfile *profile = LC32CurrentGameProfile();
    const double fallback = profile && profile->canvasScale > 0
        ? profile->canvasScale : 2.0;
    const double value = LC32GameProfileNumberFromEnv("LC32_CANVAS_SCALE",
        fallback);
    return value > 0 ? value : 2.0;
}

/* Default present cap; LC32_MAX_FPS still overrides it. */
inline double LC32GameProfileMaxFramesPerSecond(double fallback) {
    const LC32GameProfile *profile = LC32CurrentGameProfile();
    return profile && profile->maxFramesPerSecond > 0
        ? profile->maxFramesPerSecond : fallback;
}

/* LC32_TALL_PHONE_CANVAS=1 tries the 320x568 canvas on another eligible
 * game; =0 turns it off. */
inline bool LC32GameProfileTallPhoneCanvas() {
    if(const char *forced = getenv("LC32_TALL_PHONE_CANVAS"))
        return forced[0] == '1';
    const LC32GameProfile *profile = LC32CurrentGameProfile();
    return profile && profile->tallPhoneCanvas;
}

/* LC32_LANDSCAPE_GL_ROOT=1 tries the landscape canvas for a pre-iOS-6 GL
 * root on another game; =0 turns it off. */
inline bool LC32GameProfileLandscapeGLRoot() {
    if(const char *forced = getenv("LC32_LANDSCAPE_GL_ROOT"))
        return forced[0] == '1';
    const LC32GameProfile *profile = LC32CurrentGameProfile();
    return profile && profile->landscapeGLRoot;
}
