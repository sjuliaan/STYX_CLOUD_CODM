#include "guest.h"
#include "styxlog.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Guest-account scrub (iOS).
//
// MSDKPIXCore stores the guest identity in three places:
//   1. Keychain generic-password items (survives reinstall)  <- the culprit
//   2. NSUserDefaults suite "com.itop.msdk.MSDKPIXCore" (+ standard defaults)
//   3. Documents/itop_login.txt
// We delete all of them and force-close the app, mirroring the Android mod's
// unlink(persist.fallback.xml) + exit(0).
// ---------------------------------------------------------------------------

static int icontains(const char *hay, const char *needle) {
    if (!hay || !needle) return 0;
    size_t nl = strlen(needle);
    if (!nl) return 1;
    for (const char *p = hay; *p; ++p) {
        size_t i = 0;
        while (i < nl && p[i]) {
            char a = p[i], b = needle[i];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) break;
            ++i;
        }
        if (i == nl) return 1;
    }
    return 0;
}

// Keychain account/service substrings that identify MSDK/Ano guest state.
static const char *const k_guest_keys[] = {
    "guest", "itop", "msdk", "uuid", "garena", "ano", NULL
};

static int guest_key_match(CFStringRef s) {
    if (!s) return 0;
    char buf[256];
    if (!CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) return 0;
    for (int i = 0; k_guest_keys[i]; ++i)
        if (icontains(buf, k_guest_keys[i])) return 1;
    return 0;
}

static void cf_to_c(CFStringRef s, char *out, size_t n) {
    out[0] = 0;
    if (s) CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8);
}

// Enumerate and delete every generic-password item whose account or service
// looks like MSDK guest state. Entitlement-scoped: our dylib runs inside codm,
// so it shares codm's keychain access group and can see those items.
static int keychain_scrub(void) {
    int removed = 0;

    NSDictionary *query = @{
        (__bridge id)kSecClass:            (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit:       (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
    };

    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st != errSecSuccess || result == NULL) {
        styx_log("[guest] keychain enumerate -> OSStatus %d (nothing to do)", (int)st);
        if (result) CFRelease(result);
        return 0;
    }
    NSArray *items = (__bridge_transfer NSArray *)result;   // takes ownership

    for (NSDictionary *it in items) {
        CFStringRef acct = (__bridge CFStringRef)it[(__bridge id)kSecAttrAccount];
        CFStringRef svc  = (__bridge CFStringRef)it[(__bridge id)kSecAttrService];
        CFStringRef grp  = (__bridge CFStringRef)it[(__bridge id)kSecAttrAccessGroup];

        if (!guest_key_match(acct) && !guest_key_match(svc)) continue;

        NSMutableDictionary *del = [@{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword
        } mutableCopy];
        if (acct) del[(__bridge id)kSecAttrAccount]     = (__bridge id)acct;
        if (svc)  del[(__bridge id)kSecAttrService]     = (__bridge id)svc;
        if (grp)  del[(__bridge id)kSecAttrAccessGroup] = (__bridge id)grp;

        OSStatus ds = SecItemDelete((__bridge CFDictionaryRef)del);

        char a[128], s[192];
        cf_to_c(acct, a, sizeof(a));
        cf_to_c(svc,  s, sizeof(s));
        styx_log("[guest] keychain del acct='%s' svc='%s' -> %d", a, s, (int)ds);
        if (ds == errSecSuccess) removed++;
    }
    return removed;
}

// Clear the MSDK defaults suite and any guest-looking keys in the app domain.
static int defaults_scrub(void) {
    int n = 0;

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    for (NSString *k in [[std dictionaryRepresentation] allKeys]) {
        if (guest_key_match((__bridge CFStringRef)k)) {
            [std removeObjectForKey:k];
            n++;
        }
    }
    [std synchronize];

    NSUserDefaults *suite =
        [[NSUserDefaults alloc] initWithSuiteName:@"com.itop.msdk.MSDKPIXCore"];
    if (suite) {
        [suite removePersistentDomainForName:@"com.itop.msdk.MSDKPIXCore"];
        [suite synchronize];
        n++;
    }
    return n;
}

static int file_scrub(void) {
    int n = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];

    for (NSString *d in NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES))
        [cands addObject:[d stringByAppendingPathComponent:@"itop_login.txt"]];
    NSString *lib = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    if (lib) [cands addObject:[lib stringByAppendingPathComponent:@"itop_login.txt"]];
    [cands addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"itop_login.txt"]];

    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p] && [fm removeItemAtPath:p error:NULL]) {
            styx_log("[guest] removed file %@", p);
            n++;
        }
    }
    return n;
}

void styx_reset_guest_account(void) {
    styx_log("[guest] === reset guest: scrubbing persisted MSDK state ===");
    int k = keychain_scrub();
    int d = defaults_scrub();
    int f = file_scrub();
    styx_log("[guest] keychain=%d defaults=%d files=%d -> exit(0)", k, d, f);
    exit(0);
}
