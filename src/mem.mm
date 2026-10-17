#include "mem.h"

#include <mach/mach.h>
#include <mach/vm_types.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <libkern/OSCacheControl.h>

// The iOS SDK ships a stub `mach/mach_vm.h` that #errors. The mach_vm_* entry
// points are still exported by libsystem_kernel, so declare what we need.
extern kern_return_t mach_vm_remap(
    vm_map_t            target_task,
    mach_vm_address_t  *target_address,
    mach_vm_size_t      size,
    mach_vm_offset_t    mask,
    int                 flags,
    vm_map_t            src_task,
    mach_vm_address_t   src_address,
    boolean_t           copy,
    vm_prot_t          *cur_protection,
    vm_prot_t          *max_protection,
    vm_inherit_t        inheritance);

extern kern_return_t vm_copy(
    vm_map_t    target_task,
    vm_address_t target_address,
    vm_size_t   size,
    vm_address_t source_address);

#ifndef VM_FLAGS_FIXED
#define VM_FLAGS_FIXED 0x00000000
#endif
#ifndef VM_FLAGS_OVERWRITE
#define VM_FLAGS_OVERWRITE 0x00000008
#endif

static inline size_t styx_page_size(void) { return (size_t)getpagesize(); }

static inline uintptr_t styx_page_start(uintptr_t addr) {
    return addr & ~(uintptr_t)(styx_page_size() - 1);
}

static inline size_t styx_page_len(uintptr_t addr, size_t len) {
    uintptr_t start = styx_page_start(addr);
    uintptr_t end   = styx_page_start(addr + len - 1) + styx_page_size();
    return (size_t)(end - start);
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

// The target page is executable/read-only and vm_protect(RW) is denied without
// JIT. Copy the page into a fresh anonymous RW mapping, apply the patch there,
// mark it RX, then remap it back over the original address.
bool styx_mem_write(void *address, const void *buffer, size_t len) {
    if (!address || !buffer || len == 0) return false;

    task_t self = mach_task_self();
    uintptr_t pageStart = styx_page_start((uintptr_t)address);
    size_t pageLen = styx_page_len((uintptr_t)address, len);

    void *newMap = mmap(NULL, pageLen, PROT_READ | PROT_WRITE,
                        MAP_ANONYMOUS | MAP_PRIVATE, 0, 0);
    if (newMap == MAP_FAILED) return false;

    if (vm_copy(self, (vm_address_t)pageStart, (vm_size_t)pageLen,
                (vm_address_t)newMap) != KERN_SUCCESS) {
        munmap(newMap, pageLen);
        return false;
    }

    uintptr_t dst = (uintptr_t)newMap + ((uintptr_t)address - pageStart);
    memcpy((void *)dst, buffer, len);

    if (mprotect(newMap, pageLen, PROT_READ | PROT_EXEC) != 0) {
        munmap(newMap, pageLen);
        return false;
    }

    vm_prot_t cur = 0, max = 0;
    mach_vm_address_t target = (mach_vm_address_t)pageStart;
    kern_return_t kr = mach_vm_remap(self, &target, (mach_vm_size_t)pageLen, 0,
                                     VM_FLAGS_OVERWRITE | VM_FLAGS_FIXED, self,
                                     (mach_vm_address_t)newMap, FALSE,
                                     &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        munmap(newMap, pageLen);
        return false;
    }

    sys_icache_invalidate((void *)pageStart, pageLen);
    return true;
}

bool styx_hook_branch(void *from, const void *to) {
    if (!from || !to) return false;
    uintptr_t src = (uintptr_t)from;
    uintptr_t dst = (uintptr_t)to;
    int64_t delta = (int64_t)dst - (int64_t)src;
    if (delta < -(128LL << 20) || delta > (128LL << 20) - 4) {
        return false; // out of +/-128MB branch range; needs a trampoline
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
