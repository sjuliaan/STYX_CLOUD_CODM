#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Install the log-only ACE detection probe.
// Rebinds the libc/mach/dyld imports of the COD Mobile anti-cheat frameworks
// (anogs, kgvmp_dy, enq_transceiver_dy, TDataMaster, CrashSight) to logging
// shims. Nothing is hidden in this build: every shim forwards to the real
// function after recording the call to Documents/styx_ace.log.
void styx_stealth_start(void);

#ifdef __cplusplus
}
#endif
