#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Collect enemy screen positions for this frame. `view_w`/`view_h` are the
// overlay size in points (ImGui coordinate space). Main thread only.
void styx_esp_collect(float view_w, float view_h);

// Draw the collected boxes/health/lines with ImGui. Must be called between
// ImGui::NewFrame() and ImGui::Render().
void styx_esp_draw(void);

// Number of enemies collected on the last frame (diagnostics).
int styx_esp_enemy_count(void);

#ifdef __cplusplus
}
#endif
