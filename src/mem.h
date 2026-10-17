#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Write `len` bytes at `address` even if the page is read-only executable.
// Uses the KittyMemory-style vm_copy -> RW map -> mprotect RX -> mach_vm_remap
// technique, which works on a jailed device without JIT.
bool styx_mem_write(void *address, const void *buffer, size_t len);

// Read `len` bytes from `address`.
bool styx_mem_read(const void *address, void *buffer, size_t len);

// Fill `len` bytes at `address` with `value`.
bool styx_mem_set(void *address, uint8_t value, size_t len);

// Install a branch (B) from `from` to `to` (arm64). Returns true on success.
bool styx_hook_branch(void *from, const void *to);

// Naive byte-pattern scan; mask chars: 'x' = match, '?' = wildcard.
uintptr_t styx_mem_scan(uintptr_t start, size_t size, const uint8_t *pattern, const char *mask);

#ifdef __cplusplus
}
#endif
