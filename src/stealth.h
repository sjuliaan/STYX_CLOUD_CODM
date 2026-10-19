#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Install the ACE detection bypass (v4, full rival parity).
// Globally rebinds (fishhook) the dyld/mach/libc/socket/Security symbols the
// anti-cheat uses, neutralises the AnoSDK command channel (AnoSDKIoctl), hides
// our own image from dyld enumeration, spoofs code-sign/entitlement checks,
// rewrites anti-cheat network packets, and neutralises the anogs ACE detector
// suite outright by forcing its evaluation memo to "clean"
// (byte_2ADD90=1 / qword_2ADD98=0 -- data-only, arm64e W^X safe). Every call is
// recorded to Documents/GPMGameCore.probe; `[rebind] originals resolved: N / M`
// confirms coverage.
void styx_stealth_start(void);

#ifdef __cplusplus
}
#endif
