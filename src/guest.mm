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
//   1. Keychain items (survives reinstall)                     <- the culprit
//   2. NSUserDefaults suite "com.itop.msdk.MSDKPIXCore" (+ std)
//   3. itop_login.txt / MSDK.mmap3 / metadatafile.bin on disk
// We delete all of them and force-close the app, mirroring the Android mod's
// unlink(persist.fallback.xml) + exit(0).
//
// CRASH FIX (v4): MSDK stores some keychain attribute *values* as NSData, not
// NSString (observed: the 3rd item in the enumeration). Calling
// CFStringGetCString() on those crashed with -[__NSCFData _getCString:...].
// Every attribute is now inspected via CFGetTypeID() and converted safely.
// ---------------------------------------------------------------------------

// Case-insensitive substring search over an explicit length (never assumes the
// buffer is NUL-terminated — keychain data blobs are arbitrary bytes).
static int mem_icontains(const char *hay, size_t hlen, const char *needle) {
    size_t nl = strlen(needle);
    if (!nl || hlen < nl) return 0;
    for (size_t i = 0; i + nl <= hlen; ++i) {
        size_t j = 0;
        while (j < nl) {
            char a = hay[i + j], b = needle[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) break;
            ++j;
        }
        if (j == nl) return 1;
    }
    return 0;
}

// Keychain account/service/label substrings that identify MSDK/Ano guest state.
static const char *const k_guest_keys[] = {
    "guest", "itop", "msdk", "uuid", "garena", "ano", NULL
};

static int keys_match(const char *s, size_t n) {
    if (!s || !n) return 0;
    for (int i = 0; k_guest_keys[i]; ++i)
        if (mem_icontains(s, n, k_guest_keys[i])) return 1;
    return 0;
}

// Type-safe keyword test for an arbitrary CFTypeRef keychain attribute (or
// dictionary key). Never dereferences a non-string as a string.
static int value_has_guest_key(CFTypeRef v) {
    if (!v) return 0;
    CFTypeID t = CFGetTypeID(v);

    if (t == CFStringGetTypeID()) {
        char buf[512];
        CFIndex used = 0;
        CFStringRef s = (CFStringRef)v;
        if (CFStringGetBytes(s, CFRangeMake(0, CFStringGetLength(s)), kCFStringEncodingUTF8,
                             0, false, (UInt8 *)buf, sizeof(buf) - 1, &used) > 0) {
            buf[used] = 0;
            return keys_match(buf, (size_t)used);
        }
        return 0;
    }

    if (t == CFDataGetTypeID()) {
        CFDataRef d = (CFDataRef)v;
        CFIndex n = CFDataGetLength(d);
        const UInt8 *p = CFDataGetBytePtr(d);
        if (n > 0 && p) {
            size_t m = (size_t)(n < 4096 ? n : 4096);
            return keys_match((const char *)p, m);
        }
        return 0;
    }

    // CFNumber / CFBoolean / anything else: describe it instead of casting it to
    // a string (this is the exact path that used to crash).
    CFStringRef d = CFCopyDescription(v);
    int r = 0;
    if (d) {
        char buf[256];
        if (CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8))
            r = keys_match(buf, strlen(buf));
        CFRelease(d);
    }
    return r;
}

static void value_to_c(CFTypeRef v, char *out, size_t n) {
    out[0] = 0;
    if (!v) return;
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)v, out, (CFIndex)n, kCFStringEncodingUTF8);
        return;
    }
    CFStringRef d = CFCopyDescription(v);
    if (d) {
        CFStringGetCString(d, out, (CFIndex)n, kCFStringEncodingUTF8);
        CFRelease(d);
    }
}

// Delete every item of `cls` whose account/service/label/generic looks like
// MSDK guest state. Runs inside codm, so it sees codm's keychain access group.
static int churn_class(CFStringRef cls) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:               (__bridge id)cls,
        (__bridge id)kSecMatchLimit:          (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes:    @YES,
        (__bridge id)kSecReturnPersistentRef: @YES,
    };

    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st != errSecSuccess || result == NULL) {
        if (result) CFRelease(result);
        return 0;
    }
    NSArray *items = (__bridge_transfer NSArray *)result;   // takes ownership

    int removed = 0;
    for (id it in items) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)it;

        CFTypeRef acct = (__bridge CFTypeRef)d[(__bridge id)kSecAttrAccount];
        CFTypeRef svc  = (__bridge CFTypeRef)d[(__bridge id)kSecAttrService];
        CFTypeRef lbl  = (__bridge CFTypeRef)d[(__bridge id)kSecAttrLabel];
        CFTypeRef gen  = (__bridge CFTypeRef)d[(__bridge id)kSecAttrGeneric];
        CFTypeRef grp  = (__bridge CFTypeRef)d[(__bridge id)kSecAttrAccessGroup];
        CFTypeRef pref = (__bridge CFTypeRef)d[(__bridge id)kSecValuePersistentRef];

        if (!value_has_guest_key(acct) && !value_has_guest_key(svc) &&
            !value_has_guest_key(lbl)  && !value_has_guest_key(gen))
            continue;

        NSMutableDictionary *del = [@{ (__bridge id)kSecClass: (__bridge id)cls } mutableCopy];
        if (pref) {
            // Delete by the exact item we just read — no value reconstruction.
            del[(__bridge id)kSecMatchItemList] = @[ (__bridge id)pref ];
        } else {
            if (acct) del[(__bridge id)kSecAttrAccount]     = (__bridge id)acct;
            if (svc)  del[(__bridge id)kSecAttrService]     = (__bridge id)svc;
            if (grp)  del[(__bridge id)kSecAttrAccessGroup] = (__bridge id)grp;
        }

        OSStatus ds = SecItemDelete((__bridge CFDictionaryRef)del);

        char a[160], s[200];
        value_to_c(acct, a, sizeof(a));
        value_to_c(svc,  s, sizeof(s));
        styx_log("[guest] kc del acct='%s' svc='%s' -> %d", a, s, (int)ds);
        if (ds == errSecSuccess) removed++;
    }
    return removed;
}

static int keychain_scrub(void) {
    int n = churn_class(kSecClassGenericPassword);
    n += churn_class(kSecClassInternetPassword);
    if (n == 0) styx_log("[guest] keychain: nothing matched");
    return n;
}

static int ns_key_match(NSString *k) {
    if (!k) return 0;
    const char *c = k.UTF8String;
    return c && keys_match(c, strlen(c));
}

// Clear the MSDK defaults suite and any guest-looking keys in the app domain.
static int defaults_scrub(void) {
    int n = 0;

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    for (NSString *k in [[std dictionaryRepresentation] allKeys]) {
        if (ns_key_match(k)) { [std removeObjectForKey:k]; n++; }
    }
    [std synchronize];

    NSString *suiteName = @"com.itop.msdk.MSDKPIXCore";
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    if (suite) {
        [suite removePersistentDomainForName:suiteName];
        [suite synchronize];
        n++;
    }
    return n;
}

static int file_scrub(void) {
    int n = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];

    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSArray *libs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,  NSUserDomainMask, YES);
    NSString *doc = docs.count ? docs[0] : nil;
    NSString *lib = libs.count ? libs[0] : nil;

    if (doc) {
        [cands addObject:[doc stringByAppendingPathComponent:@"itop_login.txt"]];
        [cands addObject:[doc stringByAppendingPathComponent:@"metadatafile.bin"]];
    }
    if (lib) {
        [cands addObject:[lib stringByAppendingPathComponent:@"itop_login.txt"]];
        [cands addObject:[lib stringByAppendingPathComponent:@"Caches/MSDK.mmap3"]];
        [cands addObject:[lib stringByAppendingPathComponent:
                           @"Preferences/com.itop.msdk.MSDKPIXCore.plist"]];
    }
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
