#include "hook.h"
#include "base.h"
#include "mem.h"
#include "styxlog.h"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>

// ---------------------------------------------------------------------------
// IL2CPP method-pointer redirection.
//
// The main image (codm) uses LC_DYLD_CHAINED_FIXUPS, so by the time our
// constructor runs dyld has already resolved every rebased pointer in
// __DATA_CONST/__DATA to its absolute runtime address. A managed method's code
// pointer therefore appears verbatim as (main_base + method_rva) in the il2cpp
// CodeRegistration pointer table (and sometimes in vtables). Redirecting those
// slots = an inline hook, entirely inside writable data.
// ---------------------------------------------------------------------------

#define STYX_MAX_SLOTS 256

static bool styx_is_data_seg(const struct segment_command_64 *s) {
    return strcmp(s->segname, "__DATA_CONST") == 0 ||
           strcmp(s->segname, "__DATA") == 0;
}

size_t styx_method_find_slots(uintptr_t rva, uintptr_t *out, size_t max) {
    const struct mach_header_64 *h =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    if (!h || h->magic != MH_MAGIC_64) return 0;

    const uintptr_t target = (uintptr_t)h + rva; // styx_addr(rva)
    size_t count = 0;

    uintptr_t p = (uintptr_t)h + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64) &&
            styx_is_data_seg((const struct segment_command_64 *)lc)) {
            const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
            uintptr_t start = (uintptr_t)(s->vmaddr + slide);
            uintptr_t end   = start + (uintptr_t)s->vmsize;
            for (uintptr_t q = start; q + sizeof(uintptr_t) <= end; q += sizeof(uintptr_t)) {
                uintptr_t v = 0;
                if (!styx_mem_read((const void *)q, &v, sizeof(v))) continue;
                if (v == target) {
                    if (out && count < max) out[count] = q;
                    count++;
                }
            }
        }
        p += lc->cmdsize;
    }
    return count;
}

size_t styx_method_hook(uintptr_t rva, void *hook_fn, uintptr_t *orig_out) {
    if (!hook_fn) return 0;
    uintptr_t slots[STYX_MAX_SLOTS];
    size_t found = styx_method_find_slots(rva, slots, STYX_MAX_SLOTS);
    if (found == 0) {
        styx_log("[hook] no data slot references rva 0x%lx", (unsigned long)rva);
        if (orig_out) *orig_out = 0;
        return 0;
    }

    const uintptr_t target = styx_main_base() + rva;
    uintptr_t first_orig = 0;
    bool got_orig = false;
    size_t patched = 0;

    for (size_t i = 0; i < found && i < STYX_MAX_SLOTS; i++) {
        uintptr_t cur = 0;
        if (!styx_mem_read((const void *)slots[i], &cur, sizeof(cur))) continue;
        if (!got_orig) { first_orig = cur; got_orig = true; }
        if (cur != target) continue;
        uintptr_t fn = (uintptr_t)hook_fn;
        if (styx_mem_write((void *)slots[i], &fn, sizeof(fn))) patched++;
    }

    if (orig_out) *orig_out = first_orig;
    styx_log("[hook] rva 0x%lx: %zu slot(s) found, %zu patched -> %p",
             (unsigned long)rva, found, patched, hook_fn);
    return patched;
}

size_t styx_method_unhook(uintptr_t rva, uintptr_t orig) {
    uintptr_t slots[STYX_MAX_SLOTS];
    size_t found = styx_method_find_slots(rva, slots, STYX_MAX_SLOTS);
    size_t restored = 0;
    for (size_t i = 0; i < found && i < STYX_MAX_SLOTS; i++) {
        uintptr_t cur = 0;
        if (!styx_mem_read((const void *)slots[i], &cur, sizeof(cur))) continue;
        if (cur != orig && styx_mem_write((void *)slots[i], &orig, sizeof(orig)))
            restored++;
    }
    styx_log("[hook] rva 0x%lx: %zu slot(s) restored", (unsigned long)rva, restored);
    return restored;
}
