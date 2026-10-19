// gotrebind.cpp — chained-fixup-safe import rebinding (see gotrebind.h).
//
// Rationale: some embedded images (codm, APMDeviceInfoSupport, CrashSight,
// GPM_dylib) are linked with LC_DYLD_CHAINED_FIXUPS while others (anogs,
// MSDKPIXCore) are old-style LC_DYLD_INFO. For chained images dyld resolves
// every bind location at load and overwrites the encoded chain word with the
// real target address, so the ordinal/name mapping is gone by the time we run;
// classic fishhook (which walks LC_DYLD_INFO indirect symbol tables) therefore
// silently misses them. Instead we walk each image's pointer sections and use
// dladdr() on the *resolved* value to recover the symbol name, then overwrite
// the slot with our shim. Classic images are handled by fishhook first, and
// their already-shimmed slots are skipped here (idempotent).
//
// We deliberately skip /usr/lib and /System images: those live in the shared
// cache and must not be patched.

#include "gotrebind.h"

#include "../third_party/fishhook/fishhook.h"

#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

typedef struct mach_header_64          mh64_t;
typedef struct segment_command_64      seg64_t;
typedef struct section_64              sect64_t;

typedef int (*dladdr_fn)(const void *, Dl_info *);

static int styx_name_matches(const char *sym, const char *want) {
    if (sym == NULL || want == NULL) return 0;
    if (strcmp(sym, want) == 0) return 1;
    // dladdr() and the chained-fixup pools are inconsistent about the Mach-O
    // leading underscore, so accept either spelling.
    if (sym[0] == '_' && strcmp(sym + 1, want) == 0) return 1;
    if (want[0] == '_' && strcmp(sym, want + 1) == 0) return 1;
    return 0;
}

static int styx_section_is_auth(const sect64_t *sc) {
    // Auth pointer sections (__auth_got / __auth_ptr) only exist on arm64e.
    // In an arm64 process they are absent, but skip defensively: a plain
    // replacement in an authenticated slot would fail on the caller's braa.
    if (strncmp(sc->segname, "__AUTH", 6) == 0) return 1;
    if (strncmp(sc->sectname, "__auth", 6) == 0) return 1;
    return 0;
}

static void styx_make_writable(uintptr_t addr, size_t size) {
    uintptr_t pg = (uintptr_t)getpagesize();
    if (pg == 0) return;
    uintptr_t start = addr & ~(pg - 1);
    size_t len = (size_t)(addr - start) + size;
    len = (len + pg - 1) & ~(pg - 1);
    (void)vm_protect(mach_task_self(), (vm_address_t)start, (vm_size_t)len, 0,
                     VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
}

int styx_rebind_got_scan(struct rebinding rebindings[], size_t n) {
    if (rebindings == NULL || n == 0) return 0;

    // Look the real dladdr up before anything is hooked. dlsym() reads the
    // symbol table, not any __got slot, so it is unaffected by our rebinds.
    dladdr_fn real_dladdr = (dladdr_fn)dlsym(RTLD_DEFAULT, "dladdr");
    if (real_dladdr == NULL) return 0;

    int patched = 0;
    uint32_t count = _dyld_image_count();

    for (uint32_t i = 0; i < count; ++i) {
        const char *path = _dyld_get_image_name(i);
        if (path == NULL) continue;
        if (strncmp(path, "/usr/lib/", 9) == 0) continue;   // shared cache
        if (strncmp(path, "/System/", 8) == 0) continue;    // shared cache

        const mh64_t *mh = (const mh64_t *)_dyld_get_image_header(i);
        if (mh == NULL || mh->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *p = (const uint8_t *)mh + sizeof(mh64_t);

        for (uint32_t c = 0; c < mh->ncmds; ++c) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmdsize == 0) break;

            if (lc->cmd == LC_SEGMENT_64) {
                const seg64_t *seg = (const seg64_t *)p;
                const sect64_t *sects = (const sect64_t *)(p + sizeof(seg64_t));

                for (uint32_t s = 0; s < seg->nsects; ++s) {
                    const sect64_t *sc = &sects[s];
                    uint32_t type = sc->flags & SECTION_TYPE;
                    if (type != S_NON_LAZY_SYMBOL_POINTERS &&
                        type != S_LAZY_SYMBOL_POINTERS)
                        continue;
                    if (sc->size == 0 || styx_section_is_auth(sc)) continue;

                    uintptr_t addr = (uintptr_t)slide + (uintptr_t)sc->addr;
                    size_t nslots = (size_t)(sc->size / sizeof(void *));
                    void **slots = (void **)addr;

                    for (size_t k = 0; k < nslots; ++k) {
                        void *cur = slots[k];
                        if (cur == NULL) continue;

                        Dl_info di;
                        memset(&di, 0, sizeof(di));
                        if (real_dladdr(cur, &di) == 0 || di.dli_sname == NULL)
                            continue;

                        for (size_t j = 0; j < n; ++j) {
                            if (!styx_name_matches(di.dli_sname, rebindings[j].name))
                                continue;
                            if (cur == rebindings[j].replacement) break;  // done
                            if (rebindings[j].replacement == NULL) break;

                            styx_make_writable(addr, (size_t)sc->size);
                            if (rebindings[j].replaced != NULL)
                                *(rebindings[j].replaced) = cur;
                            slots[k] = rebindings[j].replacement;
                            ++patched;
                            break;
                        }
                    }
                }
            }

            p += lc->cmdsize;
        }
    }

    return patched;
}
