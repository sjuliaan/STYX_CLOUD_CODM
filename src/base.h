#pragma once
#include <stdint.h>
#include <string.h>
#include <mach-o/dyld.h>

// The main executable (index 0) is the app binary (`codm`). Its Mach-O header is
// linked at vmaddr 0x100000000, so a dumped symbol at VA (0x100000000 + RVA) is
// reachable at `base + RVA`.
static inline uintptr_t styx_main_base(void) {
    return (uintptr_t)_dyld_get_image_header(0);
}

static inline intptr_t styx_main_slide(void) {
    return (intptr_t)_dyld_get_image_vmaddr_slide(0);
}

static inline const char *styx_main_path(void) {
    return _dyld_get_image_name(0);
}

static inline uintptr_t styx_addr(uintptr_t rva) {
    return styx_main_base() + rva;
}

// Fallback: locate an image whose path contains `needle` (e.g. "codm").
static inline uintptr_t styx_find_image(const char *needle) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, needle))
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}
