#include "menu.h"
#include "config.h"
#include "esp.h"
#include "game.h"
#include "guest.h"
#include "styxlog.h"

#include "imgui.h"

#import <Foundation/Foundation.h>

#include <math.h>

// ---------------------------------------------------------------------------
// Floating draggable icon + toggle panel, both ImGui. Touch input is fed by the
// overlay; here we only interpret it for the icon (tap = open, drag = move).
// ---------------------------------------------------------------------------

#define STYX_ICON_SIZE 52.0f

static bool  g_open = false;
static float g_iconX = 12.0f;
static float g_iconY = 120.0f;
static float g_viewW = 390.0f;
static float g_viewH = 844.0f;

// Icon gesture state.
static bool  g_dragging = false;
static bool  g_tapCandidate = false;
static float g_dragStartX = 0.0f, g_dragStartY = 0.0f;
static float g_iconStartX = 0.0f, g_iconStartY = 0.0f;
static int   g_pendingResetGuest = 0;

bool styx_menu_visible(void) { return g_open; }

void styx_menu_icon_origin(float *x, float *y) {
    if (x) *x = g_iconX;
    if (y) *y = g_iconY;
}

float styx_menu_icon_size(void) { return STYX_ICON_SIZE; }

void styx_menu_set_view_size(float w, float h) {
    if (w > 1.0f) g_viewW = w;
    if (h > 1.0f) g_viewH = h;
    // Keep the icon on-screen after rotation/resize.
    if (g_iconX > g_viewW - STYX_ICON_SIZE) g_iconX = g_viewW - STYX_ICON_SIZE;
    if (g_iconY > g_viewH - STYX_ICON_SIZE) g_iconY = g_viewH - STYX_ICON_SIZE;
    if (g_iconX < 0.0f) g_iconX = 0.0f;
    if (g_iconY < 0.0f) g_iconY = 0.0f;
}

static bool icon_contains(float x, float y) {
    return x >= g_iconX && x <= g_iconX + STYX_ICON_SIZE &&
           y >= g_iconY && y <= g_iconY + STYX_ICON_SIZE;
}

bool styx_menu_point_interactive(float x, float y) {
    if (g_open) return true;
    return icon_contains(x, y);
}

void styx_menu_touch_begin(float x, float y) {
    if (g_open) return;
    if (!icon_contains(x, y)) return;
    g_dragging = true;
    g_tapCandidate = true;
    g_dragStartX = x;
    g_dragStartY = y;
    g_iconStartX = g_iconX;
    g_iconStartY = g_iconY;
}

void styx_menu_touch_move(float x, float y) {
    if (!g_dragging) return;
    float dx = x - g_dragStartX;
    float dy = y - g_dragStartY;
    if (fabsf(dx) > 6.0f || fabsf(dy) > 6.0f) g_tapCandidate = false;
    g_iconX = g_iconStartX + dx;
    g_iconY = g_iconStartY + dy;
    if (g_iconX < 0.0f) g_iconX = 0.0f;
    if (g_iconY < 0.0f) g_iconY = 0.0f;
    if (g_iconX > g_viewW - STYX_ICON_SIZE) g_iconX = g_viewW - STYX_ICON_SIZE;
    if (g_iconY > g_viewH - STYX_ICON_SIZE) g_iconY = g_viewH - STYX_ICON_SIZE;
}

void styx_menu_touch_end(float x, float y) {
    if (!g_dragging) return;
    g_dragging = false;
    if (g_tapCandidate) {
        g_open = true;
        styx_log("[menu] opened");
    }
    g_tapCandidate = false;
}

void styx_menu_apply_style(void) {
    ImGuiStyle &s = ImGui::GetStyle();
    s.WindowRounding = 8.0f;
    s.FrameRounding = 5.0f;
    s.GrabRounding = 5.0f;
    s.WindowBorderSize = 1.0f;
    s.FramePadding = ImVec2(8, 6);
    s.ItemSpacing = ImVec2(6, 8);
    ImVec4 *c = s.Colors;
    c[ImGuiCol_WindowBg]       = ImVec4(0.06f, 0.07f, 0.09f, 0.94f);
    c[ImGuiCol_Border]         = ImVec4(0.20f, 0.85f, 0.40f, 0.60f);
    c[ImGuiCol_FrameBg]        = ImVec4(0.16f, 0.18f, 0.22f, 1.00f);
    c[ImGuiCol_FrameBgHovered] = ImVec4(0.22f, 0.26f, 0.32f, 1.00f);
    c[ImGuiCol_CheckMark]      = ImVec4(0.25f, 1.00f, 0.45f, 1.00f);
    c[ImGuiCol_Button]         = ImVec4(0.16f, 0.18f, 0.22f, 1.00f);
    c[ImGuiCol_ButtonHovered]  = ImVec4(0.25f, 0.55f, 0.35f, 1.00f);
    c[ImGuiCol_ButtonActive]   = ImVec4(0.25f, 0.80f, 0.45f, 1.00f);
    c[ImGuiCol_Header]         = ImVec4(0.20f, 0.45f, 0.30f, 1.00f);
}

static void draw_icon(void) {
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    ImVec2 a(g_iconX, g_iconY);
    ImVec2 b(g_iconX + STYX_ICON_SIZE, g_iconY + STYX_ICON_SIZE);
    ImU32 fill = g_open ? IM_COL32(30, 90, 50, 235) : IM_COL32(20, 22, 28, 215);
    ImU32 edge = IM_COL32(60, 220, 110, 230);
    dl->AddRectFilled(a, b, fill, 10.0f);
    dl->AddRect(a, b, edge, 10.0f, 0, 2.0f);
    const char *t = "STYX";
    ImVec2 ts = ImGui::CalcTextSize(t);
    dl->AddText(ImVec2(g_iconX + (STYX_ICON_SIZE - ts.x) * 0.5f,
                       g_iconY + (STYX_ICON_SIZE - ts.y) * 0.5f),
                IM_COL32(235, 255, 240, 255), t);
}

static void draw_panel(void) {
    ImGui::SetNextWindowSizeConstraints(ImVec2(300, 0), ImVec2(300, 4000));
    ImGui::SetNextWindowPos(ImVec2(g_viewW * 0.5f - 150.0f, 80.0f), ImGuiCond_Always);
    ImGuiWindowFlags fl = ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoCollapse |
                          ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_AlwaysAutoResize;

    if (ImGui::Begin("STYX", &g_open, fl)) {
        ImGui::TextColored(ImVec4(0.3f, 1.0f, 0.5f, 1.0f), "CODM 1.6.58  |  enemies: %d", styx_esp_enemy_count());
        ImGui::Separator();

        if (ImGui::CollapsingHeader("Combat", ImGuiTreeNodeFlags_DefaultOpen)) {
            static const styx_feature combat[] = { STYX_FEAT_ASSIST, STYX_FEAT_RECOIL, STYX_FEAT_SPREAD };
            for (size_t i = 0; i < sizeof(combat) / sizeof(combat[0]); i++) {
                bool v = styx_feat(combat[i]);
                if (ImGui::Checkbox(styx_feat_label(combat[i]), &v)) {
                    styx_feat_set(combat[i], v);
                    styx_cfg_save();
                }
            }
            if (styx_feat(STYX_FEAT_ASSIST)) {
                ImGui::Indent();
                float s = styx_assist_strength();
                ImGui::SetNextItemWidth(160.0f);
                if (ImGui::SliderFloat("Strength", &s, 0.0f, 100.0f, "%.0f")) {
                    styx_assist_strength_set(s);
                }
                if (ImGui::IsItemDeactivatedAfterEdit()) styx_cfg_save();
                ImGui::Unindent();
            }
        }

        if (ImGui::CollapsingHeader("Visuals (ESP)", ImGuiTreeNodeFlags_DefaultOpen)) {
            static const styx_feature esp_f[] = { STYX_FEAT_ESP, STYX_FEAT_ESP_HEALTH, STYX_FEAT_ESP_LINES };
            for (size_t i = 0; i < sizeof(esp_f) / sizeof(esp_f[0]); i++) {
                bool v = styx_feat(esp_f[i]);
                if (ImGui::Checkbox(styx_feat_label(esp_f[i]), &v)) {
                    styx_feat_set(esp_f[i], v);
                    styx_cfg_save();
                }
            }
        }

        if (ImGui::CollapsingHeader("Account", ImGuiTreeNodeFlags_DefaultOpen)) {
            bool v = styx_feat(STYX_FEAT_SKIP_TUT);
            if (ImGui::Checkbox(styx_feat_label(STYX_FEAT_SKIP_TUT), &v)) {
                styx_feat_set(STYX_FEAT_SKIP_TUT, v);
                styx_cfg_save();
            }
            ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.55f, 0.15f, 0.15f, 1.0f));
            if (ImGui::Button("Reset Guest Account", ImVec2(-1, 0))) {
                g_pendingResetGuest = 1;
            }
            ImGui::PopStyleColor();
            ImGui::TextDisabled("creates a fresh guest account");
        }

        ImGui::Separator();
        if (ImGui::Button("Close", ImVec2(-1, 0))) g_open = false;
    }
    ImGui::End();
}

void styx_menu_draw(void) {
    draw_icon();
    if (g_open) draw_panel();

    // Deferred (avoid calling into the game mid-ImGui-frame).
    if (g_pendingResetGuest) {
        g_pendingResetGuest = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Best-effort native reset first, then scrub the persisted MSDK
            // state (Keychain + defaults + itop_login.txt) and force-quit so
            // the next launch creates a fresh guest. Never returns.
            styx_game_reset_guest();
            styx_reset_guest_account();
        });
    }
}
