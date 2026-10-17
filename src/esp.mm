#include "esp.h"
#include "config.h"
#include "game.h"
#include "offsets.h"
#include "styxlog.h"

#include "imgui.h"

#include <stdint.h>
#include <string.h>

// ---------------------------------------------------------------------------
// ESP: read enemy world positions once per frame, project to screen, and draw
// with ImGui's background draw list. Collection and drawing are separate so the
// draw pass never touches game memory.
//
// Coordinate spaces: Unity's WorldToScreenPoint yields render pixels with the
// origin at the BOTTOM-left. ImGui (our overlay) works in view points with the
// origin at the TOP-left. We normalise through the Unity screen size so this is
// correct regardless of the device scale factor.
// ---------------------------------------------------------------------------

#define STYX_ESP_MAX 64

typedef struct {
    bool  valid;
    float hx, hy;   // head (points)
    float bx, by;   // body/feet (points)
    float health01; // 0..1, -1 if unknown
} styx_esp_box;

static styx_esp_box g_boxes[STYX_ESP_MAX];
static int         g_count = 0;
static int         g_logged_frames = 0;

int styx_esp_enemy_count(void) { return g_count; }

// Read a 0..1 health fraction defensively; returns -1 when unavailable.
static float styx_esp_health(void *pawn) {
    // Pawn derives from AttackableTarget: m_AttackableInfo @ +0x78,
    // m_Health @ +0x34, m_MaxHealth @ +0x38. Guard the pointer before
    // dereferencing so a wrong offset skips instead of faulting.
    uintptr_t info = *(uintptr_t *)((uintptr_t)pawn + AttackableTarget_m_AttackableInfo);
    if (info < 0x100000000ULL || info >= 0x800000000000ULL || (info & 7) != 0) return -1.0f;
    float hp  = *(float *)(info + AttackableTarget_m_Health);
    float max = *(float *)(info + AttackableTarget_m_MaxHealth);
    if (!(max > 0.0f) || max > 1.0e7f) return -1.0f;
    if (!(hp >= 0.0f)) return -1.0f;
    float f = hp / max;
    if (f < 0.0f) f = 0.0f;
    if (f > 1.0f) f = 1.0f;
    return f;
}

void styx_esp_collect(float view_w, float view_h) {
    g_count = 0;

    bool want_box    = styx_feat(STYX_FEAT_ESP);
    bool want_lines  = styx_feat(STYX_FEAT_ESP_LINES);
    bool want_health = styx_feat(STYX_FEAT_ESP_HEALTH);
    if (!want_box && !want_lines) return;
    if (view_w <= 1.0f || view_h <= 1.0f) return;

    int sw = 0, sh = 0;
    styx_game_screen_size(&sw, &sh);
    if (sw <= 0 || sh <= 0) return;

    void *pawns[STYX_ESP_MAX];
    size_t n = styx_game_enemy_pawns(pawns, STYX_ESP_MAX);

    for (size_t i = 0; i < n && g_count < STYX_ESP_MAX; i++) {
        void *p = pawns[i];
        if (!styx_game_pawn_alive(p)) continue;

        styx_v3 head, body;
        bool haveHead = styx_game_pawn_head(p, &head);
        bool haveBody = styx_game_pawn_position(p, &body);
        if (!haveHead && !haveBody) continue;

        styx_v3 hsp, bsp;
        bool okH = haveHead && styx_game_world_to_screen(head, &hsp.x, &hsp.y, &hsp.z);
        bool okB = haveBody && styx_game_world_to_screen(body, &bsp.x, &bsp.y, &bsp.z);
        if (!okH && !okB) continue;
        // Skip projections behind the camera (Unity returns negative z or mirrors).
        if (hsp.z <= 0.0f && bsp.z <= 0.0f) continue;

        styx_esp_box *b = &g_boxes[g_count];
        b->hx = hsp.x / (float)sw * view_w;
        b->hy = (1.0f - hsp.y / (float)sh) * view_h;
        b->bx = bsp.x / (float)sw * view_w;
        b->by = (1.0f - bsp.y / (float)sh) * view_h;
        b->health01 = want_health ? styx_esp_health(p) : -1.0f;
        b->valid = true;
        g_count++;
    }

    if (g_logged_frames < 5) {
        styx_log("[esp] frame %d: enemies=%zu boxes=%d (screen %dx%d)",
                 g_logged_frames, n, g_count, sw, sh);
        if (g_count > 0)
            styx_log("[esp]   box0 head=(%.1f,%.1f) body=(%.1f,%.1f) hp=%.2f",
                     g_boxes[0].hx, g_boxes[0].hy, g_boxes[0].bx, g_boxes[0].by, g_boxes[0].health01);
        g_logged_frames++;
    }
}

void styx_esp_draw(void) {
    if (g_count <= 0) return;

    bool want_box    = styx_feat(STYX_FEAT_ESP);
    bool want_lines  = styx_feat(STYX_FEAT_ESP_LINES);
    bool want_health = styx_feat(STYX_FEAT_ESP_HEALTH);
    if (!want_box && !want_lines) return;

    ImDrawList *dl = ImGui::GetBackgroundDrawList();
    ImVec2 view = ImGui::GetIO().DisplaySize;

    const ImU32 col_box = IM_COL32(0, 255, 64, 220);
    const ImU32 col_out = IM_COL32(0, 0, 0, 160);
    const ImU32 col_line = IM_COL32(255, 255, 255, 120);

    for (int i = 0; i < g_count; i++) {
        styx_esp_box *b = &g_boxes[i];
        if (!b->valid) continue;

        float top = b->hy < b->by ? b->hy : b->by;
        float bot = b->hy < b->by ? b->by : b->hy;
        float h   = bot - top;
        if (h < 4.0f) h = 4.0f;
        float w   = h * 0.5f;
        if (w < 6.0f) w = 6.0f;

        if (want_lines) {
            dl->AddLine(ImVec2(view.x * 0.5f, view.y), ImVec2(b->bx, b->by), col_line, 1.5f);
        }
        if (want_box) {
            ImVec2 a(b->bx - w * 0.5f, top);
            ImVec2 c(b->bx + w * 0.5f, bot);
            dl->AddRect(ImVec2(a.x - 1, a.y - 1), ImVec2(c.x + 1, c.y + 1), col_out, 0.0f, 0, 3.0f);
            dl->AddRect(a, c, col_box, 0.0f, 0, 1.5f);
        }
        if (want_health && b->health01 >= 0.0f) {
            float bx0 = b->bx - w * 0.5f;
            float bw  = w;
            float bh  = 3.0f;
            float by0 = bot + 2.0f;
            dl->AddRectFilled(ImVec2(bx0, by0), ImVec2(bx0 + bw, by0 + bh), IM_COL32(0, 0, 0, 180));
            dl->AddRectFilled(ImVec2(bx0, by0), ImVec2(bx0 + bw * b->health01, by0 + bh), IM_COL32(255, 40, 40, 230));
        }
    }
}
