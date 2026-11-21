# Complete native SDK preview

The requested distribution is a compiled CLI with every tool and target asset
needed for supported AOT/JIT builds. It must run without installing Python,
PowerShell, Docker, make or a separate cross compiler. Producer-side CI may use
build scripts; those scripts are not the delivered build pipeline.

An earlier Docker-based frontend was not this deliverable, was never released
and has been removed. The first source preview is historical, not a complete
native SDK.

## Established evidence

- Preview.3 and earlier use the 32-patch tree at
  `7eb1156c65309c5c531b82f409ae242c06a33b29`. Preview.4 adds patch 0033
  (`Uri.base` for CTR), giving the 33-patch tree at
  `b1056c03eab479934538c293da82d356de11bab2`. The evidence below was gathered
  on the 32-patch tree.
- After preview.4, patch 0034 (`ctr-io-port`) ports the SDK's I/O layer
  (`runtime/bin`) to CTR as a new host OS. Both target graphs build a
  `runtime/bin/ctr:dart_io` archive, which the runtime freeze exports as
  `lib/<mode>/io.a` (`io_archive` in `runtime.json`). Every OS area is still a
  stub that fails with `OSError` (`ENOSYS`, "<Area> is not supported on CTR
  (dart:io)"); secure sockets use the upstream unsupported variant. The 34-patch
  tree is `89f8823f45bbf805abc062c24f8a3b33e896ddeb`. The launcher does not link
  the archive yet.
- Runtime loader spike (2026-11-21, New 3DS, Luma3DS 13.5): **go**. The prototype
  in `runtime/ctr/test/loader` loaded a devkitARM `-shared -fPIC` object from
  the SD card, applied `R_ARM_RELATIVE`, `ABS32`, `GLOB_DAT` and `JUMP_SLOT`
  relocations, ran `.init_array`, flushed caches with Luma's SVC 0x80 and made
  the text read-execute with `svcControlProcessMemory`. Calls into the object,
  callbacks into the app, libc and libgcc imports and hard-float arguments all
  worked; a TLS relocation was rejected by name. `DynamicLibrary.open` will
  therefore use a real runtime loader rather than the link-time fallback.
- The SDK can now carry a C/C++ compiler for CTR: `bin/ctr-clang` (unmodified
  LLVM clang 23.1.5, Apache-2.0 WITH LLVM-exception), its resource headers, and
  CTR target headers (newlib, libstdc++ and libctru headers from the same
  devkitPro install as the frozen libraries; no devkitPro host tools).
  `release/native_clang.py --target <host>` produces clang per host from the pins
  in `release/clang-source.json`: official LLVM archives for windows-x64 and
  macos-arm64, and a clang-only, ARM-only build from the pinned source for
  linux-x64 (the official Linux archive needs `libstdc++` and `libz`, which the
  SDK dependency policy rejects) and macos-x64 (LLVM publishes no Intel macOS
  archive). `--headers` produces the header component. `sdk.json`
  `native_compiler` records the triple, flags and include order; integer-type
  macros come from GCC so headers, C++ mangling and the prebuilt libraries agree.
  `build_native_sdk.py --clang --headers` compiles a C and a C++ sample from the
  extracted SDK and links them with `ctr-ld`. On 2026-11-21 the linux-x64 SDK
  passed that check and its linked sample matched the windows-x64 one byte for
  byte.
- The compiled Linux SDK built hello, async, GC stress, exceptions and focused
  numerics in both AOT and JIT modes. Networking was disabled, the SDK mount was
  read-only, no source SDK checkout was mounted and PATH contained only bundled
  tools. These ten build receipts are separate from target execution evidence.
- A host-only GN graph generated successfully without SDK source edits, using
  native `current_os`/`current_cpu` with CTR target OS and explicit ARMv6K Dart
  target architecture. Its definitions contain `TARGET_ARCH_ARM`,
  `DART_TARGET_OS_CTR` and `DART_TARGET_ARMV6K`. Windows, Intel Mac and Apple
  Silicon precompiler CI builds have passed. The final producers record their
  native-only sort and target-alignment inputs separately from the SDK32 base;
  the target runtime and patch queue remain unchanged.
- Exported target assets occupy 52,966,338 bytes after removing debug sections.
  Original archives remain unchanged. Both modes passed actual native-offset
  checks: 483 AOT and 486 JIT constants, with zero mismatches. Target C++ assertions
  establish the 32-byte Program structure and its eight 32-bit fields.
- The independent Dart ELF-to-3DSX encoder matches the reference converter byte
  for byte on all ten newly linked ELF inputs.
- Real native CLI checks passed for both modes in paths with spaces, invalid
  source without publication, preserving existing outputs and resolving a local
  package dependency offline using the bundled Dart resolver.
- A fresh hello AOT built and staged by the native CLI ran in Azahar 2126.2,
  printed `hello:42`, passed cleanup and emitted a matching terminal record.
  The initial staging attempt exposed a configuration-field ordering defect,
  which was corrected before this pass. No JIT emulator or new
  physical-console execution pass is claimed here.
- Independent GNU assembler/linker CI builds passed for all four native hosts.
  The complete Linux bundle passed native dependency inspection; its tools use
  standard glibc components only. The release baseline is glibc 2.36 or newer.

The generated precompiler snapshot hash is
`c5e274828bf37a90359bd3b0753e3eb2`, with SDK short hash `7eb1156c65` on the
32-patch tree and `b1056c03ea` on the 33-patch tree. Patch 0033 changes only
Dart library code, so the snapshot hash is unchanged, but the SDK hash is not:
kernel compilers and `gen_snapshot` must be rebuilt with the runtime.
No stock hash is substituted. Producer graph changes must preserve these
identities and still require generated-code/runtime compatibility checks.

## Delivery components

Each native host bundle needs the compiled CLI, CTR kernel compiler, CTR
`gen_snapshot`, GNU ARM assembler/linker, a native dependency resolver, and
prebuilt platform/runtime/launcher/startup/math/library assets. The converter
is implemented in the compiled Dart CLI. Build arguments use explicit bundled
paths; recipient machines must not supply an interpreter or compiler.

From 0.1.0-preview.4 the compiled CLI is `dartbrew`, built from
`packages/dartbrew`, and each download is named
`dartbrew-<version>-<host>.zip`. `dartbrew compile` replaces the `ctr build`
command of earlier previews; their evidence below was recorded with that
command. Producer component artifacts (`ctr-runtime-assets.zip`,
`ctr-native-precompiler-*`, `ctr-binutils-*`, `source-ctr-binutils-*`) keep their
target names. To rerun the real CLI checks against an extracted SDK, set
`DARTBREW_NATIVE_SDK` to its folder and run
`release/test/test_native_sdk_integration.py`.

Native host tools are built separately for Windows x64, Linux x64, macOS Intel
and Apple Silicon. Runtime assets can be shared across hosts, with per-mode
compatibility identities retained. A host executable smoke test is distinct
from an offline source-to-3DSX build and from actual target execution.

## Building host tools locally on Windows

`release/native_precompiler.py` runs on a Windows workstation as well as in CI.
Match the CI job (`.github/workflows/native-precompiler.yml`):

- Install the Windows SDK pinned in `release/native-windows-sdk.json`; the Dart
  toolchain helper looks for that exact version.
- Set `DEPOT_TOOLS_WIN_TOOLCHAIN=0` and `PYTHONUTF8=1`. Pass
  `core.longpaths=true` and `core.autocrlf=false` to git, for example through
  `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`, rather than
  changing global configuration.
- When several Visual Studio versions are installed, set `vs2022_install` to the
  Visual Studio 2022 directory with backslashes.
- Put `--work-dir` at least two directories below the drive root (for example
  `C:\dartbrew-build\ctr-native-producer`). The Dart SDK's
  `build/toolchain/win/setup_toolchain.py` replaces the build directory's
  grandparent with `..\..` in `INCLUDE` and `LIB`; when that grandparent is the
  drive root, `C:\Program Files\...` becomes `..\..Program Files\...` and
  `gn gen` fails with "Path ... from environment variable include does not
  exist".

## Distribution and qualification

The first four-host packaging run was stopped before execution by account
billing limits. The next run executed all four jobs. Linux completed its
extracted-archive checks; Windows and both macOS hosts failed the reference
assembly comparison. Investigation led to the native-only sort and target
alignment fixes, and the remaining cross-host difference was narrowly verified
as the DWARF producer host name.

All four extracted native SDKs pass six real integration checks, including
retaining failed native-tool stderr and rejecting two builds that compete for
one output directory. Exclusive output reservation uses the host OS's atomic
directory creation. Its Linux ownership tests also reject a deliberate
nonexclusive-creation mutation. Windows path-preservation expectations were
corrected to use native separators without weakening the ownership assertions.

The complete SDK check passed for each host: Windows x64, Linux x64,
macOS Intel and macOS Apple Silicon.

Independent inspection of each downloaded SDK verified every sealed file,
manifest and archive digest, GNU corresponding-source digest and Unix
executable mode. A fresh AOT sample produced by each host also ran in Azahar
2126.2, printed `native:42` and passed cleanup and terminal validation.
The release receipts bound each SDK, CI run, target artifact and accepted run
identity. New JIT emulator or physical-console execution is not claimed.

Do not redistribute the branded devkitARM host-tool distribution. Native GNU
assembler/linker producers use independently pinned upstream sources and retain
GNU notices, exact corresponding source and build material. Target library
notices, source availability and the MPL startup/linker layout are included.
The upstream converter's conflicting license metadata is
not used as permission to redistribute it.

The converter's format encoding was checked against the layout documented by
the [Azahar loader](https://github.com/azahar-emu/azahar/blob/master/src/core/loader/3dsx.cpp)
and existing ELF/3DSX pairs. No converter source was copied into the Dart encoder.

Native producer CI, dependency closure, archive integrity, cross-host probe
code generation and supported AOT/JIT builds from extracted downloads passed.
The converter comparisons and per-host AOT emulator samples are additional
evidence. Existing ten hardware passes retain their original artifact
identities. Universal Dart APIs, FFI/native packages and Flutter remain
unfinished milestones.
