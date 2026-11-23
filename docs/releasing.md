# Releasing dartbrew

Build each archive from the same candidate revision. Match the versions in
`release/preview.json` and `packages/dartbrew/pubspec.yaml`. Use fresh output
directories and preserve the logs from failed builds separately.

## 1. Bootstrap each native build host

Use Windows x64, Linux x64 and macOS arm64. Each needs git, Python for
bootstrap, the native compiler prerequisites for building Dart and the
devkitPro CTR development tools for checking the extracted SDK. The Linux
producer uses the pinned Compose toolchain. [Compose setup](ctr-compose.md)

On Windows, install the C++ tools in Visual Studio 2022 and the Windows SDK
specified in `release/native-windows-sdk.json`. Set
`DEPOT_TOOLS_WIN_TOOLCHAIN=0` and `PYTHONUTF8=1`. Set `vs2022_install`
if discovery picks another installation. Put the build directory at least
two levels below the drive root so Dart's toolchain setup computes correct
include paths. On macOS use the Xcode command line tools.

From the repository root, bootstrap the managed SDK and verify it. The
examples use Linux service paths. On the other hosts use native absolute paths
and the installed Python executable.

```sh
python3 toolchain/bootstrap.py --source /state/sdk --depot-tools /state/depot_tools --sync-deps --fetch-gn
python3 toolchain/bootstrap.py verify --source /state/sdk
```

Use `tools/sdks/dart-sdk/bin/dart` from that checkout as `dart` below. Run
`dart pub get --enforce-lockfile`, `dart analyze`,
`dart format --output=none --set-exit-if-changed .` and `dart test` in both
`packages/dartbrew` and `packages/release_tools`. Inside the Linux service
also run the bootstrap and launcher checks from the repository root.

```sh
python3 -m unittest discover -s toolchain/test -v
make -C runtime/ctr host-test
make -C runtime/ctr sdk-host-test SDK=/state/sdk
```

Run the remaining producer commands from `packages/release_tools`.
`dart run release_tools:check_upstream` compares pins with current upstream
releases. To adopt a new devkitPro image, run
`dart run release_tools:update_upstream devkitpro`, review the pin changes
and rebuild with those pins. An available update is informational.

## 2. Build the precompiler on each host

```sh
dart run release_tools:build_precompiler --source /state/sdk --depot-tools /state/depot_tools --work-dir /state/build/host-work --output-dir /state/release/precompiler
```

Use `--python` to select the bootstrap interpreter when the host does not
provide `python3`. Keep each host's output separate. It holds the native
`gen_snapshot`, CTR kernel compiler, host Dart and `native-precompiler.json`.

## 3. Produce the shared runtime in the Linux service

Build one target mode at a time. Use the Linux precompiler for the reference
probe and pass the same graph output root to `build_sdk` and `build_runtime`.

```sh
dart run release_tools:build_sdk build --source /state/sdk --component target --mode aot --output-root /state/build
dart run release_tools:build_sdk build --source /state/sdk --component target --mode jit --output-root /state/build
dart run release_tools:build_runtime --source /state/sdk --build-root /state/build --gen-snapshot /state/release/precompiler/gen_snapshot --output /state/release/runtime
```

Transfer the complete runtime output to each assembly host, including the
reference probe, source bundle, platform kernel, compile plan and metadata.
Resolve a missing input, failed check or failed proof build before assembly.

## 4. Assemble and verify three archives

Run on each host with its native precompiler and the shared runtime bundle.

```sh
dart run release_tools:assemble_sdk --precompiler /state/release/precompiler --runtime /state/release/runtime --output-dir /state/release/assembled
```

Retain each `dartbrew-<version>-<host>.zip` and its `verification.json`.
Check the extracted executables on their host. Run `dartbrew doctor`, build
hello and build it a second time to verify cache reuse. Record installed and
qualified toolchain versions and the archive digest. On macOS, record the
highest deployment target among the shipped Mach-O binaries (the `minos` field
in `LC_BUILD_VERSION`, or `version` in `LC_VERSION_MIN_MACOSX`, from
`otool -l`). Record the macOS version used to test separately. Use the binary
minimum and actual compatibility evidence to state the release requirements.
On the Mac, open the
downloaded candidate through the normal Gatekeeper path and record the actual
result and any action the user had to take.

## 5. Qualify the candidate applications

Run each standalone fixture with a golden file in `test/expected` using the
extracted SDK. For example, from the repository root:

```console
dartbrew run --verdict --mode aot -d azahar test/programs/hello.dart
dartbrew run --verdict --mode aot -d <console-ip> test/programs/hello.dart
dartbrew run --verdict --mode jit -d <console-ip> test/programs/hello.dart
```

Compare application output with the matching file and check the run ID,
artifact digest, build ID, cleanup and terminal verdict. Most fixtures must
exit 0. `exit_code.dart` must print `exit:3` and `partial line`, clean up and
report exit code 3. Feed EOF to the platform fixture's stdin and check its
stderr as well as stdout. With `--verdict`, parse the final JSON line
separately from the program output. Retain incomplete runs for diagnosis. Diagnostic programs
without goldens have their own observed outcomes.

Record results under `docs/qualification/<version>/results.json`. Give each
host's verification receipt a distinct name. Keep outstanding measurements
visible in the draft until the required environments pass. [Results schema](qualification/README.md)

## 6. Review and publish the qualified bytes

Open the PR, complete the code and maintainability reviews, resolve findings
and check the final revision. Rebuild and requalify artifacts affected by a
fix. Include the completed qualification record in the reviewed change.

Run the guard against the three actual archives. In the Linux shell, set
`version` to the candidate version and collect each host's archive under
`/state/qualified/<host>/`.

```sh
dart run release_tools:check_release --results "../../docs/qualification/$version/results.json" /state/qualified/*/dartbrew-"$version"-*.zip
```

Confirm the guard printed the three expected archive names and returned
success. Publish an authorized prerelease at the reviewed commit with those
ZIPs. Verify the public tag, names and SHA-256 digests against the results.
