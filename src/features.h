#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Install the aim-assist / no-recoil / no-spread method hooks.
// Uses styx_method_hook (data-pointer redirection) on the RVAs in offsets.h.
// Each hook is installed once and reads its config flag on every call, so the
// menu toggles take effect immediately (default: off).
void styx_aim_install(void);

// Skip guest tutorial is NOT installed as a hook: IsTutorialEnabled() has 48
// direct BL callers, so data-slot redirection cannot intercept it, and inline
// patching is impossible under our W^X constraint. Instead the overlay loop
// calls styx_game_skip_tutorial() (a data-only write of TutorialManager's static
// flags) while STYX_FEAT_SKIP_TUT is on. See game.h.

#ifdef __cplusplus
}
#endif
