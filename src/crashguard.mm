#include "crashguard.h"

#include <signal.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <ucontext.h>
#include <mach/mach.h>
#import <Foundation/Foundation.h>

static int  g_crash_fd = -1;
static char g_altstack[65536];

static void styx_crash_open(void) {
    if (g_crash_fd >= 0) return;
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES);
        NSString *dir = paths.count ? paths[0] : NSTemporaryDirectory();
        NSString *path = [dir stringByAppendingPathComponent:@"styx_crash.log"];
        g_crash_fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
}

static void styx_crash_write(const char *s) {
    if (g_crash_fd < 0 || !s) return;
    ssize_t n = write(g_crash_fd, s, strlen(s));
    (void)n;
}

static void styx_sig_handler(int sig, siginfo_t *si, void *uap) {
    uintptr_t pc = 0, lr = 0, sp = 0, far = 0, fp = 0;
    if (uap) {
        ucontext_t *uc = (ucontext_t *)uap;
        pc  = (uintptr_t)uc->uc_mcontext->__ss.__pc;
        lr  = (uintptr_t)uc->uc_mcontext->__ss.__lr;
        sp  = (uintptr_t)uc->uc_mcontext->__ss.__sp;
        fp  = (uintptr_t)uc->uc_mcontext->__ss.__fp;
        far = (uintptr_t)uc->uc_mcontext->__es.__far;
    }
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "[CRASH] sig=%d addr=%p pc=%p lr=%p sp=%p fp=%p far=%p\n",
                     sig, si ? si->si_addr : NULL,
                     (void *)pc, (void *)lr, (void *)sp, (void *)fp, (void *)far);
    if (n > 0) styx_crash_write(buf);

    signal(sig, SIG_DFL);
    raise(sig);
}

void styx_crashguard_install(void) {
    styx_crash_open();

    stack_t ss;
    memset(&ss, 0, sizeof(ss));
    ss.ss_sp    = g_altstack;
    ss.ss_size  = sizeof(g_altstack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = styx_sig_handler;
    sa.sa_flags     = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);

    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
}
