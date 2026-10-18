#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Reset the guest account on iOS.
//
// The Android mod just unlinks the MSDK guest fallback prefs file and calls
// exit(0). On iOS the guest id/token survive even a reinstall because MSDKPIXCore
// persists them in the *Keychain* (plus a dedicated NSUserDefaults suite and an
// itop_login.txt file). So we scrub all three, then exit(0) — the game
// regenerates a fresh, unbanned guest on the next launch.
//
// Must be called on a thread that may call exit(); it does not return.
void styx_reset_guest_account(void);

#ifdef __cplusplus
}
#endif
