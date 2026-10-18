#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Runtime feature flags. Every feature defaults to OFF; the menu toggles them
// live (the hooks read these atomics on every call) and the state is persisted
// to Documents/GPMGameCore.cfg so it survives a relaunch.
// ---------------------------------------------------------------------------

typedef enum {
    STYX_FEAT_ASSIST     = 0,   // aim assist
    STYX_FEAT_RECOIL     = 1,   // no recoil
    STYX_FEAT_SPREAD     = 2,   // no spread
    STYX_FEAT_ESP        = 3,   // draw enemy boxes
    STYX_FEAT_ESP_HEALTH = 4,   // draw enemy health bars
    STYX_FEAT_ESP_LINES  = 5,   // draw tracer lines to enemies
    STYX_FEAT_SKIP_TUT   = 6,   // skip guest tutorial
    STYX_FEAT_COUNT
} styx_feature;

// Load Documents/GPMGameCore.cfg (missing entries stay at their default = off).
void styx_cfg_init(void);

// Persist the current flags to Documents/GPMGameCore.cfg.
void styx_cfg_save(void);

bool styx_feat(styx_feature f);
void styx_feat_set(styx_feature f, bool on);
void styx_feat_toggle(styx_feature f);

// Aim-assist strength, 0..100, returned verbatim by the aim-assist hook while
// STYX_FEAT_ASSIST is on (absolute override, matching the Android mod). Persisted
// in GPMGameCore.cfg as `assist_strength=NN`. Default 50.
float styx_assist_strength(void);
void  styx_assist_strength_set(float v);

// Stable key used in GPMGameCore.cfg (e.g. "esp").
const char *styx_feat_key(styx_feature f);
// Human label shown in the menu (e.g. "ESP").
const char *styx_feat_label(styx_feature f);

#ifdef __cplusplus
}
#endif
