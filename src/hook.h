#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// il2cpp method-pointer redirection (jailbreak-free, code-signing-safe).
//
// IL2CPP resolves every managed method through a table of code pointers that
// lives in the game's writable data segments (__DATA_CONST / __DATA) — the
// CodeRegistration tables. Redirecting a slot there behaves exactly like an
// inline hook, without ever touching a signed executable page.
//
// `rva` is the method's code RVA relative to the main image (0x100000000),
// e.g. STYX_RVA_GamePlay_get_MatchGame.

// Count, and optionally return, every 8-byte aligned slot in the main image's
// __DATA_CONST/__DATA that currently holds (main_base + rva).
size_t styx_method_find_slots(uintptr_t rva, uintptr_t *out, size_t max);

// Redirect every slot equal to (main_base + rva) to point at `hook_fn`.
// Returns the number of slots patched. If `orig_out` is non-NULL it receives
// the original pointer value (0 if none found).
size_t styx_method_hook(uintptr_t rva, void *hook_fn, uintptr_t *orig_out);

// Restore the slots previously redirected by styx_method_hook for `rva`.
size_t styx_method_unhook(uintptr_t rva, uintptr_t orig);

#ifdef __cplusplus
}
#endif
