#!/usr/bin/env python3
"""
Inject libstyx.dylib into a decrypted CODM IPA (no jailbreak).

  - adds an LC_LOAD_DYLIB load command to every slice of the main executable
  - copies the dylib to <App>.app/Frameworks/libstyx.dylib
  - strips the now-invalid code signature (Sideloadly re-signs the whole app)

Requires: pip install lief

Usage:
  python tools/inject.py -i "com.garena.game.codm.ipa" -d out/libstyx.dylib -o STYX_CODM.ipa
"""
import argparse
import os
import plistlib
import shutil
import sys
import tempfile
import zipfile

try:
    import lief
except ImportError:
    sys.exit("lief is required:  pip install lief")

INSTALL_NAME = "@executable_path/Frameworks/libstyx.dylib"


def find_app(root):
    payload = os.path.join(root, "Payload")
    if not os.path.isdir(payload):
        sys.exit("error: no Payload/ directory in the IPA")
    for name in sorted(os.listdir(payload)):
        if name.endswith(".app"):
            return os.path.join(payload, name)
    sys.exit("error: no .app bundle inside Payload/")


def inject(binary, dylib_name):
    fat = lief.MachO.parse(binary)
    if fat is None:
        sys.exit(f"error: lief could not parse {binary}")

    n = len(fat)
    if n == 0:
        sys.exit("error: no Mach-O slices found")

    lt_dylib = lief.MachO.LoadCommand.TYPE.LOAD_DYLIB
    for i in range(n):
        bin_ = fat.at(i)
        if bin_.find_library(dylib_name) is not None:
            print(f"[*] slice {i}: {dylib_name} already present, skipping")
        else:
            # Insert as the FIRST load-dylib so our constructor runs before the
            # embedded anti-cheat frameworks (anogs/...) initialise. dyld still
            # runs our own dependencies' initializers first, so this is safe.
            first = next((idx for idx, c in enumerate(bin_.commands)
                          if c.command == lt_dylib), None)
            cmd = bin_.add_library(dylib_name)
            if first is not None:
                bin_.add(cmd, first)                      # insert a copy up front
                if not bin_.remove_command(len(bin_.commands) - 1):
                    sys.exit("error: failed to drop duplicate dylib command")
                print(f"[*] slice {i}: inserted libstyx as first dependency")
            else:
                print(f"[*] slice {i}: appended libstyx (no existing LOAD_DYLIB)")
        if bin_.has_code_signature:
            bin_.remove_signature()
    fat.write(binary)
    return n


def enable_file_sharing(app_dir):
    """Expose the app's Documents/ folder in the Files app so the probe log
    (Documents/styx_ace.log) can be pulled off the device without a jailbreak."""
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
    ap.add_argument("-d", "--dylib", required=True, help="libstyx.dylib to inject")
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
        binary = os.path.join(app, args.binary or app_name)
        if not os.path.isfile(binary):
            sys.exit(f"error: executable not found: {binary}")

        print(f"[*] injecting {INSTALL_NAME} into {os.path.relpath(binary, td)}")
        slices = inject(binary, INSTALL_NAME)
        print(f"[*] patched {slices} Mach-O slice(s)")

        fw = os.path.join(app, "Frameworks")
        os.makedirs(fw, exist_ok=True)
        dst = os.path.join(fw, "libstyx.dylib")
        shutil.copyfile(args.dylib, dst)
        print(f"[*] copied dylib -> {os.path.relpath(dst, td)}")

        plist = enable_file_sharing(app)
        print(f"[*] enabled file sharing in {os.path.relpath(plist, td)}")

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
