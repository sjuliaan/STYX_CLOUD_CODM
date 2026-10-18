#include "game.h"
#include "base.h"
#include "offsets.h"
#include "styxlog.h"

#include <string.h>
#include <math.h>

// ---------------------------------------------------------------------------
// Typed il2cpp call wrappers.
//
// Static methods (dump.cs) take only the MethodInfo* which is unused by the
// generated code, so we pass NULL. Instance methods take (this, MethodInfo*).
// ---------------------------------------------------------------------------

// static MatchGame*   GamePlay.get_MatchGame(const MethodInfo*)
typedef void *(*fn_static_ptr_t)(const void *method);
// instance  void*     BaseGame.GetEnemyPawns(this, const MethodInfo*)
typedef void *(*fn_self_ptr_t)(void *self, const void *method);
// instance  bool      Pawn.get_IsAlive(this, const MethodInfo*)
typedef bool  (*fn_self_bool_t)(void *self, const void *method);
// instance  Vector3   Transform.get_position(this, const MethodInfo*)
typedef styx_v3 (*fn_self_v3_t)(void *self, const void *method);
// instance  Vector3   Camera.WorldToScreenPoint(this, Vector3, const MethodInfo*)
typedef styx_v3 (*fn_self_arg_v3_t)(void *self, styx_v3 pos, const void *method);
// static    int32     Screen.get_width/height(const MethodInfo*)
typedef int32_t (*fn_static_int_t)(const void *method);
// static    void      MSDKLogin.ResetGuest(const MethodInfo*)
typedef void (*fn_static_void_t)(const void *method);

// Cheap plausibility check for a pointer read out of game memory. il2cpp
// objects live in the app's address space and are 8-byte aligned. This filters
// obvious garbage before we dereference (a wrong offset should skip, not fault).
static inline bool styx_ptr_ok(uintptr_t p) {
    return p >= 0x100000000ULL && p < 0x800000000000ULL && (p & 7) == 0;
}

void *styx_game_matchgame(void) {
    fn_static_ptr_t f = (fn_static_ptr_t)styx_addr(STYX_RVA_GamePlay_get_MatchGame);
    return f ? f(NULL) : NULL;
}

void *styx_game_localpawn(void) {
    fn_static_ptr_t f = (fn_static_ptr_t)styx_addr(STYX_RVA_GamePlay_get_LocalPawn);
    return f ? f(NULL) : NULL;
}

void *styx_game_camera(void) {
    fn_static_ptr_t f = (fn_static_ptr_t)styx_addr(STYX_RVA_Camera_get_main);
    return f ? f(NULL) : NULL;
}

size_t styx_game_enemy_pawns(void **out, size_t max) {
    if (!out || max == 0) return 0;

    void *mg = styx_game_matchgame();
    if (!styx_ptr_ok((uintptr_t)mg)) return 0;

    // Read the list field DIRECTLY (BaseGame.EnemyPawns @ +0x178) instead of
    // calling GetEnemyPawns(). This is exactly what the proven Android mod and
    // the rival dylib do, and removes one call dependency.
    void *list = *(void **)((uintptr_t)mg + BaseGame_EnemyPawns);
    if (!styx_ptr_ok((uintptr_t)list)) return 0;

    // PawnList derives from List<Pawn>: { _items @ +0x10, _size @ +0x18 }.
    void   *items = *(void **)((uintptr_t)list + IL2CPP_LIST_ITEMS);
    int32_t size  = *(int32_t *)((uintptr_t)list + IL2CPP_LIST_SIZE);
    if (!styx_ptr_ok((uintptr_t)items) || size <= 0) return 0;

    // Clamp defensively against a mis-read _size.
    if (size > 512) size = 512;
    if ((size_t)size > max) size = (int32_t)max;

    // Element data starts at +0x20 (see IL2CPP_ARRAY_DATA), stride 8.
    const uintptr_t data = (uintptr_t)items + IL2CPP_ARRAY_DATA;
    size_t n = 0;
    for (int32_t i = 0; i < size; i++) {
        uintptr_t pawn = *(uintptr_t *)(data + (uintptr_t)i * sizeof(void *));
        if (styx_ptr_ok(pawn)) out[n++] = (void *)pawn;
    }
    return n;
}

bool styx_game_pawn_alive(void *pawn) {
    if (!pawn) return false;
    // Direct field read of Pawn.m_IsAlive (@ +0x548) — matches Android/rival and
    // avoids a per-pawn virtual-ish call.
    return *(volatile uint8_t *)((uintptr_t)pawn + Pawn_m_IsAlive) != 0;
}

bool styx_v3_finite(styx_v3 v) {
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z);
}

static bool styx_game_pawn_bone(void *pawn, uintptr_t field_off, styx_v3 *out) {
    if (!pawn || !out) return false;
    uintptr_t t = *(uintptr_t *)((uintptr_t)pawn + field_off);
    if (!styx_ptr_ok(t)) return false;
    fn_self_v3_t getpos = (fn_self_v3_t)styx_addr(STYX_RVA_Transform_get_position);
    if (!getpos) return false;
    styx_v3 v = getpos((void *)t, NULL);
    if (!styx_v3_finite(v)) return false;
    *out = v;
    return true;
}

bool styx_game_pawn_position(void *pawn, styx_v3 *out) {
    return styx_game_pawn_bone(pawn, Pawn_m_Mesh, out);
}

bool styx_game_pawn_location(void *pawn, styx_v3 *out) {
    if (!pawn || !out) return false;
    styx_v3 v = *(styx_v3 *)((uintptr_t)pawn + Pawn_m_Location);
    if (!styx_v3_finite(v)) return false;
    *out = v;
    return true;
}

bool styx_game_pawn_head(void *pawn, styx_v3 *out) {
    return styx_game_pawn_bone(pawn, Pawn_m_HeadBone, out);
}

bool styx_game_world_to_screen(styx_v3 world, float *sx, float *sy, float *sz) {
    void *cam = styx_game_camera();
    if (!cam) return false;
    fn_self_arg_v3_t f = (fn_self_arg_v3_t)styx_addr(STYX_RVA_Camera_WorldToScreenPoint);
    if (!f) return false;
    styx_v3 r = f(cam, world, NULL);
    if (sx) *sx = r.x;
    if (sy) *sy = r.y;
    if (sz) *sz = r.z;
    return true;
}

void styx_game_screen_size(int *w, int *h) {
    fn_static_int_t fw = (fn_static_int_t)styx_addr(STYX_RVA_Screen_get_width);
    fn_static_int_t fh = (fn_static_int_t)styx_addr(STYX_RVA_Screen_get_height);
    if (w) *w = fw ? fw(NULL) : 0;
    if (h) *h = fh ? fh(NULL) : 0;
}

void styx_game_reset_guest(void) {
    fn_static_void_t f = (fn_static_void_t)styx_addr(STYX_RVA_MSDKLogin_ResetGuest);
    styx_log("[guest] ResetGuest @ %p -> calling", (void *)f);
    if (f) f(NULL);
    styx_log("[guest] ResetGuest returned");
}

// ---------------------------------------------------------------------------
// One-shot diagnostics. Called once from the ESP after the first frames so the
// log shows exactly where the enemy walk breaks if detection is still empty.
// ---------------------------------------------------------------------------
void styx_game_diag(void) {
    static bool done = false;
    if (done) return;
    done = true;

    void *lp = styx_game_localpawn();
    void *mg = styx_game_matchgame();
    styx_log("[diag] localpawn=%p matchgame=%p", lp, mg);
    if (!styx_ptr_ok((uintptr_t)mg)) { styx_log("[diag] matchgame invalid -> stop"); return; }

    void *list = *(void **)((uintptr_t)mg + BaseGame_EnemyPawns);
    styx_log("[diag] EnemyPawns[+0x%X]=%p", BaseGame_EnemyPawns, list);
    if (!styx_ptr_ok((uintptr_t)list)) { styx_log("[diag] list invalid -> stop"); return; }

    void   *items = *(void **)((uintptr_t)list + IL2CPP_LIST_ITEMS);
    int32_t size  = *(int32_t *)((uintptr_t)list + IL2CPP_LIST_SIZE);
    styx_log("[diag] _items=%p _size=%d", items, size);
    if (!styx_ptr_ok((uintptr_t)items) || size <= 0) { styx_log("[diag] items/size invalid -> stop"); return; }

    int shown = 0;
    const uintptr_t data = (uintptr_t)items + IL2CPP_ARRAY_DATA;
    for (int32_t i = 0; i < size && shown < 4; i++) {
        uintptr_t pawn = *(uintptr_t *)(data + (uintptr_t)i * sizeof(void *));
        if (!styx_ptr_ok(pawn)) { styx_log("[diag]   [%d] bad ptr %p", i, (void *)pawn); continue; }
        styx_v3 loc = *(styx_v3 *)(pawn + Pawn_m_Location);
        styx_log("[diag]   [%d] pawn=%p alive=%d loc=(%.1f,%.1f,%.1f) finite=%d",
                 i, (void *)pawn, styx_game_pawn_alive((void *)pawn) ? 1 : 0,
                 loc.x, loc.y, loc.z, styx_v3_finite(loc) ? 1 : 0);
        shown++;
    }
}
