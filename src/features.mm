#include "features.h"
#include "hook.h"
#include "offsets.h"
#include "styxlog.h"

#include <stdint.h>

// ---------------------------------------------------------------------------
// Aim features (v1). Every hook is an il2cpp method pointer redirected in the
// game's data segments (see hook.mm) and forwards to the original implementation
// returned by styx_method_hook. Each feature can be compiled out independently.
//
// Tuning constants are the multipliers applied to the original return value.
// ---------------------------------------------------------------------------

#ifndef STYX_ENABLE_RECOIL
#define STYX_ENABLE_RECOIL 1
#endif
#ifndef STYX_ENABLE_SPREAD
#define STYX_ENABLE_SPREAD 1
#endif
#ifndef STYX_ENABLE_ASSIST
#define STYX_ENABLE_ASSIST 1
#endif

#define STYX_RECOIL_SCALE 0.05f   // 1.0 = vanilla, 0.0 = no recoil
#define STYX_SPREAD_SCALE 0.05f   // 1.0 = vanilla, 0.0 = no spread
#define STYX_ASSIST_SCALE 3.00f   // 1.0 = vanilla, >1 = stronger aim assist

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
#if STYX_ENABLE_RECOIL
static float hook_recoil(void *self, const void *method) {
    float v = orig_recoil ? orig_recoil(self, method) : 0.0f;
    static int n = 0;
    if (n < STYX_LOG_CALLS) { styx_log("[aim] GetScaleRecoil %.4f -> %.4f", v, v * STYX_RECOIL_SCALE); n++; }
    return v * STYX_RECOIL_SCALE;
}
#endif

// ---- GetRealSpreadModifier -------------------------------------------------
#if STYX_ENABLE_SPREAD
static float hook_spread(void *self, const void *method) {
    float v = orig_spread ? orig_spread(self, method) : 0.0f;
    static int n = 0;
    if (n < STYX_LOG_CALLS) { styx_log("[aim] GetRealSpreadModifier %.4f -> %.4f", v, v * STYX_SPREAD_SCALE); n++; }
    return v * STYX_SPREAD_SCALE;
}
#endif

// ---- GetAssitAimSpeed ------------------------------------------------------
#if STYX_ENABLE_ASSIST
static float hook_assist(void *self, StyVector3 pos, float assistDis, float dis,
                         float angle, bool isPVE, bool gamepad, const void *method) {
    float v = orig_assist ? orig_assist(self, pos, assistDis, dis, angle, isPVE, gamepad, method) : 0.0f;
    static int n = 0;
    if (n < STYX_LOG_CALLS) { styx_log("[aim] GetAssitAimSpeed %.4f -> %.4f", v, v * STYX_ASSIST_SCALE); n++; }
    return v * STYX_ASSIST_SCALE;
}
#endif

void styx_aim_install(void) {
    styx_log("---- aim hooks ----");

#if STYX_ENABLE_RECOIL
    {
        uintptr_t orig = 0;
        size_t n = styx_method_hook(STYX_RVA_Pawn_GetScaleRecoil, (void *)hook_recoil, &orig);
        orig_recoil = (fn_self_t)orig;
        styx_log("[aim] recoil: %zu slot(s), orig=%p", n, (void *)orig);
    }
#endif

#if STYX_ENABLE_SPREAD
    {
        uintptr_t orig = 0;
        size_t n = styx_method_hook(STYX_RVA_Pawn_GetRealSpreadModifier, (void *)hook_spread, &orig);
        orig_spread = (fn_self_t)orig;
        styx_log("[aim] spread: %zu slot(s), orig=%p", n, (void *)orig);
    }
#endif

#if STYX_ENABLE_ASSIST
    {
        uintptr_t orig = 0;
        size_t n = styx_method_hook(STYX_RVA_Pawn_GetAssitAimSpeed, (void *)hook_assist, &orig);
        orig_assist = (fn_assist_t)orig;
        styx_log("[aim] assist: %zu slot(s), orig=%p", n, (void *)orig);
    }
#endif

    styx_log("-------------------");
}
