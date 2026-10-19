#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rebinding;

// Chained-fixup-safe import rebinding.
//
// fishhook only understands the classic LC_DYLD_INFO indirect-symbol tables, so
// on modern (LC_DYLD_CHAINED_FIXUPS) images it silently misses most imports.
// At runtime dyld has already resolved every bind slot to the real address, and
// the encoded chain (ordinal/next) is overwritten -- so we instead enumerate
// the pointer sections (__got / __la_symbol_ptr / __nl_symbol_ptr) of each
// non-shared-cache image and identify each resolved pointer via dladdr().
//
// Returns the number of slots patched on this pass. Idempotent: slots that
// already hold the replacement are skipped.
int styx_rebind_got_scan(struct rebinding rebindings[], size_t n);

#ifdef __cplusplus
}
#endif
