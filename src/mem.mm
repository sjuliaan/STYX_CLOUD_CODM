#include "mem.h"
#include "base.h"
#include "styxlog.h"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <libkern/OSCacheControl.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

// ---------------------------------------------------------------------------
// No-JIT memory patching (jailed iOS).
//
// We do NOT inline-patch the game's executable __TEXT pages. Confirmed on
// iOS 17.6.1: writing a signed code page (even via vm_protect(VM_PROT_COPY),
// which works for the write) leaves the page non-executable, and the next
// instruction fetch on it is a CODESIGNING "Invalid Page" SIGKILL.
//
// The working technique used by shipping jailbreak-free mods is DATA-only:
//   * rebind symbol/pointer slots in __DATA / __DATA_CONST (fishhook-style), and
//   * redirect il2cpp method pointers in __DATA_CONST (see hook.mm),
// both via a plain writable-region write or vm_protect(VM_PROT_COPY).
//
// mem_write therefore treats executable pages defensively: it verifies it can
// restore EXECUTE *before* dirtying anything, and refuses otherwise.
// ---------------------------------------------------------------------------

static inline size_t styx_page_size(void) { return (size_t)getpagesize(); }

static inline uintptr_t styx_page_start(uintptr_t addr) {
    return addr & ~(uintptr_t)(styx_page_size() - 1);
}

static inline size_t styx_page_len(uintptr_t addr, size_t len) {
    uintptr_t start = styx_page_start(addr);
    uintptr_t end   = styx_page_start(addr + len - 1) + styx_page_size();
    return (size_t)(end - start);
}

static inline kern_return_t styx_protect(uintptr_t start, size_t len,
                                         uint32_t prot, bool set_maximum) {
    return vm_protect(mach_task_self(), (vm_address_t)start, (vm_size_t)len,
                      set_maximum ? TRUE : FALSE, (vm_prot_t)prot);
}

// Our own Mach-O header (libstyx.dylib). We must never patch the image we are
// executing from — protecting its live code pages crashes the app.
static void *styx_own_header(void) {
    Dl_info info;
    if (dladdr((void *)&styx_own_header, &info) != 0) return info.dli_fbase;
    return NULL;
}

static bool styx_is_own_image(uintptr_t addr) {
    Dl_info info;
    if (dladdr((void *)addr, &info) == 0) return false;
    return info.dli_fbase == styx_own_header();
}

bool styx_region_info(uintptr_t addr, styx_region *out) {
    if (!out) return false;
    vm_address_t region = (vm_address_t)styx_page_start(addr);
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &size,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) return false;
    out->start   = (uintptr_t)region;
    out->size    = (size_t)size;
    out->prot    = (uint32_t)info.protection;
    out->maxprot = (uint32_t)info.max_protection;
    return true;
}

bool styx_mem_read(const void *address, void *buffer, size_t len) {
    if (!address || !buffer || len == 0) return false;
    memcpy(buffer, address, len);
    return true;
}

bool styx_mem_write_data(void *address, const void *buffer, size_t len) {
    return styx_mem_write(address, buffer, len);
}

bool styx_mem_set(void *address, uint8_t value, size_t len) {
    if (!address || len == 0) return false;
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) return false;
    memset(buf, value, len);
    bool ok = styx_mem_write(address, buf, len);
    free(buf);
    return ok;
}

bool styx_mem_write(void *address, const void *buffer, size_t len) {
    if (!address || !buffer || len == 0) return false;

    if (styx_is_own_image((uintptr_t)address)) {
        styx_log("[mem] REFUSE to patch own image @%p", address);
        return false;
    }

    uintptr_t pageStart = styx_page_start((uintptr_t)address);
    size_t    pageLen   = styx_page_len((uintptr_t)address, len);

    styx_region reg;
    if (!styx_region_info((uintptr_t)address, &reg)) {
        styx_log("[mem] region query FAIL @%p -- refusing write", address);
        return false;
    }
    // Do not straddle a region boundary: pageLen must stay inside the region.
    if (pageStart < reg.start || pageStart + pageLen > reg.start + reg.size) {
        styx_log("[mem] write straddles region @%p (page 0x%zx..0x%zx vs 0x%lx..0x%lx)",
                 address, (size_t)pageStart, (size_t)(pageStart + pageLen),
                 (unsigned long)reg.start, (unsigned long)(reg.start + reg.size));
        return false;
    }

    const uint32_t orig = reg.prot;
    const bool exec = (orig & VM_PROT_EXECUTE) != 0;

    // Fast path: already writable (data/heap/__DATA). Just write.
    if (orig & VM_PROT_WRITE) {
        memcpy(address, buffer, len);
        sys_icache_invalidate((void *)pageStart, pageLen);
        styx_log("[mem] wrote %zu B @%p (writable, prot=0x%x)", len, address, orig);
        return true;
    }

    // Make it writable through a private copy-on-write page.
    kern_return_t kr = styx_protect(pageStart, pageLen,
                                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY, false);
    if (kr != KERN_SUCCESS) {
        styx_log("[mem] vm_protect(RW|COPY) FAIL kr=%d page=0x%lx", (int)kr,
                 (unsigned long)pageStart);
        return false;
    }

    if (exec) {
        // Verify we can put EXECUTE back BEFORE dirtying the page.
        styx_protect(pageStart, pageLen, VM_PROT_READ | VM_PROT_WRITE, false);
        kern_return_t r2 = styx_protect(pageStart, pageLen, orig, true);
        styx_region now;
        bool restorable = (r2 == KERN_SUCCESS) &&
                          styx_region_info((uintptr_t)address, &now) &&
                          (now.prot & VM_PROT_EXECUTE);
        if (!restorable) {
            styx_protect(pageStart, pageLen, orig, true);
            styx_log("[mem] REFUSE exec-page patch @%p (cannot restore X: r2=%d prot=0x%x)",
                     address, (int)r2, now.prot);
            return false;
        }
        // Round-trip verified; re-acquire the writable copy for the real write.
        kr = styx_protect(pageStart, pageLen,
                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY, false);
        if (kr != KERN_SUCCESS) {
            styx_log("[mem] vm_protect(RW|COPY) re-acquire FAIL kr=%d", (int)kr);
            return false;
        }
    }

    memcpy(address, buffer, len);
    sys_icache_invalidate((void *)pageStart, pageLen);

    kr = styx_protect(pageStart, pageLen, orig, false);
    if (kr != KERN_SUCCESS) {
        kern_return_t kr2 = styx_protect(pageStart, pageLen, orig, true);
        styx_log("[mem] restore prot 0x%x FAIL kr=%d (setmax retry kr=%d)", orig, (int)kr, (int)kr2);
        if (exec && kr2 != KERN_SUCCESS)
            styx_log("[mem] FATAL: exec page left non-exec @0x%lx", (unsigned long)pageStart);
    }

    styx_log("[mem] patched %zu B @%p (page 0x%lx orig=0x%x max=0x%x exec=%d)",
             len, address, (unsigned long)pageStart, orig, reg.maxprot, (int)exec);
    return true;
}

bool styx_hook_branch(void *from, const void *to) {
    if (!from || !to) return false;
    styx_log("[mem] styx_hook_branch DISABLED (inline __TEXT patch is AMFI-unsafe); "
             "use styx_method_hook (data redirection) instead");
    return false;
}

uintptr_t styx_mem_scan(uintptr_t start, size_t size,
                        const uint8_t *pattern, const char *mask) {
    if (!start || !pattern || !mask || size == 0) return 0;
    size_t plen = strlen(mask);
    if (plen == 0 || plen > size) return 0;
    uintptr_t end = start + size - plen;
    for (uintptr_t p = start; p <= end; p++) {
        bool matched = true;
        for (size_t i = 0; i < plen; i++) {
            if (mask[i] != '?' && *(const uint8_t *)(p + i) != pattern[i]) {
                matched = false;
                break;
            }
        }
        if (matched) return p;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Capability probe (zero risk): private RX mapping of the running binary's page.
// ---------------------------------------------------------------------------

static bool styx_fileoff_for_rva(uintptr_t rva, uintptr_t *fileoff) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!h || h->magic != MH_MAGIC_64) return false;
    const uintptr_t va = 0x100000000ULL + rva; // preferrred base of the main image
    uintptr_t p = (uintptr_t)h + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
            if (va >= s->vmaddr && va < s->vmaddr + s->filesize) {
                *fileoff = (uintptr_t)s->fileoff + (va - s->vmaddr);
                return true;
            }
        }
        p += lc->cmdsize;
    }
    return false;
}

static void styx_caps_report(const char *tag, uintptr_t addr) {
    styx_region r;
    if (styx_region_info(addr, &r))
        styx_log("[caps] %s -> prot=0x%x max=0x%x rx=%d", tag, r.prot, r.maxprot,
                 (r.prot & VM_PROT_EXECUTE) ? 1 : 0);
    else
        styx_log("[caps] %s -> region query failed", tag);
}

void styx_probe_patch_caps(uintptr_t rva) {
    styx_log("[caps] ===== patch-capability probe (private mmap, no live code) =====");

    uintptr_t fileoff = 0;
    if (!styx_fileoff_for_rva(rva, &fileoff)) {
        styx_log("[caps] could not map rva 0x%lx to a file offset", (unsigned long)rva);
        return;
    }

    const char *path = styx_main_path();
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        styx_log("[caps] open(%s) failed", path ? path : "(null)");
        return;
    }

    size_t pg = styx_page_size();
    off_t poff = (off_t)(fileoff & ~(uintptr_t)(pg - 1));
    void *m = mmap(NULL, pg, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, poff);
    close(fd);
    if (m == MAP_FAILED) {
        styx_log("[caps] mmap(page) failed");
        return;
    }
    styx_caps_report("baseline RX copy", (uintptr_t)m);

    // Strategy A: vm_protect(READ|WRITE|COPY) then restore READ|EXECUTE.
    {
        kern_return_t k1 = styx_protect((uintptr_t)m, pg,
                                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY, false);
        memset(m, 0x90, 4); // ARM64 NOP
        kern_return_t k2 = styx_protect((uintptr_t)m, pg, VM_PROT_READ | VM_PROT_EXECUTE, false);
        styx_log("[caps] A vm_protect(COPY)=%d restore(RX)=%d", (int)k1, (int)k2);
        styx_caps_report("A after restore", (uintptr_t)m);
    }

    // Strategy B: POSIX mprotect(RW) then mprotect(RX).
    {
        int r1 = mprotect(m, pg, PROT_READ | PROT_WRITE);
        memset(m, 0x90, 4);
        int r2 = mprotect(m, pg, PROT_READ | PROT_EXEC);
        styx_log("[caps] B mprotect(RW)=%d mprotect(RX)=%d", r1, r2);
        styx_caps_report("B after restore", (uintptr_t)m);
    }

    // Strategy C: raise maximum to RWX, COPY-write, restore RX.
    {
        kern_return_t c0 = styx_protect((uintptr_t)m, pg,
                                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE, true);
        kern_return_t c1 = styx_protect((uintptr_t)m, pg,
                                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY, false);
        memset(m, 0x90, 4);
        kern_return_t c2 = styx_protect((uintptr_t)m, pg, VM_PROT_READ | VM_PROT_EXECUTE, false);
        styx_log("[caps] C setmax(RWX)=%d copy=%d restore(RX)=%d", (int)c0, (int)c1, (int)c2);
        styx_caps_report("C after restore", (uintptr_t)m);
    }

    munmap(m, pg);
    styx_log("[caps] ===== probe done =====");
}
