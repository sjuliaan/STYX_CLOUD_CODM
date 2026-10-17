#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// A resolved VM region (page-aligned) around some address.
typedef struct styx_region {
    uintptr_t start;    // region base (page aligned)
    size_t    size;     // region size in bytes
    uint32_t  prot;     // current protection (VM_PROT_*)
    uint32_t  maxprot;  // maximum protection (VM_PROT_*)
} styx_region;

// Query the VM region containing `addr`. Returns false if unresolvable.
bool styx_region_info(uintptr_t addr, styx_region *out);

// Write `len` bytes at `address`.
//
// Strategy (matches the technique used by the working jailbreak-free iOS mods):
//   - if the page is already writable: plain memcpy;
//   - otherwise vm_protect(page, READ|WRITE|COPY) so the kernel gives us a
//     private copy-on-write page, memcpy, then restore the original protection.
//   - EXECUTABLE pages: the COPY request can lower the page's max protection so
//     EXECUTE can no longer be restored; if we cannot prove we can put EXECUTE
//     back we REFUSE the patch (never leave a live code page non-executable,
//     which triggers a CODESIGNING "Invalid Page" SIGKILL on next fetch).
// Refuses to patch libstyx's own image.
bool styx_mem_write(void *address, const void *buffer, size_t len);

// Convenience for patching *data* slots (function pointers, il2cpp method
// pointer tables in __DATA/__DATA_CONST). Thin wrapper over styx_mem_write.
bool styx_mem_write_data(void *address, const void *buffer, size_t len);

// Read `len` bytes from `address`.
bool styx_mem_read(const void *address, void *buffer, size_t len);

// Fill `len` bytes at `address` with `value`.
bool styx_mem_set(void *address, uint8_t value, size_t len);

// Install a branch (B) from `from` to `to` (arm64). Returns true on success.
// NOTE: this inline-patches a __TEXT code page and is DISABLED by default
// (see mem.mm) because dirtying a signed executable page is SIGKILLed by AMFI.
bool styx_hook_branch(void *from, const void *to);

// Naive byte-pattern scan; mask chars: 'x' = match, '?' = wildcard.
uintptr_t styx_mem_scan(uintptr_t start, size_t size, const uint8_t *pattern, const char *mask);

// Zero-risk capability probe: maps a PRIVATE copy of the page of the running
// binary that contains `rva` and tests, on that copy, whether each known
// protection strategy can make it writable AND restore EXECUTE. Logs the
// kern_return codes and the resulting region prot/maxprot. Never touches the
// live, signed game code.
void styx_probe_patch_caps(uintptr_t rva);

#ifdef __cplusplus
}
#endif
