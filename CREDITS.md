# Credits and provenance

This record identifies software used or referenced by the experimental Dart CTR
port. Inclusion is attribution and provenance, not endorsement. Exact source,
toolchain, patch and dependency pins are in `toolchain/versions.json`.

## Software and tools used

- **Dart SDK, the Dart project authors:** compiler, VM, core libraries and test
  sources used as the port's upstream foundation. The CTR changes are preserved
  as an ordered patch queue. [Dart SDK](https://github.com/dart-lang/sdk),
  [bundled license](release/licenses/dart.LICENSE).
- **ICU and Unicode contributors:** the pinned Dart build's Unicode dependency,
  with a recorded newlib portability patch. [ICU](https://github.com/unicode-org/icu),
  [bundled notice](release/licenses/icu.LICENSE).
- **devkitPro, GCC, newlib and GNU Binutils contributors:** SDK users install
  devkitARM and libctru from devkitPro. Native builds use its compiler,
  assembler, linker, startup code, selected runtime libraries and headers. The
  software-math component is derived locally from the installed soft-float
  libm. Maintainers use the pinned devkitPro container for the Linux producer.
  [devkitPro](https://devkitpro.org/), [libctru](https://github.com/devkitPro/libctru),
  [GNU Binutils](https://sourceware.org/binutils/),
  [GCC runtime exception](https://www.gnu.org/licenses/gcc-exception-3.1.html),
  [newlib licensing](https://sourceware.org/newlib/COPYING.NEWLIB).
- **Chromium/depot_tools, GN, Ninja and LLVM/Clang contributors:** pinned host
  dependency synchronization, build generation and host compiler tools used by
  the SDK build. Their own source/distribution notices remain applicable.
- **Dart package contributors:** the `dartbrew` executable includes `args`
  (argument parsing), `path` (host paths), `crypto` (hashing), `ffi` (host
  system calls), `image` (decoding and scaling app icons), `yaml` (reading
  `pubspec.yaml`) and the packages these depend on: `archive`, `posix`, `meta`,
  `collection`, `source_span`, `string_scanner`, `term_glyph` and `typed_data`.
  Versions are locked in `packages/dartbrew/pubspec.lock`, and each package's
  notice is bundled under `release/licenses/`. `test` and `lints` are
  development dependencies. Host-side FFI reserves output directories
  atomically through the operating system; this does not expose FFI to
  applications on the console.
- **Dart `test` contributors:** `dartbrew test` drives `package:test_api`'s
  test backend in a generated entrypoint. The `test` and `test_api` packages
  come from the user's own project dependencies and are not bundled with the
  SDK.
- **devkitPro contributors, 3dslink and the Homebrew Launcher netloader:** the
  network protocol `dartbrew run`, `test` and `devices` use to find a console,
  send it an app and receive output was designed by devkitPro for 3dslink and
  Homebrew Launcher. dartbrew's client is a clean-room Dart implementation of
  that protocol; no 3dslink or Homebrew Launcher source is copied or bundled. [3dslink](https://github.com/devkitPro/3dslink),
  [Homebrew Launcher](https://github.com/devkitPro/3ds-hbmenu).
- **Azahar contributors:** actual AOT emulator execution used in qualification.
  [Azahar](https://github.com/azahar-emu/azahar). Emulator success is not substituted
  for physical-console evidence. `dartbrew run -d azahar` and `dartbrew test -d
  azahar` launch a user-installed Azahar; Azahar is not bundled.
  Its loader was also inspected for 3DSX format facts while implementing the
  CLI's independent ELF-to-3DSX encoder; no converter source was copied.
- **LumaTeam and Homebrew Launcher contributors:** the owner's modified-console
  launch environment for the reported physical New 3DS tests. Exact installed
  environment versions remain unrecorded.
- **LumaTeam, BootNTR/NTR and Chokistream contributors:** network input redirection
  and decoded screen capture used to establish agent-assisted console control.
  These tools are not bundled with the Dart preview.

## Reference material and related projects

ARM architecture documentation, 3dbrew and upstream source inspection informed
the compiler, ABI and platform work.
The separate [emucap project](https://github.com/getBoolean/emucap) owns emulator
bridge integration; its planned capabilities are not claimed as shipped here.
The project is independent of Nintendo and is not an official Nintendo SDK.

## AI assistance and accountability

OpenAI Codex and Anthropic Claude have assisted research, source implementation,
debugging, tests and documentation through the development workflow. Generated
output is not accepted solely because an AI produced it: claims require source
provenance and reproducible checks, and hypotheses remain distinct from measured
results. Maintainers remain responsible for review, licensing, testing and
release decisions. The preserved curated passes establish only their documented
scope, not arbitrary Dart or Flutter compatibility.
