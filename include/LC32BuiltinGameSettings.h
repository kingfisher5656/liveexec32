#ifndef LC32_BUILTIN_GAME_SETTINGS_H
#define LC32_BUILTIN_GAME_SETTINGS_H

/*
 * LC32_ settings LiveExec32 itself applies to known games. Shared by the
 * runtime (LiveExec32Shared.cpp) and the settings screen (LC32HelpUI), which
 * shows them as what a game inherits.
 *
 * Order of precedence when a guest starts, first match wins:
 *   real environment > LiveExec32-Games/<app>.env > Info.plist
 *   LC32Environment > this table > LiveExec32.env
 */
#include <string.h>

typedef struct {
    const char *bundleIdentifier;
    const char *key;
    const char *value;
} LC32BuiltinGameSetting;

static const LC32BuiltinGameSetting LC32BuiltinGameSettings[] = {
    /* Dead Space 1.3.34: its widescreen UI patch is laid out for the full
     * screen, and under the 16:9 canvas the stock game aborts at launch
     * (its Burstly ad controller is made the window root, then its view is
     * moved under a view no controller owns). */
    {"com.ea.deadspace.bv", "LC32_ASPECT", "auto"},
    /* Air Mail (Unity): full-screen 3D with the 3:2 menu patch. */
    {"com.chillingo.airmail", "LC32_ASPECT", "auto"},
    /* Galaxy on Fire 2 HD: full screen, with its phone UI patch keeping the
     * HUD in a centred 16:9 box. */
    {"www.fishlabs.net.gof2hd", "LC32_ASPECT", "auto"},
    /* Epic Zen Garden (Unreal Engine 4, 30 MB executable): startup code
     * alone overflows the default 32 MiB JIT cache several times. */
    {"com.epicgames.ZenGarden", "LC32_JIT_CACHE_MB", "64"},
};

static inline const char *LC32BuiltinGameSettingValue(
        const char *bundleIdentifier, const char *key) {
    if(!bundleIdentifier || !key) return 0;
    for(unsigned i = 0; i < sizeof(LC32BuiltinGameSettings) /
            sizeof(LC32BuiltinGameSettings[0]); i++) {
        if(strcmp(LC32BuiltinGameSettings[i].bundleIdentifier,
                  bundleIdentifier) == 0 &&
                strcmp(LC32BuiltinGameSettings[i].key, key) == 0) {
            return LC32BuiltinGameSettings[i].value;
        }
    }
    return 0;
}

#endif
