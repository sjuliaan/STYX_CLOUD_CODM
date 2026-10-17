#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

#include "base.h"
#include "crashguard.h"
#include "features.h"
#include "hook.h"
#include "mem.h"
#include "offsets.h"
#include "stealth.h"
#include "styxlog.h"

__attribute__((constructor))
static void styx_init(void) {
    styx_crashguard_install();

    @autoreleasepool {
        uintptr_t base = styx_main_base();

        styx_log("================ STYX Cloud CODM ================");
        styx_log("main image : %s", styx_main_path());
        styx_log("base       : 0x%lx", (unsigned long)base);
        styx_log("slide      : 0x%lx", (unsigned long)styx_main_slide());

        uintptr_t matchGame = styx_addr(STYX_RVA_GamePlay_get_MatchGame);
        uintptr_t localPawn = styx_addr(STYX_RVA_GamePlay_get_LocalPawn);
        uintptr_t w2s       = styx_addr(STYX_RVA_Camera_WorldToScreenPoint);
        uintptr_t aim       = styx_addr(STYX_RVA_Pawn_GetAssitAimSpeed);

        styx_log("MatchGame  : 0x%lx", (unsigned long)matchGame);
        styx_log("LocalPawn  : 0x%lx", (unsigned long)localPawn);
        styx_log("W2S        : 0x%lx", (unsigned long)w2s);
        styx_log("AimSpeed   : 0x%lx", (unsigned long)aim);

        uint32_t insn = 0;
        if (styx_mem_read((const void *)matchGame, &insn, sizeof(insn)))
            styx_log("probe MatchGame[0] = 0x%08x", insn);
        else
            styx_log("probe MatchGame FAILED");

        // Arm the ACE detection probe/bypass before any patching.
        styx_stealth_start();

        // Discovery only (read-only): how many __DATA/__DATA_CONST slots
        // reference each hook target? This is the data-redirection hook engine.
        static const struct { const char *name; uintptr_t rva; } targets[] = {
            { "get_MatchGame",         STYX_RVA_GamePlay_get_MatchGame },
            { "get_LocalPawn",         STYX_RVA_GamePlay_get_LocalPawn },
            { "Camera_WorldToScreen",  STYX_RVA_Camera_WorldToScreenPoint },
            { "get_main",              STYX_RVA_Camera_get_main },
            { "GetAssitAimSpeed",      STYX_RVA_Pawn_GetAssitAimSpeed },
            { "GetScaleRecoil",        STYX_RVA_Pawn_GetScaleRecoil },
            { "GetRealSpreadModifier", STYX_RVA_Pawn_GetRealSpreadModifier },
        };
        for (size_t i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
            size_t n = styx_method_find_slots(targets[i].rva, NULL, 0);
            styx_log("slots[%-22s] rva=0x%-8lx count=%zu",
                     targets[i].name, (unsigned long)targets[i].rva, n);
        }

        // Install the aim feature hooks (data-pointer redirection).
        styx_aim_install();

        styx_log("loader ready (data-redirection build)");
        styx_log("================================================");
    }
}
