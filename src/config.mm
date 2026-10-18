#include "config.h"
#include "styxlog.h"

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Feature-flag storage. Plain reads/writes via __atomic builtins so the render
// thread and the hook call sites never tear a read. Portable across ObjC++.
// ---------------------------------------------------------------------------

static volatile int g_feat[STYX_FEAT_COUNT];
static volatile int g_assist_strength = 50;        // 0..100 absolute aim speed
static char g_cfg_path[512];

static const char *k_keys[STYX_FEAT_COUNT] = {
    "assist", "recoil", "spread", "esp", "esp_health", "esp_lines", "skip_tut",
};
static const char *k_labels[STYX_FEAT_COUNT] = {
    "Aim Assist", "No Recoil", "No Spread", "ESP", "ESP Health", "ESP Lines", "Skip Tutorial",
};

const char *styx_feat_key(styx_feature f)   { return (f >= 0 && f < STYX_FEAT_COUNT) ? k_keys[f]   : "?"; }
const char *styx_feat_label(styx_feature f) { return (f >= 0 && f < STYX_FEAT_COUNT) ? k_labels[f] : "?"; }

bool styx_feat(styx_feature f) {
    if (f < 0 || f >= STYX_FEAT_COUNT) return false;
    return __atomic_load_n(&g_feat[f], __ATOMIC_RELAXED) != 0;
}

void styx_feat_set(styx_feature f, bool on) {
    if (f < 0 || f >= STYX_FEAT_COUNT) return;
    __atomic_store_n(&g_feat[f], on ? 1 : 0, __ATOMIC_RELAXED);
}

void styx_feat_toggle(styx_feature f) {
    if (f < 0 || f >= STYX_FEAT_COUNT) return;
    int cur = __atomic_load_n(&g_feat[f], __ATOMIC_RELAXED);
    __atomic_store_n(&g_feat[f], cur ? 0 : 1, __ATOMIC_RELAXED);
}

static int styx_clamp_strength(float v) {
    if (!(v > 0.0f)) v = 0.0f;      // also catches NaN
    if (v > 100.0f) v = 100.0f;
    return (int)(v + 0.5f);
}

float styx_assist_strength(void) {
    return (float)__atomic_load_n(&g_assist_strength, __ATOMIC_RELAXED);
}

void styx_assist_strength_set(float v) {
    __atomic_store_n(&g_assist_strength, styx_clamp_strength(v), __ATOMIC_RELAXED);
}

static void styx_cfg_path_build(void) {
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = paths.count ? paths[0] : NSTemporaryDirectory();
        NSString *path = [dir stringByAppendingPathComponent:@"styx.cfg"];
        strncpy(g_cfg_path, path.UTF8String, sizeof(g_cfg_path) - 1);
        g_cfg_path[sizeof(g_cfg_path) - 1] = 0;
    }
}

void styx_cfg_init(void) {
    // Defaults: everything off, aim strength 50.
    for (int i = 0; i < STYX_FEAT_COUNT; i++) __atomic_store_n(&g_feat[i], 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_assist_strength, 50, __ATOMIC_RELAXED);

    styx_cfg_path_build();

    FILE *fp = fopen(g_cfg_path, "r");
    if (!fp) {
        styx_log("[cfg] no config at %s (all features off)", g_cfg_path);
        return;
    }
    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char *key = line;
        int val = atoi(eq + 1);
        // trim trailing CR/LF/space on key
        size_t kl = strlen(key);
        while (kl && (key[kl - 1] == '\n' || key[kl - 1] == '\r' || key[kl - 1] == ' ')) key[--kl] = 0;
        if (strcmp(key, "assist_strength") == 0) {
            styx_assist_strength_set((float)val);
            continue;
        }
        for (int i = 0; i < STYX_FEAT_COUNT; i++) {
            if (strcmp(key, k_keys[i]) == 0) {
                __atomic_store_n(&g_feat[i], val ? 1 : 0, __ATOMIC_RELAXED);
                break;
            }
        }
    }
    fclose(fp);

    styx_log("[cfg] loaded from %s", g_cfg_path);
    for (int i = 0; i < STYX_FEAT_COUNT; i++)
        styx_log("[cfg]   %-12s = %d", k_keys[i], styx_feat((styx_feature)i) ? 1 : 0);
    styx_log("[cfg]   %-12s = %.0f", "assist_str", (double)styx_assist_strength());
}

void styx_cfg_save(void) {
    if (!g_cfg_path[0]) styx_cfg_path_build();
    FILE *fp = fopen(g_cfg_path, "w");
    if (!fp) { styx_log("[cfg] save FAILED (%s)", g_cfg_path); return; }
    for (int i = 0; i < STYX_FEAT_COUNT; i++)
        fprintf(fp, "%s=%d\n", k_keys[i], styx_feat((styx_feature)i) ? 1 : 0);
    fprintf(fp, "assist_strength=%d\n", (int)(styx_assist_strength() + 0.5f));    fclose(fp);
    styx_log("[cfg] saved to %s", g_cfg_path);
}
