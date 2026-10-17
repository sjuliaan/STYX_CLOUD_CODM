#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

#include "base.h"
#include "crashguard.h"
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

        // Arm the ACE detection probe before any code patching, so we still
        // get the probe log even if a later write faults.
        styx_stealth_start();

        // Capability test: no-op write of the same bytes to a GAME code page.
        // Confirms whether vm_protect(VM_PROT_COPY) is permitted on a signed
        // __TEXT page on this iOS build.
        if (styx_mem_read((const void *)matchGame, &insn, sizeof(insn))) {
            bool ok = styx_mem_write((void *)matchGame, &insn, sizeof(insn));
            styx_log("vm_protect write test: %s", ok ? "OK" : "FAIL");
        }

        styx_log("loader ready (feature build pending)");
        styx_log("================================================");
    }
}
