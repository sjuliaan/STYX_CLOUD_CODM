#!/usr/bin/env python3
"""
Inject the GPMGameCore dylib into a decrypted CODM IPA (no jailbreak) WITHOUT
touching the main executable.

Technique (mirrors the reference mod exactly):

  * The main executable `codm` binds its imports by dylib ORDINAL (it uses
    LC_DYLD_CHAINED_FIXUPS and references ordinals 1..122). Inserting a new
    load command into codm renumbers every ordinal >= the insertion point and
    makes dyld abort at launch ("Symbol not found: _sqlite3_bind_blob"). So we
    NEVER modify codm.
  * Instead we APPEND `@rpath/GPMGameCore.framework/GPMGameCore` as the LAST
    dependency of the existing framework
        Frameworks/APMDeviceInfoSupport_dylib.framework/APMDeviceInfoSupport_dylib
    (codm ordinal 40). Appending at the end shifts none of that host's own
    ordinals, and codm is left byte-identical.
  * The dylib is shipped inside a `.framework` wrapper under
    Frameworks/GPMGameCore.framework/ and resolved via codm's existing
    `@executable_path/Frameworks` rpath (so `@rpath/...` maps to it).

Requires: pip install lief

Usage:
  python tools/inject.py -i "com.garena.game.codm.ipa" -d out/GPMGameCore.dylib -o STYX_CODM.ipa
"""
import argparse
import hashlib
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import zipfile

try:
    import lief
except ImportError:
    sys.exit("lief is required:  pip install lief")

# Host framework that gets the extra dependency (codm ordinal 40).
HOST_REL = "Frameworks/APMDeviceInfoSupport_dylib.framework/APMDeviceInfoSupport_dylib"
# Our framework wrapper + the dependency path codm's @executable_path/Frameworks
# rpath resolves to. Named to blend with the game's own GPM*/APM* frameworks.
FW_DIR = "Frameworks/GPMGameCore.framework"
FW_BIN = "GPMGameCore"
DEP_PATH = "@rpath/GPMGameCore.framework/GPMGameCore"

FW_INFO = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": FW_BIN,
    "CFBundleIdentifier": "com.garena.gpm.gamecore",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": FW_BIN,
    "CFBundlePackageType": "FMWK",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "MinimumOSVersion": "15.0",
    "UIDeviceFamily": [1, 2],
}


def find_app(root):
    payload = os.path.join(root, "Payload")
    if not os.path.isdir(payload):
        sys.exit("error: no Payload/ directory in the IPA")
    for name in sorted(os.listdir(payload)):
        if name.endswith(".app"):
            return os.path.join(payload, name)
    sys.exit("error: no .app bundle inside Payload/")


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_dylibs(binary):
    """Return the ordered list of LC_LOAD_DYLIB names in a Mach-O (raw parse)."""
    with open(binary, "rb") as f:
        d = f.read()
    magic = struct.unpack_from("<I", d, 0)[0]
    if magic not in (0xFEEDFACF, 0xFEEDFACD):  # arm64 / x86_64
        sys.exit(f"error: not a thin 64-bit Mach-O: {binary}")
    ncmds, _ = struct.unpack_from("<2I", d, 16)
    off, names = 32, []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from("<2I", d, off)
        if cmd == 0xC:  # LC_LOAD_DYLIB
            no = struct.unpack_from("<I", d, off + 8)[0]
            e = d.index(b"\0", off + no, off + cs)
            names.append(d[off + no:e].decode("utf8", "replace"))
        off += cs
    return names


def patch_host(host, dep):
    """Append `dep` as the last LC_LOAD_DYLIB of the host framework binary."""
    before = load_dylibs(host)
    if dep in before:
        print(f"[*] host already depends on {dep}; leaving as-is")
        return before, before

    fat = lief.MachO.parse(host)
    if fat is None:
        sys.exit(f"error: lief could not parse {host}")
    for i in range(len(fat)):
        b = fat.at(i)
        b.add_library(dep)  # appended at the end of the load-command list
        if b.has_code_signature:
            b.remove_signature()
    fat.write(host)

    after = load_dylibs(host)
    return before, after


def verify(host, dep, before, after, codm, codm_md5):
    ok = True
    if after != before + [dep]:
        print(f"[!] FAIL: host dylib list = {after} (expected {before} + [{dep}])")
        ok = False
    if md5(codm) != codm_md5:
        print("[!] FAIL: codm main executable was modified!")
        ok = False
    if dep in load_dylibs(codm):
        print("[!] FAIL: codm references our dylib (ordinals would shift)!")
        ok = False
    if not ok:
        sys.exit("error: post-injection verification failed")
    print("[+] verify: codm untouched; host gained exactly one dep at the end")


def enable_file_sharing(app_dir):
    """Expose Documents/ in the Files app so the on-device log can be pulled off."""
    p = os.path.join(app_dir, "Info.plist")
    with open(p, "rb") as f:
        info = plistlib.load(f)
    info["UIFileSharingEnabled"] = True
    info["LSSupportsOpeningDocumentsInPlace"] = True
    with open(p, "wb") as f:
        plistlib.dump(info, f)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--ipa", required=True, help="decrypted input IPA")
    ap.add_argument("-d", "--dylib", required=True, help="built GPMGameCore.dylib")
    ap.add_argument("-o", "--out", required=True, help="output IPA path")
    ap.add_argument("--binary", default=None, help="executable name (default: app name)")
    args = ap.parse_args()

    if not os.path.isfile(args.ipa):
        sys.exit(f"error: IPA not found: {args.ipa}")
    if not os.path.isfile(args.dylib):
        sys.exit(f"error: dylib not found: {args.dylib}")

    with tempfile.TemporaryDirectory() as td:
        print(f"[*] extracting {args.ipa}")
        with zipfile.ZipFile(args.ipa) as z:
            z.extractall(td)

        app = find_app(td)
        app_name = os.path.basename(app)[:-4]
        codm = os.path.join(app, args.binary or app_name)
        if not os.path.isfile(codm):
            sys.exit(f"error: executable not found: {codm}")
        codm_md5 = md5(codm)

        host = os.path.join(app, HOST_REL)
        if not os.path.isfile(host):
            sys.exit(f"error: host framework not found: {host}")

        # 1. Append our dependency to the host framework (never touch codm).
        before, after = patch_host(host, DEP_PATH)
        print(f"[*] host deps {len(before)} -> {len(after)} (appended {DEP_PATH})")

        # 2. Drop the host framework's now-stale signature envelope.
        csig = os.path.join(os.path.dirname(host), "_CodeSignature")
        if os.path.isdir(csig):
            shutil.rmtree(csig)
            print("[*] removed stale _CodeSignature from host framework")

        # 3. Ship the dylib inside Frameworks/GPMGameCore.framework/.
        fw = os.path.join(app, FW_DIR)
        os.makedirs(fw, exist_ok=True)
        shutil.copyfile(args.dylib, os.path.join(fw, FW_BIN))
        with open(os.path.join(fw, "Info.plist"), "wb") as f:
            plistlib.dump(FW_INFO, f)
        print(f"[*] wrote {os.path.relpath(fw, td)}/{FW_BIN} + Info.plist")

        # 4. Files-app access for the on-device log.
        plist = enable_file_sharing(app)
        print(f"[*] enabled file sharing in {os.path.relpath(plist, td)}")

        # 5. Prove nothing shifted.
        verify(host, DEP_PATH, before, after, codm, codm_md5)

        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        if os.path.exists(args.out):
            os.remove(args.out)
        print(f"[*] repacking -> {args.out}")
        with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED) as z:
            for root, _, files in os.walk(td):
                for f in files:
                    full = os.path.join(root, f)
                    z.write(full, os.path.relpath(full, td))

    print("[+] done")


if __name__ == "__main__":
    main()
