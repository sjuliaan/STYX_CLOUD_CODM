#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// UnityEngine.Vector3_o (il2cpp) is exactly { float x, y, z; }. Declaring the
// matching C struct everywhere lets the compiler apply the correct arm64 ABI
// (HFA of 3 floats) for both arguments and returns — never hand-roll this.
typedef struct { float x, y, z; } styx_v3;

// Typed wrappers around the RVAs in offsets.h. All return NULL/false when the
// game is not in a state that provides the object (e.g. not in a match). These
// MUST be called on the main thread (Unity's main thread).
void *styx_game_matchgame(void);   // MatchGame* (derives from BaseGame) or NULL
void *styx_game_localpawn(void);   // local Pawn* or NULL
void *styx_game_camera(void);      // main Camera* or NULL

// Fills `out` with up to `max` enemy Pawn* read directly from the MatchGame's
// BaseGame.EnemyPawns list (+0x178) — the same access the proven Android mod and
// the rival dylib use. Returns the number written (0 when not in a match).
size_t styx_game_enemy_pawns(void **out, size_t max);

bool styx_game_pawn_alive(void *pawn);
bool styx_game_pawn_position(void *pawn, styx_v3 *out);   // body bone (m_Mesh, calls get_position)
bool styx_game_pawn_location(void *pawn, styx_v3 *out);   // plain m_Location field, no call
bool styx_game_pawn_head(void *pawn, styx_v3 *out);       // head bone (m_HeadBone)

// True when every component is finite (rejects NaN/Inf from a bad read).
bool styx_v3_finite(styx_v3 v);

// One-shot diagnostics: logs matchgame / enemy list / first few pawns once.
void styx_game_diag(void);

// Camera.WorldToScreenPoint. Returns false when there is no camera.
// sx/sy/sz are in Unity render pixels (origin bottom-left, sz = view depth).
bool styx_game_world_to_screen(styx_v3 world, float *sx, float *sy, float *sz);

// UnityEngine.Screen size in render pixels.
void styx_game_screen_size(int *w, int *h);

// Call the game's own guest-account reset (MSDKLogin.ResetGuest()). Main thread.
void styx_game_reset_guest(void);

// Skip the guest tutorial by writing TutorialManager's static flags directly
// (data-only: SkipTutorialFromAppLauncher=1, m_TutorialEnable/m_PrologueEnable/
// m_TutorialFinalEnable/m_BRTutorialEnable=0). Forces TutorialManager's class init
// first so its class-pointer global is populated. Returns true once the write
// landed (false while the class is not initialised yet — call again to retry).
// Main thread only (calls an il2cpp method).
bool styx_game_skip_tutorial(void);

#ifdef __cplusplus
}
#endif
