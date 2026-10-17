#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdarg.h>

static FILE *styx_log_fp = NULL;

static inline void styx_log_open(void) {
    if (styx_log_fp) return;
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = paths.count ? paths[0] : NSTemporaryDirectory();
        NSString *path = [dir stringByAppendingPathComponent:@"styx.log"];
        styx_log_fp = fopen(path.UTF8String, "a");
    }
}

static inline void styx_log(const char *fmt, ...) {
    styx_log_open();
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (styx_log_fp) { fprintf(styx_log_fp, "%s\n", buf); fflush(styx_log_fp); }
    fprintf(stderr, "[styx] %s\n", buf);
}
