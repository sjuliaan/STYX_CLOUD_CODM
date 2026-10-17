#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Install SIGSEGV/SIGBUS/SIGILL/SIGABRT handlers on an alternate signal stack
// that append fault address / PC / LR / FAR to Documents/styx_crash.log, then
// re-raise so the OS still records the crash. Diagnostic only.
void styx_crashguard_install(void);

#ifdef __cplusplus
}
#endif
