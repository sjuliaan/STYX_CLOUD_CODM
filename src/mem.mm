#include "mem.h"
#include "styxlog.h"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <libkern/OSCacheControl.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// No-JIT memory patching (jailed iOS).
//
// We do NOT inline-patch the game's executable __TEXT pages. Confirmed on
// iOS 17.6.1 (probe): once a code page is made writable via
// vm_protect(VM_PROT_COPY) its max protection drops to RW, VM_PROT_EXECUTE can
// never be restored (kr=2), and mprotect back to RX fails (-1). The next
// instruction fetch on a dirtied page is a CODESIGNING "Invalid Page" SIGKILL.
//
// The only safe technique is DATA-only redirection:
//   * rebind symbol/pointer slots in __DATA / __DATA_CONST (fishhook-style), and
//   * redirect il2cpp method pointers in __DATA_CONST (see hook.mm),
// both via a plain writable write or vm_protect(VM_PROT_COPY).
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

// Our own Mach-O header (our framework dylib). Never patch the image we run from.
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

// Make [start, start+len) writable. `exec` pages are never forced (we must be
// able to put EXECUTE back). For data pages, if COPY fails because the region's
// max protection was lowered to R, raise the maximum first and retry.
static bool styx_make_writable(uintptr_t start, size_t len, bool exec) {
    kern_return_t kr = styx_protect(start, len,
                                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY, false);
    if (kr == KERN_SUCCESS) return true;
    if (exec) return false;

    // Data page: try to raise the maximum protection, then request the copy.
    if (styx_protect(start, len, VM_PROT_READ | VM_PROT_WRITE, true) == KERN_SUCCESS) {
        kr = styx_protect(start, len,
                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY, false);
        if (kr == KERN_SUCCESS) return true;
    }
    return false;
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
    if (pageStart < reg.start || pageStart + pageLen > reg.start + reg.size) {
        styx_log("[mem] write straddles region @%p", address);
        return false;
    }

    const uint32_t orig = reg.prot;
    const bool exec = (orig & VM_PROT_EXECUTE) != 0;

    // Fast path: already writable data.
    if (orig & VM_PROT_WRITE) {
        memcpy(address, buffer, len);
        sys_icache_invalidate((void *)pageStart, pageLen);
        return true;
    }

    if (!styx_make_writable(pageStart, pageLen, exec)) {
        styx_log("[mem] make_writable FAIL @%p (prot=0x%x max=0x%x exec=%d)",
                 address, orig, reg.maxprot, (int)exec);
        return false;
    }

    if (exec) {
        // Prove we can restore EXECUTE before dirtying the page.
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
        if (!styx_make_writable(pageStart, pageLen, exec)) {
            styx_log("[mem] make_writable (re-acquire) FAIL @%p", address);
            return false;
        }
    }

    memcpy(address, buffer, len);
    sys_icache_invalidate((void *)pageStart, pageLen);

    kern_return_t kr = styx_protect(pageStart, pageLen, orig, false);
    if (kr != KERN_SUCCESS && exec) {
        kern_return_t kr2 = styx_protect(pageStart, pageLen, orig, true);
        if (kr2 != KERN_SUCCESS)
            styx_log("[mem] FATAL: exec page left non-exec @0x%lx", (unsigned long)pageStart);
    }
    return true;
}

bool styx_hook_branch(void *from, const void *to) {
    (void)from; (void)to;
    styx_log("[mem] styx_hook_branch DISABLED (inline __TEXT patch is AMFI-unsafe)");
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
