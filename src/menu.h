#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// True while the toggle panel is open.
bool styx_menu_visible(void);

// Whether a touch at (x,y) in view points belongs to the menu (panel open, or
// inside the floating icon). Used by the overlay window's hit-test to decide
// whether to swallow the touch or pass it through to the game.
bool styx_menu_point_interactive(float x, float y);

// Floating-icon gesture handling (only used while the panel is closed).
void styx_menu_touch_begin(float x, float y);
void styx_menu_touch_move(float x, float y);
void styx_menu_touch_end(float x, float y);

// View size in points, tracked so the panel/icon stay on screen.
void styx_menu_set_view_size(float w, float h);

// Floating-icon top-left in view points (for positioning the icon window).
void styx_menu_icon_origin(float *x, float *y);
// Icon edge length in points.
float styx_menu_icon_size(void);

// Draw the floating icon (always) and the toggle panel (when open).
// Must be called between ImGui::NewFrame() and ImGui::Render().
void styx_menu_draw(void);

// Apply the STYX dark style to ImGui.
void styx_menu_apply_style(void);

#ifdef __cplusplus
}
#endif
