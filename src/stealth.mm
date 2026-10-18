// stealth.mm — ACE detection bypass (v4, full rival parity).
//
// Recon of the rival dylib (Cloud_CODM 1.6.57) gave its complete stealth stack;
// this now matches it behaviour-for-behaviour:
//
//   dyld enumeration     -> hide our own image (count/name/header/slide); our
//                           slot is skipped by index remap
//   dladdr               -> present a DECOY system path (not NULL) for our image
//   main-binary cryptid  -> patch LC_ENCRYPTION_INFO_64 (cryptsize=0x1000,
//                           cryptid=1) so an in-memory integrity read looks
//                           like an untouched App-Store binary
//   getsegbyname         -> return a FAKED __LINKEDIT segment (vmsize/filesize
//   getsegmentdata          = 0x86CE50), matching the rival's constants
//   AnoSDKIoctl          -> return 0 for a fixed command set; spoof the
//                           version query (cmd 14) with "7.7.58.42114"
//   SecCode/SecStaticCode-> return 0 (valid)
//   SecCertificateCopy   -> spoof "Apple Distribution: Activision ..."
//   SecTaskCopyValue     -> spoof application-identifier / team-id / get-task-allow
//   sysctl / sysctlbyname-> scrub P_TRACED, zero the {KERN,14} probe
//   ptrace               -> PT_DENY_ATTACH (31) returns 0
//   csops / csops_audit  -> passthrough (inert parity)
//   send / recv          -> rewrite anti-cheat packets ("01 00 09" -> "00 00 09")
//   NSBundle methods     -> spoof bundle id / signing identity (swizzled)
//
// Hook surface is trimmed to the rival's exact set (no task_info / file-op hooks).
//
// fishhook compares `&symbol_name[1]` (i.e. the name with the binary's leading
// underscore stripped) to the rebind name, so names here must NOT start with '_'.
//
// NOTE: `[rebind] originals resolved: N / M` in GPMGameCore.probe confirms
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
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>

#include "fishhook.h"

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
        NSString *path = [dir stringByAppendingPathComponent:@"GPMGameCore.probe"];
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
static char *(*orig_getenv)(const char *)                                      = NULL;

static int  (*orig_AnoSDKIoctl)(int, void *, void *, size_t)                   = NULL;
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

static uint32_t g_c_dyld = 0, g_c_sys = 0, g_c_env = 0, g_c_ace = 0, g_c_net = 0;
#define CAP_DYLD   600u
#define CAP_SYS    400u
#define CAP_ENV    200u
#define CAP_ACE    200u
#define CAP_NET    200u

// Our own image, so the ACE cannot enumerate us via dyld or dladdr.
static int   g_our_index  = -1;      // _dyld index of our framework dylib
static void *g_our_header = NULL;    // its mach_header

// Remap a caller-supplied dyld index so our image is invisible (the reported
// list is simply shifted down by one after our slot).
static inline uint32_t styx_dyld_remap(uint32_t idx) {
    if (g_our_index >= 0 && idx >= (uint32_t)g_our_index) return idx + 1;
    return idx;
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

// Decoy path the rival feeds dladdr for its own image (recovered from its
// obfuscated constant). Keeps a valid code address resolvable to a plausible
// system dylib instead of returning NULL.
static const char *const k_decoy_path = "/usr/lib/system/libsystem_c.dylib";

static int shim_dladdr(const void *addr, Dl_info *info) {
    if (!g_armed || tls_hook) return orig_dladdr(addr, info);
    tls_hook = 1;
    int r = orig_dladdr(addr, info);
    if (r && info && g_our_header && info->dli_fbase == g_our_header) {
        info->dli_fname = k_decoy_path;   // decoy (not NULL) — rival parity
        info->dli_sname = NULL;
        info->dli_saddr = NULL;
        if (g_c_dyld++ < CAP_DYLD) probe_printf("[dladdr     ] decoy path for %p", addr);
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
    int flag = n && (strstr(n, "kern.proc") || strstr(n, "kern.argmax") ||
                     strstr(n, "hw.machine") || strstr(n, "model"));
    if (g_c_sys++ < CAP_SYS)
        probe_printf("[sysctlbynm ] %s%s", n ? n : "(null)",
                     flag ? "   <<< model / proc query" : "");
    int r = orig_sysctlbyname(n, oldp, oldlenp, newp, newlen);
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

// --- faked __LINKEDIT + main-binary cryptid (rival parity) -----------------

#define STYX_LINKEDIT_FAKE_SIZE 0x86CE50ULL   // rival's constant (8834640)

static struct segment_command_64 g_fake_linkedit;
static int g_have_fake_linkedit = 0;

// Cache image 0's real __LINKEDIT command and override vmsize/filesize, exactly
// like the rival does, so getsegbyname()/getsegmentdata() report a benign size.
static void styx_cache_linkedit(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh || mh->magic != MH_MAGIC_64) return;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
            if (strncmp(seg->segname, "__LINKEDIT", 10) == 0) {
                g_fake_linkedit = *seg;
                g_fake_linkedit.vmsize   = STYX_LINKEDIT_FAKE_SIZE;
                g_fake_linkedit.filesize = STYX_LINKEDIT_FAKE_SIZE;
                g_have_fake_linkedit = 1;
                probe_printf("[linkedit   ] cached __LINKEDIT (vmsize/filesize -> 0x%llx)",
                             (unsigned long long)STYX_LINKEDIT_FAKE_SIZE);
                return;
            }
        }
        if (lc->cmdsize == 0) break;
        p += lc->cmdsize;
    }
}

// Patch image 0's LC_ENCRYPTION_INFO_64 in place (VM_COPY so the private copy is
// writable, exactly the rival's primitive): cryptsize = 0x1000, cryptid = 1.
static void styx_patch_cryptid(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh || mh->magic != MH_MAGIC_64) return;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_ENCRYPTION_INFO_64) {
            struct encryption_info_command_64 *ei = (struct encryption_info_command_64 *)p;
            if (ei->cryptid == 1 && ei->cryptsize == 0x1000) {
                probe_printf("[cryptid    ] already cryptid=1/cryptsize=0x1000");
                return;
            }
            long ps = getpagesize();
            vm_address_t page = (vm_address_t)ei & ~((vm_address_t)ps - 1);
            vm_size_t span = (vm_size_t)(((uint8_t *)ei + sizeof(*ei)) - (uint8_t *)page);
            kern_return_t kr = vm_protect(mach_task_self(), page, span, 0,
                                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr == KERN_SUCCESS) {
                ei->cryptsize = 0x1000;
                ei->cryptid   = 1;
                probe_printf("[cryptid    ] patched LC_ENCRYPTION_INFO_64 (cryptid -> 1)");
            } else {
                probe_printf("[cryptid    ] vm_protect failed kr=%d", (int)kr);
            }
            return;
        }
        if (lc->cmdsize == 0) break;
        p += lc->cmdsize;
    }
}

static const void *shim_getsegbyname(const char *segname) {
    if (g_armed && !tls_hook && g_have_fake_linkedit && segname &&
        strcmp(segname, "__LINKEDIT") == 0) {
        if (g_c_ace++ < CAP_ACE) probe_printf("[getsegbynm ] __LINKEDIT -> faked seg");
        return &g_fake_linkedit;
    }
    return orig_getsegbyname ? orig_getsegbyname(segname) : NULL;
}

static void *shim_getsegmentdata(const void *mhp, const char *segname, size_t *size) {
    if (g_armed && !tls_hook && g_have_fake_linkedit && segname &&
        strcmp(segname, "__LINKEDIT") == 0) {
        void *r = orig_getsegmentdata ? orig_getsegmentdata(mhp, segname, size) : NULL;
        if (size) *size = (size_t)STYX_LINKEDIT_FAKE_SIZE;
        if (g_c_ace++ < CAP_ACE)
            probe_printf("[getsegdata ] __LINKEDIT -> size 0x%llx",
                         (unsigned long long)STYX_LINKEDIT_FAKE_SIZE);
        return r;
    }
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
// Rebinding (trimmed to the rival's exact symbol set).
// ---------------------------------------------------------------------------

static struct rebinding g_rebinds[] = {
    { "dyld_image_count",            (void *)shim_dyld_image_count,           (void **)&orig_dyld_image_count },
    { "dyld_get_image_name",         (void *)shim_dyld_get_image_name,        (void **)&orig_dyld_get_image_name },
    { "dyld_get_image_header",       (void *)shim_dyld_get_image_header,      (void **)&orig_dyld_get_image_header },
    { "dyld_get_image_vmaddr_slide", (void *)shim_dyld_get_image_vmaddr_slide, (void **)&orig_dyld_get_image_vmaddr_slide },
    { "dladdr",                       (void *)shim_dladdr,                      (void **)&orig_dladdr },
    { "sysctl",                       (void *)shim_sysctl,                     (void **)&orig_sysctl },
    { "sysctlbyname",                 (void *)shim_sysctlbyname,               (void **)&orig_sysctlbyname },
    { "getenv",                       (void *)shim_getenv,                     (void **)&orig_getenv },
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

    // Per-name resolution, so a silently-missing symbol is obvious in the log.
    for (size_t i = 0; i < N_REBINDS; ++i)
        if (!(g_rebinds[i].replaced && *g_rebinds[i].replaced))
            probe_printf("[rebind     ]   MISS %s", g_rebinds[i].name);
}

void styx_stealth_start(void) {
    static int started = 0;
    if (started) return;
    started = 1;

    probe_open();
    probe_printf("================ STYX ACE BYPASS (v4, rival parity) ================");

    // Locate our own image so the ACE cannot enumerate us. Done before arming,
    // so dladdr/_dyld_* are still the real ones.
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

    // Integrity parity: patch the main binary's encryption info + cache a faked
    // __LINKEDIT before any of the anti-cheat's own code runs.
    styx_patch_cryptid();
    styx_cache_linkedit();

    // Global rebind (installs the shims in every image + an add-image callback
    // for late loads). Our shims only act once g_armed is set below.
    rebind_all();

    // Spoof app metadata (bundle id + signing identity).
    swizzle_nsbundle();

    g_armed = 1;
    probe_printf("[init       ] bypass armed. Filtering detection calls...");
    probe_printf("======================================================");
}
