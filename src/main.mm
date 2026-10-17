#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

#include "base.h"
#include "mem.h"
#include "offsets.h"
#include "stealth.h"
#include "styxlog.h"

// A self-contained function used to validate the no-JIT patch layer without
// touching game code (safe no-op: we write the same bytes back).
static int __attribute__((noinline)) styx_selftest_target(void) {
    return 0x5A5A;
}

__attribute__((constructor))
static void styx_init(void) {
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

        // Validate the vm_remap write path on our own code (no-op write).
        uint32_t cur = 0;
        if (styx_mem_read((const void *)&styx_selftest_target, &cur, sizeof(cur))) {
            bool ok = styx_mem_write((void *)&styx_selftest_target, &cur, sizeof(cur));
            styx_log("mem_write self-test: %s (val 0x%08x)", ok ? "OK" : "FAIL", cur);
        } else {
            styx_log("mem_read self-test FAILED");
        }

        styx_log("loader ready (feature build pending)");
        styx_log("================================================");

        // Install the log-only anti-cheat detection probe.
        styx_stealth_start();
    }
}
