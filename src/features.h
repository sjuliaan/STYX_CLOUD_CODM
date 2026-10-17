#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Install the aim-assist / no-recoil / no-spread method hooks.
// Uses styx_method_hook (data-pointer redirection) on the RVAs in offsets.h.
void styx_aim_install(void);

#ifdef __cplusplus
}
#endif
