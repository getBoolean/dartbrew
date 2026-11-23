# Getting started with dartbrew

Install devkitPro's **3DS Development** tool group, including devkitARM and libctru, on your computer. On Windows the devkitPro graphical installer offers this group. Linux and macOS use the devkitPro package manager and the `3ds-dev` group. [devkitPro installation guide](https://devkitpro.org/wiki/Getting_Started)

Extract the dartbrew archive for your host. Keep the extracted directory together and add it to your PATH, or invoke `./dartbrew` (`.\dartbrew.exe` on Windows) directly. Run `dartbrew doctor` to verify the files and inspect the installed and qualified devkitPro versions. If dartbrew cannot find your custom installation, set `DEVKITPRO` to its root directory.

## Compile and run

Create a project outside the SDK directory.

```sh
dartbrew create hello
cd hello
dartbrew compile --output build-hello bin/main.dart
```

If your project uses a different entrypoint, pass its path. The output directory must be new. Copy the contents of `build-hello/SDROOT` onto the console's SD card and open the app from Homebrew Launcher. The first build for each mode compiles the runtime sources with your installed devkitARM. Later builds reuse those objects. AOT is the compile default. Pass `--mode jit` when you want a JIT application.

For a live console run, open Homebrew Launcher, press **Y** to start its netloader, and run `dartbrew run` in your project directory. Use `dartbrew devices` to see available devices, or select a console by IPv4 address with `-d`. Open UDP and TCP port 17491 on the host for discovery and output. Use `--host-port` to select another output port.

To run in Azahar, use `dartbrew run -d azahar`. Set `DARTBREW_AZAHAR` to the emulator executable or provide `--azahar` if it is outside PATH. Use `DARTBREW_AZAHAR_SDMC` when dartbrew needs the location of the emulator's configured SD card.

Run package tests with `dartbrew test`. Use `dartbrew pub`, `analyze`, `format`, `fix`, `doc`, and `info` for host-side Dart tools. Pub needs network access on first resolution or a populated cache with `--offline`. Use `dartbrew help <command>` for options.
