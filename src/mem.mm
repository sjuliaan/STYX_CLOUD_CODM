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
// No-JIT code patching (jailed iOS).
//
// The previous implementation swapped the target page with an anonymous copy
// via mach_vm_remap(VM_FLAGS_OVERWRITE). On iOS 17 the AMFI code-signing
// monitor treats that as an "Invalid Page" and SIGKILLs the process (confirmed
// by a crash report: EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE / namespace
// CODESIGNING on libstyx's own __TEXT page).
//
// The correct jailed technique (KittyMemory-style) is vm_protect + VM_PROT_COPY:
// the kernel makes a private copy-on-write copy of the page, so the signed page
// stays valid and we can write to it. No executable anonymous memory needed.
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

// Our own Mach-O header (libstyx.dylib). We must never patch the image we are
// executing from — remapping/protecting its live code pages crashes the app.
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

static bool styx_region_prot(uintptr_t addr, vm_prot_t *prot) {
    vm_address_t region = (vm_address_t)styx_page_start(addr);
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &size,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) return false;
    *prot = info.protection;
    return true;
}

bool styx_mem_read(const void *address, void *buffer, size_t len) {
    if (!address || !buffer || len == 0) return false;
    memcpy(buffer, address, len);
    return true;
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

    vm_prot_t orig = VM_PROT_READ | VM_PROT_EXECUTE; // sane default for code
    styx_region_prot((uintptr_t)address, &orig);

    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)pageStart,
                                  (vm_size_t)pageLen, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        styx_log("[mem] vm_protect(COPY) FAIL kr=%d page=%p", (int)kr, (void *)pageStart);
        return false;
    }

    memcpy(address, buffer, len);
    sys_icache_invalidate((void *)pageStart, pageLen);

    kr = vm_protect(mach_task_self(), (vm_address_t)pageStart, (vm_size_t)pageLen,
                    FALSE, orig);
    if (kr != KERN_SUCCESS)
        styx_log("[mem] vm_protect(restore 0x%x) FAIL kr=%d", (unsigned)orig, (int)kr);

    styx_log("[mem] patched %zu byte(s) @%p (page %p orig=0x%x)",
             len, address, (void *)pageStart, (unsigned)orig);
    return true;
}

bool styx_hook_branch(void *from, const void *to) {
    if (!from || !to) return false;
    uintptr_t src = (uintptr_t)from;
    uintptr_t dst = (uintptr_t)to;
    int64_t delta = (int64_t)dst - (int64_t)src;
    if (delta < -(128LL << 20) || delta > (128LL << 20) - 4) {
        styx_log("[mem] branch out of range %p -> %p (needs trampoline)", from, to);
        return false;
    }
    uint32_t insn = 0x14000000u | ((uint32_t)((delta >> 2) & 0x03FFFFFFu));
    return styx_mem_write(from, &insn, sizeof(insn));
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
