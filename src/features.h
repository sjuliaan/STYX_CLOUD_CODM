#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Install the aim-assist / no-recoil / no-spread method hooks.
// Uses styx_method_hook (data-pointer redirection) on the RVAs in offsets.h.
// Each hook is installed once and reads its config flag on every call, so the
// menu toggles take effect immediately (default: off).
void styx_aim_install(void);

// Hook FrontEndUIScene.DoSomeThingOnUISceneInited so that, when the
// STYX_FEAT_SKIP_TUT flag is on, we also call the game's own
// MarkTutorialFinishedFromAppLauncher() for the same scene after the original
// runs. Takes effect on the next FrontEndUIScene init.
void styx_skip_tutorial_install(void);

#ifdef __cplusplus
}
#endif
