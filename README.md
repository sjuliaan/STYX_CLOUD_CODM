# STYX_CLOUD_CODM

iOS **CODM (Garena) 1.6.58** mod engine — cloud-style build, **no jailbreak**.

Pipeline: Theos dylib (built on a GitHub macOS runner) → injected into a decrypted
IPA with `lief` → signed + installed with **Sideloadly** (free Apple ID).

## Layout
```
Makefile                 Theos library target -> GPMGameCore.dylib (arm64, min iOS 14)
src/offsets.h            iOS RVAs + field offsets (1.6.58)
src/base.h               main-image base/slide resolve (_dyld_get_image_header)
src/mem.mm               KittyMemory-style vm_remap memory patch (no-JIT safe)
src/main.mm              __attribute__((constructor)) entry
src/stealth.mm           ACE bypass: fishhook + chained-fixup got-scan, anogs kill
src/gotrebind.cpp        chained-fixup-safe __got/__la_symbol_ptr rebinding
tools/inject.py          append dep to APMDeviceInfoSupport + ship framework + rezip
.github/workflows/       CI: build GPMGameCore.dylib on macos-14
```

## Build (CI)
Push to `main` → the `build` workflow produces the **`gpmgamecore-dylib`** artifact
(a single `GPMGameCore.dylib`).

## Inject + install (local, Windows)
```
gh run download -R sjuliaan/STYX_CLOUD_CODM -n gpmgamecore-dylib -D out
python tools/inject.py -i "com.garena.game.codm_1.6.58_und3fined.ipa" \
                       -d out/GPMGameCore.dylib -o STYX_CODM.ipa
# then sign + install STYX_CODM.ipa with Sideloadly (free Apple ID)
```

`inject.py` never modifies the `codm` executable: it appends
`@rpath/GPMGameCore.framework/GPMGameCore` as the last dependency of
`Frameworks/APMDeviceInfoSupport_dylib.framework/APMDeviceInfoSupport_dylib`
(so no bind ordinals shift), drops our dylib into
`Frameworks/GPMGameCore.framework/`, and enables Files app access.

## On-device verification
Launch once, then open Files → **On My iPhone → CODM → `GPMGameCore.probe`**.
Expected at boot:
```
[rebind     ] originals resolved: 15 / 20
[selftest   ] dyld count real=N seen=N-1 (idx <last>)
```
The 5 `MISS` lines (`ptrace`, `getsegbyname`, `getsegmentdata`,
`SecCodeCheckValidity`, `SecStaticCodeCheckValidity`) are expected: no embedded
image imports them. Never touch `codm` itself or dyld aborts on ordinal shifts.

## Status
- Stealth: ACE bypass v4 (rival parity) + real `__dyld_*` hooks + chained-fixup
  `__got` scan + anogs detector memo kill (data-only).
- Features: ESP, aim assist, skip tutorial, guest-account scrub.
