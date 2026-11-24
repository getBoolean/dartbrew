# dartbrew

Build, run and test Dart programs as homebrew apps.

`dartbrew` is a command-line tool shaped like `dart`. It builds an ordinary Dart
program for a homebrew target, and can run it or its `package:test` tests on a
device with one command that streams the results back to your terminal. CTR,
the codename of the 3DS-family platform, is the only target so far: apps are
`.3dsx` files for Homebrew Launcher on New 3DS-family consoles. They run the real Dart VM on the console's
ARM11 CPU, in either of two modes:

- **AOT:** the program is compiled to ARMv6K machine code on your computer.
- **JIT:** the Dart VM compiles the program on the console itself.

**Experimental preview.** Download the [preview.5 SDK](https://github.com/getBoolean/dartbrew/releases/tag/v0.1.0-preview.5)
for your host. See [CTR support](docs/ctr-supported-features.md) for coverage
by feature and execution mode.

## Requirements

- A Windows x64, Linux x64 (glibc 2.36 or newer) or Apple Silicon Mac. The
  preview.5 Mac binaries target macOS 14.0 or newer. The SDK build tests ran
  on macOS 27.0. Gatekeeper rejected the quarantined preview.5 CLI on that host.
- devkitPro with the **3DS Development** group (devkitARM and libctru). The
  first build compiles the native runtime for the selected mode. Subsequent
  builds reuse it from the local cache. [devkitPro installation guide](https://devkitpro.org/wiki/Getting_Started)
- A New 3DS-family console with Luma3DS and Homebrew Launcher for AOT and JIT,
  or Azahar for AOT. The original 3DS is unsupported.

## Quick start

1. Download the `dartbrew-...` SDK ZIP for your computer from the
   [releases page](https://github.com/getBoolean/dartbrew/releases) and extract
   it. Keep the extracted folder together, keep your projects outside it, and
   add it to `PATH` (or call
   `.\dartbrew.exe` on Windows and `./dartbrew` on macOS and Linux from that
   folder).

2. Check the SDK and create a project:

   ```console
   dartbrew doctor
   dartbrew create hello
   cd hello
   ```

3. On the console, open Homebrew Launcher and press Y to start the netloader.
   Then run the program or its tests from the project folder:

   ```console
   dartbrew run
   dartbrew test
   ```

   Output streams to your terminal. Allow inbound UDP and TCP port 17491 through
   your computer's firewall, or pick another TCP port with `--host-port`. Use
   `-d azahar` to run in Azahar instead.

4. To build an app to copy by hand, use `compile`. The output directory must not
   already exist:

   ```console
   dartbrew compile --project-directory . --output ../builds/hello bin/main.dart
   ```

   Copy the contents of the output's `SDROOT` folder to the root of your SD card
   and launch the app from Homebrew Launcher.

`dartbrew compile` replaces `ctr build` from earlier previews, and the `ctr`
command is gone. `dartbrew pub`, `analyze`, `format`, `fix`, `doc` and `info`
run the bundled Dart SDK. See the [SDK guide](docs/user-guide.md) for every
command, Azahar setup and the SD card flow.

## Building from source

Maintainers use the [release checklist](docs/releasing.md) to build the SDKs,
qualify the extracted archives and publish a preview. The [SDK overview](docs/ctr-native-sdk.md)
describes the host and target components and the launcher protocol.

Layout:

| Path | Contents |
| --- | --- |
| `packages/dartbrew` | The `dartbrew` command-line tool. |
| `toolchain` | Dart SDK pins, the CTR patch queue and the SDK build scripts. |
| `runtime/ctr` | The launcher that embeds the Dart VM on the console. |
| `packages/release_tools` | SDK build, packaging and qualification commands. |
| `release` | Preview version, host toolchain requirements and third-party notices. |
| `test/programs` | Sample programs used for hardware checks. |

## License and credits

This project is licensed under the [BSD 3-Clause License](LICENSE). The SDK
includes third-party software under the licenses shipped in its notices.
[CREDITS.md](CREDITS.md) identifies the upstream software and external tools.

## Trademarks

This is an unofficial project, not affiliated with, endorsed or sponsored by
Nintendo. Nintendo 3DS and New Nintendo 3DS are trademarks of Nintendo. Dart is
a trademark of Google LLC. These names are used only to describe compatibility.
