// stealth.mm — ACE detection bypass (v2).
//
// Strategy: the COD Mobile anti-cheat lives in the embedded frameworks
// anogs / kgvmp_dy / enq_transceiver_dy / TDataMaster / CrashSight. All of
// them use classic bindings (LC_DYLD_INFO_ONLY), so we can rebind their
// imported libc / mach / dyld symbols per-image with fishhook and (a) observe
// and (b) filter what they see.
//
// v2 active filters: dyld image enumeration (our image removed from the list),
// dladdr() (image hidden), sysctl P_TRACED scrub, and file-probe denial for
// styx/frida/substrate/cydia-style paths. task_info / mach_vm_region_recurse /
// proc_regionfilename stay log-only (Unity uses TASK_VM_INFO itself).
//
// Detection surface (from IDA recon of anogs + import scan of the siblings):
//   module enum : _dyld_image_count / _dyld_get_image_name / _dyld_get_image_header
//   addr->file  : proc_regionfilename + mach_vm_region_recurse
//   anti-debug  : sysctl (P_TRACED), sysctlbyname, task_info, task_get_special_port
//   root/files  : stat / lstat / access / open / fopen / opendir / statfs
//   env         : getenv

#include "stealth.h"

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>

#import <Foundation/Foundation.h>

#include "fishhook.h"

#ifdef __cplusplus
extern "C" {
#endif

// Declarations not always shipped in the iOS SDK.
extern int proc_regionfilename(int pid, uint64_t address, void *buffer, uint32_t buffersize);
extern kern_return_t mach_vm_region_recurse(vm_map_t target_task,
                                            mach_vm_address_t *address,
                                            mach_vm_size_t *size,
                                            natural_t *nesting_depth,
                                            void *info,
                                            mach_msg_type_number_t *info_cnt);

#ifdef __cplusplus
}
#endif

// ---------------------------------------------------------------------------
// Probe log (raw fd + write(); never goes through a rebindable symbol).
// ---------------------------------------------------------------------------

static int      g_fd       = -1;
static int      g_armed    = 0;
static __thread int tls_hook = 0;

static void probe_open(void) {
    if (g_fd >= 0) return;
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir  = paths.count ? paths[0] : NSTemporaryDirectory();
        NSString *path = [dir stringByAppendingPathComponent:@"styx_ace.log"];
        g_fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
}

static void probe_printf(const char *fmt, ...) {
    if (g_fd < 0) return;
    char buf[768];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n > (int)sizeof(buf) - 1) n = (int)sizeof(buf) - 1;
    ssize_t ignored = write(g_fd, buf, (size_t)n);
    ignored = write(g_fd, "\n", 1);
    (void)ignored;
}

static const char *istrstr(const char *hay, const char *needle) {
    if (!hay || !needle) return NULL;
    size_t nl = strlen(needle);
    if (!nl) return hay;
    for (const char *p = hay; *p; ++p) {
        size_t i = 0;
        while (i < nl && p[i] &&
               (char)((p[i] >= 'A' && p[i] <= 'Z') ? p[i] + 32 : p[i]) ==
               (char)((needle[i] >= 'A' && needle[i] <= 'Z') ? needle[i] + 32 : needle[i]))
            ++i;
        if (i == nl) return p;
    }
    return NULL;
}

// Paths the ACE touches that are worth recording.
static int path_interesting(const char *p) {
    static const char *keys[] = {
        "styx", "codm", ".app/", "payload", "mobileprovision", "codesignature",
        "_codedirectory", "sc_info", "substrate", "cydia", "frida", "bulldozer",
        "/var/", "/etc/", "/bin/", "/usr/", "/applications", "password", "libhooker",
        "ellekit", "shadow", NULL
    };
    if (!p) return 0;
    for (int i = 0; keys[i]; ++i)
        if (istrstr(p, keys[i])) return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// Originals (filled in by fishhook's `replaced` out-param).
// ---------------------------------------------------------------------------

static uint32_t             (*orig_dyld_image_count)(void)                      = NULL;
static const char *         (*orig_dyld_get_image_name)(uint32_t)              = NULL;
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t)       = NULL;
static intptr_t             (*orig_dyld_get_image_vmaddr_slide)(uint32_t)      = NULL;
static int                  (*orig_dladdr)(const void *, Dl_info *)            = NULL;

static int  (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t)     = NULL;
static int  (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static pid_t (*orig_getpid)(void)                                              = NULL;
static pid_t (*orig_getppid)(void)                                             = NULL;
static kern_return_t (*orig_task_info)(task_t, task_flavor_t, task_info_t, mach_msg_type_number_t *) = NULL;
static kern_return_t (*orig_task_get_special_port)(task_t, int, mach_port_t *) = NULL;

static int  (*orig_proc_regionfilename)(int, uint64_t, void *, uint32_t)      = NULL;
static kern_return_t (*orig_mach_vm_region_recurse)(vm_map_t, mach_vm_address_t *, mach_vm_size_t *, natural_t *, void *, mach_msg_type_number_t *) = NULL;

static int  (*orig_stat)(const char *, struct stat *)                          = NULL;
static int  (*orig_lstat)(const char *, struct stat *)                         = NULL;
static int  (*orig_access)(const char *, int)                                  = NULL;
static int  (*orig_open)(const char *, int, ...)                               = NULL;
static FILE *(*orig_fopen)(const char *, const char *)                         = NULL;
static DIR *(*orig_opendir)(const char *)                                      = NULL;
static int  (*orig_statfs)(const char *, struct statfs *)                      = NULL;

static char *(*orig_getenv)(const char *)                                      = NULL;

// ---------------------------------------------------------------------------
// Shims. Every shim: if unarmed / re-entrant -> straight through to real.
// ---------------------------------------------------------------------------

static uint32_t g_c_dyld = 0, g_c_sys = 0, g_c_file = 0, g_c_task = 0,
                g_c_region = 0, g_c_env = 0;
#define CAP_DYLD   600u
#define CAP_SYS    400u
#define CAP_FILE   300u
#define CAP_TASK   120u
#define CAP_REGION 200u
#define CAP_ENV    200u

// Our own image, so the ACE cannot enumerate us via dyld or dladdr.
static int   g_our_index  = -1;      // _dyld index of libstyx.dylib
static void *g_our_header = NULL;    // its mach_header

// Remap a caller-supplied dyld index so our image is invisible (the reported
// list is simply shifted down by one after our slot).
static inline uint32_t styx_dyld_remap(uint32_t idx) {
    if (g_our_index >= 0 && idx >= (uint32_t)g_our_index) return idx + 1;
    return idx;
}

// Paths whose access the ACE must not observe.
static int path_denied(const char *p) {
    static const char *keys[] = {
        "styx", "frida", "substrate", "libhooker", "ellekit", "cydia",
        "sileo", "odyssey", "trollstore", "dnssd", NULL
    };
    if (!p) return 0;
    for (int i = 0; keys[i]; ++i)
        if (istrstr(p, keys[i])) return 1;
    return 0;
}

static uint32_t shim_dyld_image_count(void) {
    if (!g_armed || tls_hook) return orig_dyld_image_count();
    tls_hook = 1;
    uint32_t c = orig_dyld_image_count();
    if (g_our_index >= 0 && (uint32_t)g_our_index < c) c--;
    if (g_c_dyld++ < CAP_DYLD) probe_printf("[dyld.count ] -> %u (hidden our idx %d)", c, g_our_index);
    tls_hook = 0;
    return c;
}

static const char *shim_dyld_get_image_name(uint32_t idx) {
    if (!g_armed || tls_hook) return orig_dyld_get_image_name(idx);
    tls_hook = 1;
    uint32_t ridx = styx_dyld_remap(idx);
    const char *n = orig_dyld_get_image_name(ridx);
    if (g_c_dyld++ < CAP_DYLD)
        probe_printf("[dyld.name  ] [%u->%u] %s", idx, ridx, n ? n : "(null)");
    tls_hook = 0;
    return n;
}

static const struct mach_header *shim_dyld_get_image_header(uint32_t idx) {
    if (!g_armed || tls_hook) return orig_dyld_get_image_header(idx);
    tls_hook = 1;
    uint32_t ridx = styx_dyld_remap(idx);
    const struct mach_header *h = orig_dyld_get_image_header(ridx);
    if (g_c_dyld++ < CAP_DYLD)
        probe_printf("[dyld.head  ] [%u->%u] %p", idx, ridx, (const void *)h);
    tls_hook = 0;
    return h;
}

static intptr_t shim_dyld_get_image_vmaddr_slide(uint32_t idx) {
    if (!g_armed || tls_hook) return orig_dyld_get_image_vmaddr_slide(idx);
    tls_hook = 1;
    intptr_t s = orig_dyld_get_image_vmaddr_slide(styx_dyld_remap(idx));
    tls_hook = 0;
    return s;
}

static int shim_dladdr(const void *addr, Dl_info *info) {
    if (!g_armed || tls_hook) return orig_dladdr(addr, info);
    tls_hook = 1;
    int r = orig_dladdr(addr, info);
    if (r && info && g_our_header && info->dli_fbase == g_our_header) {
        memset(info, 0, sizeof(*info));
        r = 0;
        if (g_c_dyld++ < CAP_DYLD) probe_printf("[dladdr     ] HID our image for %p", addr);
    }
    tls_hook = 0;
    return r;
}

static int shim_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!g_armed || tls_hook) return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    tls_hook = 1;
    int flag = 0;
    if (name && namelen >= 2 && name[0] == CTL_KERN && name[1] == KERN_PROC) flag = 1;
    if (g_c_sys++ < CAP_SYS)
        probe_printf("[sysctl     ] mib=%d,%d%s", name && namelen > 0 ? name[0] : -1,
                     name && namelen > 1 ? name[1] : -1,
                     flag ? "   <<< P_TRACED / KERN_PROC" : "");
    int r = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    // Scrub P_TRACED from any KERN_PROC result (anti-debug probe).
    if (r == 0 && flag && oldp && oldlenp &&
        *oldlenp >= sizeof(struct kinfo_proc)) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        if (kp->kp_proc.p_flag & P_TRACED) {
            kp->kp_proc.p_flag &= ~P_TRACED;
            probe_printf("[sysctl     ] scrubbed P_TRACED");
        }
    }
    tls_hook = 0;
    return r;
}

static int shim_sysctlbyname(const char *n, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!g_armed || tls_hook) return orig_sysctlbyname(n, oldp, oldlenp, newp, newlen);
    tls_hook = 1;
    int flag = n && (istrstr(n, "kern.proc") || istrstr(n, "kern.argmax") ||
                     istrstr(n, "hw.machine") || istrstr(n, "model"));
    if (g_c_sys++ < CAP_SYS)
        probe_printf("[sysctlbynm ] %s%s", n ? n : "(null)",
                     flag ? "   <<< model / proc query" : "");
    int r = orig_sysctlbyname(n, oldp, oldlenp, newp, newlen);
    tls_hook = 0;
    return r;
}

static pid_t shim_getpid(void) {
    if (!g_armed || tls_hook) return orig_getpid();
    tls_hook = 1;
    static int once = 0;
    if (!once++) probe_printf("[getpid     ] called (used for sysctl(KERN_PROC) debugger probe)");
    tls_hook = 0;
    return orig_getpid();
}

static pid_t shim_getppid(void) {
    if (!g_armed || tls_hook) return orig_getppid();
    tls_hook = 1;
    static int once = 0;
    if (!once++) probe_printf("[getppid    ] called (parent-process probe)");
    tls_hook = 0;
    return orig_getppid();
}

static kern_return_t shim_task_info(task_t t, task_flavor_t f, task_info_t o, mach_msg_type_number_t *c) {
    if (!g_armed || tls_hook) return orig_task_info(t, f, o, c);
    tls_hook = 1;
    if (g_c_task++ < CAP_TASK)
        probe_printf("[task_info  ] flavor=%d (5=TASK_DYLD_INFO)%s", f,
                     f == 5 ? "   <<< TASK_DYLD_INFO" : "");
    kern_return_t r = orig_task_info(t, f, o, c);
    tls_hook = 0;
    return r;
}

static kern_return_t shim_task_get_special_port(task_t t, int which, mach_port_t *p) {
    if (!g_armed || tls_hook) return orig_task_get_special_port(t, which, p);
    tls_hook = 1;
    if (g_c_task++ < CAP_TASK)
        probe_printf("[task_port  ] which=%d", which);
    kern_return_t r = orig_task_get_special_port(t, which, p);
    tls_hook = 0;
    return r;
}

static int shim_proc_regionfilename(int pid, uint64_t addr, void *buf, uint32_t sz) {
    if (!g_armed || tls_hook) return orig_proc_regionfilename(pid, addr, buf, sz);
    tls_hook = 1;
    int r = orig_proc_regionfilename(pid, addr, buf, sz);
    if (g_c_region++ < CAP_REGION)
        probe_printf("[region.fn  ] pid=%d addr=0x%llx -> %d%s", pid, (unsigned long long)addr, r,
                     r < 1 ? "   <<< ANONYMOUS REGION (no file)" : "");
    tls_hook = 0;
    return r;
}

static kern_return_t shim_mach_vm_region_recurse(vm_map_t t, mach_vm_address_t *a, mach_vm_size_t *s,
                                                 natural_t *d, void *i, mach_msg_type_number_t *c) {
    if (!g_armed || tls_hook) return orig_mach_vm_region_recurse(t, a, s, d, i, c);
    tls_hook = 1;
    kern_return_t r = orig_mach_vm_region_recurse(t, a, s, d, i, c);
    if (g_c_region++ < CAP_REGION)
        probe_printf("[vm.region  ] addr=0x%llx size=0x%llx r=%d", (unsigned long long)(a ? *a : 0),
                     (unsigned long long)(s ? *s : 0), r);
    tls_hook = 0;
    return r;
}

static int shim_stat(const char *p, struct stat *b) {
    if (!g_armed || tls_hook) return orig_stat(p, b);
    tls_hook = 1;
    if (path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[stat       ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[stat       ] %s", p ? p : "(null)");
    int r = orig_stat(p, b);
    tls_hook = 0;
    return r;
}

static int shim_lstat(const char *p, struct stat *b) {
    if (!g_armed || tls_hook) return orig_lstat(p, b);
    tls_hook = 1;
    if (path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[lstat      ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[lstat      ] %s", p ? p : "(null)");
    int r = orig_lstat(p, b);
    tls_hook = 0;
    return r;
}

static int shim_access(const char *p, int m) {
    if (!g_armed || tls_hook) return orig_access(p, m);
    tls_hook = 1;
    if (path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[access     ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[access     ] %s mode=%d", p ? p : "(null)", m);
    int r = orig_access(p, m);
    tls_hook = 0;
    return r;
}

static int shim_open(const char *p, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    if (!g_armed || tls_hook) return orig_open(p, flags, mode);
    tls_hook = 1;
    if (path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[open       ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[open       ] %s flags=0x%x", p ? p : "(null)", flags);
    int r = orig_open(p, flags, mode);
    tls_hook = 0;
    return r;
}

static FILE *shim_fopen(const char *p, const char *m) {
    if (!g_armed || tls_hook) return orig_fopen(p, m);
    tls_hook = 1;
    if (path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[fopen      ] DENY %s", p); tls_hook = 0; errno = ENOENT; return NULL; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[fopen      ] %s mode=%s", p ? p : "(null)", m ? m : "(null)");
    FILE *r = orig_fopen(p, m);
    tls_hook = 0;
    return r;
}

static DIR *shim_opendir(const char *p) {
    if (!g_armed || tls_hook) return orig_opendir(p);
    tls_hook = 1;
    if (path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[opendir    ] DENY %s", p); tls_hook = 0; errno = ENOENT; return NULL; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[opendir    ] %s", p ? p : "(null)");
    DIR *r = orig_opendir(p);
    tls_hook = 0;
    return r;
}

static int shim_statfs(const char *p, struct statfs *b) {
    if (!g_armed || tls_hook) return orig_statfs(p, b);
    tls_hook = 1;
    if (path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[statfs     ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[statfs     ] %s", p ? p : "(null)");
    int r = orig_statfs(p, b);
    tls_hook = 0;
    return r;
}

static char *shim_getenv(const char *n) {
    if (!g_armed || tls_hook) return orig_getenv(n);
    tls_hook = 1;
    if (g_c_env++ < CAP_ENV)
        probe_printf("[getenv     ] %s%s", n ? n : "(null)",
                     (n && strncmp(n, "DYLD_", 5) == 0) ? "   <<< DYLD env query" : "");
    char *r = orig_getenv(n);
    tls_hook = 0;
    return r;
}

// ---------------------------------------------------------------------------
// Rebinding
// ---------------------------------------------------------------------------

static struct rebinding g_rebinds[] = {
    { "_dyld_image_count",            (void *)shim_dyld_image_count,           (void **)&orig_dyld_image_count },
    { "_dyld_get_image_name",         (void *)shim_dyld_get_image_name,        (void **)&orig_dyld_get_image_name },
    { "_dyld_get_image_header",       (void *)shim_dyld_get_image_header,      (void **)&orig_dyld_get_image_header },
    { "_dyld_get_image_vmaddr_slide", (void *)shim_dyld_get_image_vmaddr_slide, (void **)&orig_dyld_get_image_vmaddr_slide },
    { "dladdr",                       (void *)shim_dladdr,                      (void **)&orig_dladdr },
    { "sysctl",                       (void *)shim_sysctl,                     (void **)&orig_sysctl },
    { "sysctlbyname",                 (void *)shim_sysctlbyname,               (void **)&orig_sysctlbyname },
    { "getpid",                       (void *)shim_getpid,                     (void **)&orig_getpid },
    { "getppid",                      (void *)shim_getppid,                    (void **)&orig_getppid },
    { "task_info",                    (void *)shim_task_info,                  (void **)&orig_task_info },
    { "task_get_special_port",        (void *)shim_task_get_special_port,      (void **)&orig_task_get_special_port },
    { "proc_regionfilename",          (void *)shim_proc_regionfilename,        (void **)&orig_proc_regionfilename },
    { "mach_vm_region_recurse",       (void *)shim_mach_vm_region_recurse,     (void **)&orig_mach_vm_region_recurse },
    { "stat",                         (void *)shim_stat,                       (void **)&orig_stat },
    { "lstat",                        (void *)shim_lstat,                      (void **)&orig_lstat },
    { "access",                       (void *)shim_access,                     (void **)&orig_access },
    { "open",                         (void *)shim_open,                       (void **)&orig_open },
    { "fopen",                        (void *)shim_fopen,                      (void **)&orig_fopen },
    { "opendir",                      (void *)shim_opendir,                    (void **)&orig_opendir },
    { "statfs",                       (void *)shim_statfs,                     (void **)&orig_statfs },
    { "getenv",                       (void *)shim_getenv,                     (void **)&orig_getenv },
};
#define N_REBINDS (sizeof(g_rebinds) / sizeof(g_rebinds[0]))

static const char *g_targets[] = {
    "anogs.framework",
    "kgvmp_dy.framework",
    "enq_transceiver_dy.framework",
    "TDataMaster.framework",
    "CrashSight.framework",
    NULL
};

static void rebind_targets(void) {
    uint32_t count = _dyld_image_count();
    for (const char **t = g_targets; *t; ++t) {
        int found = 0;
        for (uint32_t i = 0; i < count; ++i) {
            const char *nm = _dyld_get_image_name(i);
            if (!nm || !istrstr(nm, *t)) continue;
            const struct mach_header *h = _dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            int rc = rebind_symbols_image((void *)h, slide, g_rebinds, N_REBINDS);
            probe_printf("[rebind     ] %s idx=%u rc=%d", *t, i, rc);
            found = 1;
        }
        if (!found) probe_printf("[rebind     ] %s NOT LOADED", *t);
    }

    int resolved = 0;
    for (size_t i = 0; i < N_REBINDS; ++i)
        if (g_rebinds[i].replaced && *g_rebinds[i].replaced) ++resolved;
    probe_printf("[rebind     ] originals resolved: %d / %zu", resolved, N_REBINDS);
}

// ---------------------------------------------------------------------------

void styx_stealth_start(void) {
    static int started = 0;
    if (started) return;
    started = 1;

    probe_open();
    probe_printf("================ STYX ACE BYPASS (v2) ================");

    // Locate our own image so the ACE cannot enumerate us.
    {
        Dl_info info;
        if (dladdr((void *)&styx_stealth_start, &info) != 0) {
            g_our_header = info.dli_fbase;
            uint32_t count = _dyld_image_count();
            for (uint32_t i = 0; i < count; ++i) {
                if (_dyld_get_image_header(i) == g_our_header) { g_our_index = (int)i; break; }
            }
        }
        probe_printf("[self       ] header=%p dyld_idx=%d", g_our_header, g_our_index);
    }

    rebind_targets();

    g_armed = 1;
    probe_printf("[init       ] bypass armed. Filtering detection calls...");
    probe_printf("======================================================");
}
