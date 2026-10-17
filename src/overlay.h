#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Create the Metal + ImGui overlay (window, MTKView, command queue, ImGui
// context) once UIKit is up. Safe to call from any thread; it hops to main and
// retries until a key window exists.
void styx_overlay_start(void);

#ifdef __cplusplus
}
#endif
