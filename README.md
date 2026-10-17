# STYX_CLOUD_CODM

iOS **CODM (Garena) 1.6.58** mod engine — cloud-style build, **no jailbreak**.

Pipeline: Theos dylib (built on a GitHub macOS runner) → injected into a decrypted
IPA with `lief` → signed + installed with **Sideloadly** (free Apple ID).

## Layout
```
Makefile                 Theos library target -> libstyx.dylib (arm64, min iOS 14)
src/offsets.h            iOS RVAs + field offsets (1.6.58)
src/base.h               main-image base/slide resolve (_dyld_get_image_header)
src/mem.mm               KittyMemory-style vm_remap memory patch (no-JIT safe)
src/main.mm              __attribute__((constructor)) entry
tools/inject.py          add LC_LOAD_DYLIB + copy dylib + rezip IPA
.github/workflows/       CI: build libstyx.dylib on macos-14
```

## Build (CI)
Push to `main` → the `build` workflow produces the `styx-dylib` artifact.

## Inject + install (local, Windows)
```
gh run download -R sjuliaan/STYX_CLOUD_CODM -n styx-dylib -D out
python tools/inject.py -i "game.ipa" -d out/libstyx.dylib -o STYX_CODM.ipa
# then sign + install STYX_CODM.ipa with Sideloadly (free Apple ID)
```

## Status
- **P1 (current):** dylib loads, resolves base, probes hook targets, validates the
  no-JIT patch layer. No feature code yet.
- **P2:** Metal + UIKit ImGui overlay.
- **P3:** ESP (pawn enumerate + WorldToScreenPoint), aim assist, skip tutorial.
