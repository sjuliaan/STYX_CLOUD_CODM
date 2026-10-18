#include "features.h"
#include "base.h"
#include "config.h"
#include "hook.h"
#include "offsets.h"
#include "styxlog.h"

#include <stdint.h>

// ---------------------------------------------------------------------------
// Feature hooks. Every hook is an il2cpp method pointer redirected in the
// game's data segments (see hook.mm) and forwards to the original implementation
// returned by styx_method_hook. Each hook is installed once but consults its
// runtime config flag on every call, so the menu can toggle it live.
// ---------------------------------------------------------------------------

#define STYX_RECOIL_SCALE 0.05f   // 1.0 = vanilla, 0.0 = no recoil
#define STYX_SPREAD_SCALE 0.05f   // 1.0 = vanilla, 0.0 = no spread

// UnityEngine.Vector3_o (il2cpp) is exactly { float x, y, z; }.
typedef struct { float x, y, z; } StyVector3;

// il2cpp instance-method signatures (from script.json):
//   float GetScaleRecoil(WeaponFireComponent_Instant*, const MethodInfo*)
//   float GetRealSpreadModifier(WeaponFireComponent_Instant*, const MethodInfo*)
//   float GetAssitAimSpeed(PlayerController*, Vector3, float, float, float,
//                          bool, bool, const MethodInfo*)
typedef float (*fn_self_t)(void *self, const void *method);
typedef float (*fn_assist_t)(void *self, StyVector3 pos, float assistDis, float dis,
                             float angle, bool isPVE, bool gamepad, const void *method);

static fn_self_t   orig_recoil  = 0;
static fn_self_t   orig_spread  = 0;
static fn_assist_t orig_assist  = 0;

#define STYX_LOG_CALLS 5

// ---- GetScaleRecoil --------------------------------------------------------
static float hook_recoil(void *self, const void *method) {
    float v = orig_recoil ? orig_recoil(self, method) : 0.0f;
    if (!styx_feat(STYX_FEAT_RECOIL)) return v;
    static int n = 0;
    if (n < STYX_LOG_CALLS) { styx_log("[aim] GetScaleRecoil %.4f -> %.4f", v, v * STYX_RECOIL_SCALE); n++; }
    return v * STYX_RECOIL_SCALE;
}

// ---- GetRealSpreadModifier -------------------------------------------------
static float hook_spread(void *self, const void *method) {
    float v = orig_spread ? orig_spread(self, method) : 0.0f;
    if (!styx_feat(STYX_FEAT_SPREAD)) return v;
    static int n = 0;
    if (n < STYX_LOG_CALLS) { styx_log("[aim] GetRealSpreadModifier %.4f -> %.4f", v, v * STYX_SPREAD_SCALE); n++; }
    return v * STYX_SPREAD_SCALE;
}

// ---- GetAssitAimSpeed ------------------------------------------------------
// Absolute override (same semantics as the Android mod): while the feature is on
// we return the strength slider value (0..100) verbatim and DO NOT call the
// original. The slider is the aim speed, so 0 turns assist off.
static float hook_assist(void *self, StyVector3 pos, float assistDis, float dis,
                         float angle, bool isPVE, bool gamepad, const void *method) {
    if (styx_feat(STYX_FEAT_ASSIST)) {
        float s = styx_assist_strength();
        static int n = 0;
        if (n < STYX_LOG_CALLS) { styx_log("[aim] GetAssitAimSpeed -> %.2f (orig skipped)", (double)s); n++; }
        return s;
    }
    return orig_assist ? orig_assist(self, pos, assistDis, dis, angle, isPVE, gamepad, method) : 0.0f;
}

void styx_aim_install(void) {
    styx_log("---- aim hooks ----");

    {
        uintptr_t orig = 0;
        size_t n = styx_method_hook(STYX_RVA_Pawn_GetScaleRecoil, (void *)hook_recoil, &orig);
        orig_recoil = (fn_self_t)orig;
        styx_log("[aim] recoil: %zu slot(s), orig=%p", n, (void *)orig);
    }
    {
        uintptr_t orig = 0;
        size_t n = styx_method_hook(STYX_RVA_Pawn_GetRealSpreadModifier, (void *)hook_spread, &orig);
        orig_spread = (fn_self_t)orig;
        styx_log("[aim] spread: %zu slot(s), orig=%p", n, (void *)orig);
    }
    {
        uintptr_t orig = 0;
        size_t n = styx_method_hook(STYX_RVA_Pawn_GetAssitAimSpeed, (void *)hook_assist, &orig);
        orig_assist = (fn_assist_t)orig;
        styx_log("[aim] assist: %zu slot(s), orig=%p", n, (void *)orig);
    }

    styx_log("-------------------");
}
