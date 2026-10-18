// stealth.mm — ACE detection bypass (v3, rival parity).
//
// Recon of the rival dylib (Cloud_CODM 1.6.57) showed its anti-cheat bypass is a
// *global* fishhook `rebind_symbols` install (its InitFunc_6 / InitFunc_0) plus an
// NSBundle metadata spoof. It rebinds, in every image, the exact symbols below and
// neutralises the AnoSDK command channel. We now match that:
//
//   AnoSDKIoctl                 -> return 0 for a fixed command set; spoof the
//                                  version query (cmd 14) with "7.7.58.42114"
//   dyld image enumeration      -> hide our own image (count/name/header/slide/dladdr)
//   getsegbyname/getsegmentdata -> log only (we do NOT patch the main cryptid, so
//                                  masking __LINKEDIT buys us nothing)
//   SecCode/SecStaticCodeCheck  -> return 0 (valid)
//   SecCertificateCopySubject   -> spoof "Apple Distribution: Activision ..."
//   SecTaskCopyValueForEntitle  -> spoof application-identifier / team-id / get-task-allow
//   sysctl / sysctlbyname       -> scrub P_TRACED, zero the {KERN,14} probe
//   ptrace                      -> PT_DENY_ATTACH (31) returns 0
//   csops / csops_audittoken    -> passthrough (inert parity)
//   send / recv                 -> rewrite anti-cheat packets ("01 00 09" -> "00 00 09")
//   NSBundle methods            -> spoof bundle id / signing identity (swizzled)
//
// fishhook compares `&symbol_name[1]` (i.e. the name with the binary's leading
// underscore stripped) to the rebind name, so names here must NOT start with '_'.
//
// NOTE: nslog-style `[rebind] originals resolved: N / M` in styx_ace.log confirms
// which symbols actually resolved.

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
#include <sys/socket.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>

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

// Our own probe/log files must never be filtered — the global rebind means our
// own open()/fopen() calls go through these shims too.
static int path_is_our_log(const char *p) {
    if (!p) return 0;
    return istrstr(p, "styx.log") || istrstr(p, "styx_ace.log");
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

// Rival-parity additions.
static int  (*orig_AnoSDKIoctl)(int, void *, void *, size_t)                  = NULL;
static long (*orig_ptrace)(int, int, void *, int)                              = NULL;
static const void *(*orig_getsegbyname)(const char *)                          = NULL;
static void *(*orig_getsegmentdata)(const void *, const char *, size_t *)      = NULL;
static int  (*orig_SecCodeCheckValidity)(void *, uint32_t, void *)             = NULL;
static int  (*orig_SecStaticCodeCheckValidity)(void *, uint32_t, void *)       = NULL;
static CFStringRef (*orig_SecCertificateCopySubjectSummary)(void *)            = NULL;
static CFTypeRef (*orig_SecTaskCopyValueForEntitlement)(void *, CFStringRef, CFErrorRef *) = NULL;
static int  (*orig_csops)(int, unsigned int, void *, size_t)                   = NULL;
static int  (*orig_csops_audittoken)(int, unsigned int, void *, size_t, uint32_t *) = NULL;
static ssize_t (*orig_send)(int, const void *, size_t, int)                    = NULL;
static ssize_t (*orig_recv)(int, void *, size_t, int)                          = NULL;

// ---------------------------------------------------------------------------
// Shims. Every shim: if unarmed / re-entrant -> straight through to real.
// ---------------------------------------------------------------------------

static uint32_t g_c_dyld = 0, g_c_sys = 0, g_c_file = 0, g_c_task = 0,
                g_c_region = 0, g_c_env = 0, g_c_ace = 0, g_c_net = 0;
#define CAP_DYLD   600u
#define CAP_SYS    400u
#define CAP_FILE   300u
#define CAP_TASK   120u
#define CAP_REGION 200u
#define CAP_ENV    200u
#define CAP_ACE    200u
#define CAP_NET    200u

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

    // Zero the output of the {CTL_KERN(1),14} probe outright (rival parity).
    if (name && namelen >= 2 && name[0] == CTL_KERN && name[1] == 14) {
        if (oldp && oldlenp && *oldlenp) memset(oldp, 0, *oldlenp);
        if (g_c_sys++ < CAP_SYS) probe_printf("[sysctl     ] {KERN,14} -> zeroed");
        tls_hook = 0;
        return 0;
    }

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
    if (!path_is_our_log(p) && path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[stat       ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[stat       ] %s", p ? p : "(null)");
    int r = orig_stat(p, b);
    tls_hook = 0;
    return r;
}

static int shim_lstat(const char *p, struct stat *b) {
    if (!g_armed || tls_hook) return orig_lstat(p, b);
    tls_hook = 1;
    if (!path_is_our_log(p) && path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[lstat      ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[lstat      ] %s", p ? p : "(null)");
    int r = orig_lstat(p, b);
    tls_hook = 0;
    return r;
}

static int shim_access(const char *p, int m) {
    if (!g_armed || tls_hook) return orig_access(p, m);
    tls_hook = 1;
    if (!path_is_our_log(p) && path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[access     ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
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
    if (!path_is_our_log(p) && path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[open       ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[open       ] %s flags=0x%x", p ? p : "(null)", flags);
    int r = orig_open(p, flags, mode);
    tls_hook = 0;
    return r;
}

static FILE *shim_fopen(const char *p, const char *m) {
    if (!g_armed || tls_hook) return orig_fopen(p, m);
    tls_hook = 1;
    if (!path_is_our_log(p) && path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[fopen      ] DENY %s", p); tls_hook = 0; errno = ENOENT; return NULL; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[fopen      ] %s mode=%s", p ? p : "(null)", m ? m : "(null)");
    FILE *r = orig_fopen(p, m);
    tls_hook = 0;
    return r;
}

static DIR *shim_opendir(const char *p) {
    if (!g_armed || tls_hook) return orig_opendir(p);
    tls_hook = 1;
    if (!path_is_our_log(p) && path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[opendir    ] DENY %s", p); tls_hook = 0; errno = ENOENT; return NULL; }
    if (path_interesting(p) && g_c_file++ < CAP_FILE) probe_printf("[opendir    ] %s", p ? p : "(null)");
    DIR *r = orig_opendir(p);
    tls_hook = 0;
    return r;
}

static int shim_statfs(const char *p, struct statfs *b) {
    if (!g_armed || tls_hook) return orig_statfs(p, b);
    tls_hook = 1;
    if (!path_is_our_log(p) && path_denied(p)) { if (g_c_file++ < CAP_FILE) probe_printf("[statfs     ] DENY %s", p); tls_hook = 0; errno = ENOENT; return -1; }
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

// --- AnoSDK command channel (the actual anogs bypass) ----------------------
//
// Command set neutralised by the rival (bitmask over codes 0..0x31), plus the
// version query (14) which it answers with the expected version string.
static int shim_AnoSDKIoctl(int cmd, void *in, void *out, size_t outlen) {
    if (!g_armed || tls_hook)
        return orig_AnoSDKIoctl ? orig_AnoSDKIoctl(cmd, in, out, outlen) : 0;
    tls_hook = 1;
    int ret;
    if ((unsigned)cmd <= 0x31 && ((1ULL << cmd) & 0x2C6000E040002ULL)) {
        if (g_c_ace++ < CAP_ACE) probe_printf("[anosdk     ] cmd=%d <- neutralized (mask)", cmd);
        ret = 0;
    } else if (cmd == 14) {
        if (out && outlen >= 16) strcpy((char *)out, "7.7.58.42114");
        if (g_c_ace++ < CAP_ACE) probe_printf("[anosdk     ] cmd=14 <- version spoof");
        ret = 0;
    } else {
        ret = orig_AnoSDKIoctl ? orig_AnoSDKIoctl(cmd, in, out, outlen) : 0;
    }
    tls_hook = 0;
    return ret;
}

static long shim_ptrace(int req, int pid, void *addr, int data) {
    if (g_armed && !tls_hook && req == 31) {   // PT_DENY_ATTACH
        if (g_c_ace++ < CAP_ACE) probe_printf("[ptrace     ] PT_DENY_ATTACH -> 0");
        return 0;
    }
    return orig_ptrace ? orig_ptrace(req, pid, addr, data) : -1;
}

static const void *shim_getsegbyname(const char *segname) {
    if (g_armed && !tls_hook && g_c_ace++ < CAP_ACE)
        probe_printf("[getsegbynm ] %s", segname ? segname : "(null)");
    return orig_getsegbyname ? orig_getsegbyname(segname) : NULL;
}

static void *shim_getsegmentdata(const void *mhp, const char *segname, size_t *size) {
    if (g_armed && !tls_hook && g_c_ace++ < CAP_ACE)
        probe_printf("[getsegdata ] %s", segname ? segname : "(null)");
    return orig_getsegmentdata ? orig_getsegmentdata(mhp, segname, size) : NULL;
}

// --- code-sign / entitlement integrity spoofs ------------------------------

static int shim_SecCodeCheckValidity(void *code, uint32_t flags, void *req) {
    if (g_armed && !tls_hook) {
        if (g_c_ace++ < CAP_ACE) probe_printf("[seccode    ] SecCodeCheckValidity -> 0 (ok)");
        return 0;
    }
    return orig_SecCodeCheckValidity ? orig_SecCodeCheckValidity(code, flags, req) : 0;
}

static int shim_SecStaticCodeCheckValidity(void *code, uint32_t flags, void *req) {
    if (g_armed && !tls_hook) {
        if (g_c_ace++ < CAP_ACE) probe_printf("[seccode    ] SecStaticCodeCheckValidity -> 0 (ok)");
        return 0;
    }
    return orig_SecStaticCodeCheckValidity ? orig_SecStaticCodeCheckValidity(code, flags, req) : 0;
}

static CFStringRef shim_SecCertificateCopySubjectSummary(void *cert) {
    if (g_armed && !tls_hook) {
        if (g_c_ace++ < CAP_ACE) probe_printf("[seccert    ] subject summary spoofed");
        return CFStringCreateCopy(NULL, CFSTR("Apple Distribution: Activision Publishing, Inc. (ZEE745Z5RR)"));
    }
    return orig_SecCertificateCopySubjectSummary ? orig_SecCertificateCopySubjectSummary(cert) : NULL;
}

static CFTypeRef shim_SecTaskCopyValueForEntitlement(void *task, CFStringRef ent, CFErrorRef *err) {
    if (g_armed && !tls_hook && ent) {
        tls_hook = 1;
        CFTypeRef r = NULL;
        if      (CFEqual(ent, CFSTR("application-identifier")))                r = CFSTR("ZEE745Z5RR.com.garena.game.codm");
        else if (CFEqual(ent, CFSTR("com.apple.developer.team-identifier")))   r = CFSTR("ZEE745Z5RR");
        else if (CFEqual(ent, CFSTR("get-task-allow")))                        r = kCFBooleanFalse;
        if (r && g_c_ace++ < CAP_ACE) probe_printf("[secentitle ] spoofed entitlement");
        tls_hook = 0;
        if (r) return r;
    }
    return orig_SecTaskCopyValueForEntitlement ? orig_SecTaskCopyValueForEntitlement(task, ent, err) : NULL;
}

static int shim_csops(int pid, unsigned int ops, void *addr, size_t size) {
    if (g_armed && !tls_hook && g_c_ace++ < CAP_ACE)
        probe_printf("[csops      ] ops=0x%x (passthrough)", ops);
    return orig_csops ? orig_csops(pid, ops, addr, size) : -1;
}

static int shim_csops_audittoken(int pid, unsigned int ops, void *addr, size_t size, uint32_t *token) {
    if (g_armed && !tls_hook && g_c_ace++ < CAP_ACE)
        probe_printf("[csops      ] audittoken ops=0x%x (passthrough)", ops);
    return orig_csops_audittoken ? orig_csops_audittoken(pid, ops, addr, size, token) : -1;
}

// --- anti-cheat network packet rewriting -----------------------------------
//
// The rival scans for the 3-byte record "01 00 09" in the anti-cheat channel
// (packets beginning "01 00 00") and zeroes the leading byte. Same here.

static int styx_scrub_tokens(unsigned char *p, size_t len) {
    int n = 0;
    size_t v = 0;
    if (!p || len < 3) return 0;
    do {
        uint16_t w;
        memcpy(&w, p + v, 2);
        if (w == 1 && p[v + 2] == 9) { p[v] = 0; ++n; v += 2; }
        ++v;
    } while (v <= len - 3);
    return n;
}

static int styx_is_ace_packet(const void *buf, size_t len) {
    if (!buf || len < 3) return 0;
    const unsigned char *b = (const unsigned char *)buf;
    return b[0] == 1 && b[1] == 0 && b[2] == 0;
}

static ssize_t shim_send(int s, const void *buf, size_t len, int flags) {
    if (!orig_send) return -1;
    if (g_armed && !tls_hook && styx_is_ace_packet(buf, len)) {
        tls_hook = 1;
        void *copy = malloc(len);
        ssize_t r;
        if (copy) {
            memcpy(copy, buf, len);
            int n = styx_scrub_tokens((unsigned char *)copy, len);
            if (g_c_net++ < CAP_NET && n) probe_printf("[send       ] scrubbed %d token(s) len=%zu", n, len);
            r = orig_send(s, copy, len, flags);
            free(copy);
        } else {
            r = orig_send(s, buf, len, flags);
        }
        tls_hook = 0;
        return r;
    }
    return orig_send(s, buf, len, flags);
}

static ssize_t shim_recv(int s, void *buf, size_t len, int flags) {
    if (!orig_recv) return -1;
    ssize_t r = orig_recv(s, buf, len, flags);
    if (g_armed && !tls_hook && r >= 3 && styx_is_ace_packet(buf, (size_t)r)) {
        tls_hook = 1;
        int n = styx_scrub_tokens((unsigned char *)buf, (size_t)r);
        if (g_c_net++ < CAP_NET && n) probe_printf("[recv       ] scrubbed %d token(s) len=%zd", n, r);
        tls_hook = 0;
    }
    return r;
}

// ---------------------------------------------------------------------------
// Rebinding
// ---------------------------------------------------------------------------

static struct rebinding g_rebinds[] = {
    { "dyld_image_count",            (void *)shim_dyld_image_count,           (void **)&orig_dyld_image_count },
    { "dyld_get_image_name",         (void *)shim_dyld_get_image_name,        (void **)&orig_dyld_get_image_name },
    { "dyld_get_image_header",       (void *)shim_dyld_get_image_header,      (void **)&orig_dyld_get_image_header },
    { "dyld_get_image_vmaddr_slide", (void *)shim_dyld_get_image_vmaddr_slide, (void **)&orig_dyld_get_image_vmaddr_slide },
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
    // Rival-parity additions.
    { "AnoSDKIoctl",                  (void *)shim_AnoSDKIoctl,                (void **)&orig_AnoSDKIoctl },
    { "ptrace",                       (void *)shim_ptrace,                     (void **)&orig_ptrace },
    { "getsegbyname",                 (void *)shim_getsegbyname,               (void **)&orig_getsegbyname },
    { "getsegmentdata",               (void *)shim_getsegmentdata,             (void **)&orig_getsegmentdata },
    { "SecCodeCheckValidity",         (void *)shim_SecCodeCheckValidity,       (void **)&orig_SecCodeCheckValidity },
    { "SecStaticCodeCheckValidity",   (void *)shim_SecStaticCodeCheckValidity, (void **)&orig_SecStaticCodeCheckValidity },
    { "SecCertificateCopySubjectSummary", (void *)shim_SecCertificateCopySubjectSummary, (void **)&orig_SecCertificateCopySubjectSummary },
    { "SecTaskCopyValueForEntitlement",   (void *)shim_SecTaskCopyValueForEntitlement,   (void **)&orig_SecTaskCopyValueForEntitlement },
    { "csops",                        (void *)shim_csops,                      (void **)&orig_csops },
    { "csops_audittoken",             (void *)shim_csops_audittoken,           (void **)&orig_csops_audittoken },
    { "send",                         (void *)shim_send,                       (void **)&orig_send },
    { "recv",                         (void *)shim_recv,                       (void **)&orig_recv },
};
#define N_REBINDS (sizeof(g_rebinds) / sizeof(g_rebinds[0]))

// ---------------------------------------------------------------------------
// NSBundle metadata spoof (swizzled, matching the rival).
// ---------------------------------------------------------------------------

static IMP g_orig_bundleIdentifier = NULL;
static IMP g_orig_objectForInfoDictionaryKey = NULL;
static IMP g_orig_infoDictionary = NULL;

static id styx_bundleIdentifier(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle])
        return (__bridge id)CFSTR("com.garena.game.codm");
    return ((id (*)(id, SEL))g_orig_bundleIdentifier)(self, _cmd);
}

static id styx_objectForInfoDictionaryKey(id self, SEL _cmd, id key) {
    if (self == [NSBundle mainBundle] && [key isKindOfClass:[NSString class]]) {
        if ([key isEqualToString:@"CFBundleIdentifier"])                 return (__bridge id)CFSTR("com.garena.game.codm");
        if ([key isEqualToString:@"application-identifier"])             return (__bridge id)CFSTR("ZEE745Z5RR.com.garena.game.codm");
        if ([key isEqualToString:@"com.apple.developer.team-identifier"]) return (__bridge id)CFSTR("ZEE745Z5RR");
        if ([key isEqualToString:@"AppIdentifierPrefix"])                return (__bridge id)CFSTR("ZEE745Z5RR.");
    }
    return ((id (*)(id, SEL, id))g_orig_objectForInfoDictionaryKey)(self, _cmd, key);
}

static id styx_infoDictionary(id self, SEL _cmd) {
    id d = ((id (*)(id, SEL))g_orig_infoDictionary)(self, _cmd);
    if (self == [NSBundle mainBundle] && [d isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [d mutableCopy];
        m[@"CFBundleIdentifier"]                  = @"com.garena.game.codm";
        m[@"application-identifier"]              = @"ZEE745Z5RR.com.garena.game.codm";
        m[@"com.apple.developer.team-identifier"] = @"ZEE745Z5RR";
        m[@"AppIdentifierPrefix"]                 = @"ZEE745Z5RR.";
        return [m copy];
    }
    return d;
}

static void swizzle_nsbundle(void) {
    Class b = objc_getClass("NSBundle");
    if (!b) { probe_printf("[nbundle   ] NSBundle not found"); return; }

    Method m;
    m = class_getInstanceMethod(b, sel_registerName("bundleIdentifier"));
    if (m) { g_orig_bundleIdentifier = method_getImplementation(m); method_setImplementation(m, (IMP)styx_bundleIdentifier); }
    m = class_getInstanceMethod(b, sel_registerName("objectForInfoDictionaryKey:"));
    if (m) { g_orig_objectForInfoDictionaryKey = method_getImplementation(m); method_setImplementation(m, (IMP)styx_objectForInfoDictionaryKey); }
    m = class_getInstanceMethod(b, sel_registerName("infoDictionary"));
    if (m) { g_orig_infoDictionary = method_getImplementation(m); method_setImplementation(m, (IMP)styx_infoDictionary); }

    probe_printf("[nbundle    ] swizzled bundleIdentifier=%d objForInfoKey=%d infoDictionary=%d",
                 g_orig_bundleIdentifier != NULL, g_orig_objectForInfoDictionaryKey != NULL,
                 g_orig_infoDictionary != NULL);
}

// ---------------------------------------------------------------------------

static void rebind_all(void) {
    int rc = rebind_symbols(g_rebinds, N_REBINDS);
    probe_printf("[rebind     ] rebind_symbols (global, all images) rc=%d", rc);

    int resolved = 0;
    for (size_t i = 0; i < N_REBINDS; ++i)
        if (g_rebinds[i].replaced && *g_rebinds[i].replaced) ++resolved;
    probe_printf("[rebind     ] originals resolved: %d / %zu", resolved, N_REBINDS);
}

void styx_stealth_start(void) {
    static int started = 0;
    if (started) return;
    started = 1;

    probe_open();
    probe_printf("================ STYX ACE BYPASS (v3, rival parity) ================");

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

    // Global rebind (installs the shims in every image + an add-image callback
    // for late loads). Our shims only act once g_armed is set below.
    rebind_all();

    // Spoof app metadata (bundle id + signing identity).
    swizzle_nsbundle();

    g_armed = 1;
    probe_printf("[init       ] bypass armed. Filtering detection calls...");
    probe_printf("======================================================");
}
