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

// Fills `out` with up to `max` alive enemy Pawn* (via BaseGame.GetEnemyPawns()).
// Returns the number written. Returns 0 when not in a match / no enemies.
size_t styx_game_enemy_pawns(void **out, size_t max);

bool styx_game_pawn_alive(void *pawn);
bool styx_game_pawn_position(void *pawn, styx_v3 *out);   // body bone (m_Mesh)
bool styx_game_pawn_head(void *pawn, styx_v3 *out);       // head bone (m_HeadBone)

// Camera.WorldToScreenPoint. Returns false when there is no camera.
// sx/sy/sz are in Unity render pixels (origin bottom-left, sz = view depth).
bool styx_game_world_to_screen(styx_v3 world, float *sx, float *sy, float *sz);

// UnityEngine.Screen size in render pixels.
void styx_game_screen_size(int *w, int *h);

// Call the game's own guest-account reset (MSDKLogin.ResetGuest()). Main thread.
void styx_game_reset_guest(void);

#ifdef __cplusplus
}
#endif
