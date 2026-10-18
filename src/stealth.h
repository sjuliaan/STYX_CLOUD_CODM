#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Install the ACE detection bypass (v3, rival parity).
// Globally rebinds (fishhook) the dyld/mach/libc/socket/Security symbols the
// anti-cheat uses, neutralises the AnoSDK command channel (AnoSDKIoctl), hides
// our own image from dyld enumeration, spoofs code-sign/entitlement checks, and
// rewrites anti-cheat network packets. Every call is recorded to
// Documents/styx_ace.log; `[rebind] originals resolved: N / M` confirms coverage.
void styx_stealth_start(void);

#ifdef __cplusplus
}
#endif
