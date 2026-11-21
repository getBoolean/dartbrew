# Building and qualifying CTR runtime primitives

The repository provides a locked SDK source/patch queue, distinct host and CTR
GN configurations and an experimental Dart embedder. Five curated programs now
execute and clean up on physical New 3DS in both AOT and JIT modes. See the
[supported-feature inventory](../ctr-supported-features.md). Earlier Azahar
runs are separate emulator evidence. The ten hardware passes establish this
bounded runtime milestone; wider Dart compatibility and other Nintendo targets
remain open.

## Locked SDK and host tools

Use [the named Compose service](../ctr-compose.md) with host-folder bind mounts
for all Linux builds and tests. The commands below run inside its `toolchain`
service, container `ctr-dart-toolchain`.

`toolchain/versions.json` pins the published Dart beta, upstream revision, ordered
patch hashes, DEPS digest, depot_tools, GN, Clang, Ninja, and devkitPro versions.
Local builds execute the pinned image. CI migration is separate work.
`target-ctr.json` owns the ARMv6K/VFPv2 hard-float profile and composed linker specs.
The specs select CP15 barriers once and retain their implementation; merely
stacking the two upstream specs causes a rename conflict, and an unrooted alias
can resolve to zero.

Keep SDK/dependency/build caches in the case-sensitive Linux host folder bound
at `/state`. From PowerShell in the repository, set `CTR_IMAGE` from
`toolchain/versions.json` and `CTR_STATE_DIR` to the existing host folder as
documented in the Compose guide. Run the following commands through
`docker compose exec -T toolchain`; paths are container paths:

```sh
python3 toolchain/native_linux.py check
# Prevent inherited Windows-style Git conversion in dependency checkouts.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
python3 toolchain/bootstrap.py --source /state/sdk --depot-tools /state/depot_tools --sync-deps
python3 toolchain/build_sdk.py build --source /state/sdk --component probe --mode jit
python3 toolchain/build_sdk.py configure --source /state/sdk --component host --mode jit
python3 toolchain/build_sdk.py configure --source /state/sdk --component precompiler --mode aot
python3 toolchain/build_sdk.py configure --source /state/sdk --component target --mode aot
python3 toolchain/build_sdk.py configure --source /state/sdk --component target --mode jit
```

Bootstrap refuses to overwrite unmanaged, dirty or mismatched sources. Export
changes as tracked patches and update their hashes, then use a new source
directory for a changed queue. All managed patches must remain reproducible.

`identity` prints the compatible inputs/cache key without building. Configure and
build verify the checkout and GN hash. Components distinguish Linux executables
from ARM libraries; modes select separate runtime graphs. Both native runtime
archives, the host precompiler and complete AOT/JIT launchers now build and link.
Successful GN generation alone is not a VM build or execution receipt.
`--check-includes` exposes upstream include ownership checking; that audit
currently reports errors on both the patched and exact upstream graphs. Not all
errors have been classified. The isolated native GN probe passes strict checking.

## Runtime assets for the native SDK

The complete SDK workflow (`.github/workflows/native-sdk.yml`) consumes a
`ctr-runtime-assets.zip` and, for Linux, a `ctr-native-precompiler-linux-x64.zip`
from a release, each pinned by SHA-256. After building both `target` runtime
graphs with `build_sdk.py build`, a producer exports and archives the target
assets in the Compose service:

```sh
python3 release/freeze_runtime.py --source /state/sdk --build-root /state/build --output <new-runtime-dir>
python3 release/archive_runtime.py --runtime <new-runtime-dir> --output <new-dir>/ctr-runtime-assets.zip --probe-kernel <kernel.dill> --precompiler <reference-gen_snapshot>
```

`freeze_runtime.py` checks the pinned toolchain, compiles the launcher sources in
`runtime/ctr/source` for both modes, checks native offsets and the platform's
private hooks, and records every exported file in `runtime.json`.
`archive_runtime.py` adds the bundled notices and records the reference AOT
assembly that `release/build_native_sdk.py` compares against each host's
precompiler. The Linux compiler component is the output folder of
`release/native_precompiler.py` run on Linux x64.

## Runtime results

The launcher writes `CTR_RUNTIME` JSON records to `ctr-runtime.log` on the SD
card. `runtime/ctr/results.py` validates one journal against the identity in
the matching `run.json`: schema, run ID, fixture, mode, compatibility,
artifact hash, build ID and environment. Records from other runs are ignored;
interleaved runs, records before `begin` or after the terminal record, and
contradictory cleanup/terminal outcomes are rejected.

Outcomes are `pass`, `fail` or `incomplete`. A journal without a begin, cleanup
assertion or terminal record is incomplete. A host-observed crash never
qualifies as a pass. Prepare a fresh run for every launch.

## Launcher contract (schema 2)

The launcher takes its run identity from netloader argv when any argv entry
starts with `--ctr-`; otherwise it reads `sdmc:/ctr-runtime-run.cfg`. Malformed
argv identity never falls back to the cfg file: the launcher writes no records
and exits 1.

**Cfg file.** Eight `key=value` lines in this order, each ending in a newline:
`schema`, `run_id`, `fixture`, `mode`, `compatibility`, `artifact_sha256`,
`build_id`, `environment`. Schema `1` allows nothing after them. Schema `2`
allows one more line, `host=<a>.<b>.<c>.<d>:<port>` (dotted-decimal IPv4 with
octets 0-255, port 1-65535, no spaces, newline-terminated), and nothing after
it. Any other ninth line is rejected.

**Argv tokens.** Each is one argv entry; order is free and each may appear once.

| Token | Required | Value |
| --- | --- | --- |
| `--ctr-run=schema=2` | yes | always `2` |
| `--ctr-run=run_id=<32 hex>` | yes | lowercase hex |
| `--ctr-run=artifact_sha256=<64 hex>` | yes | lowercase hex |
| `--ctr-run=environment=<hardware\|azahar\|host>` | yes | |
| `--ctr-run=fixture=<name>` | no | must equal the linked value |
| `--ctr-run=mode=<aot\|jit>` | no | must equal the linked value |
| `--ctr-run=compatibility=<64 hex>` | no | must equal the linked value |
| `--ctr-run=build_id=<64 hex>` | no | must equal the linked value |
| `--ctr-host-port=<1-65535>` | no | host listener port |

Omitted optional keys take the values linked into the application. Unknown
`--ctr-` tokens and repeated keys are rejected; entries without the `--ctr-`
prefix are ignored. The netloader appends `<8 hex>_3DSLINK_` after these
tokens; libctru's default argv setup removes it and stores the address in
`__3dslink_host`. The host is that address plus `--ctr-host-port`; without
either, the run has no socket.

**Socket output.** With a host, the launcher allocates a 1 MiB, 0x1000-aligned
buffer, calls `socInit` and connects over TCP before `begin`. Every
`CTR_RUNTIME` line then goes to the socket as well as the screen and journal,
and a bare `\n` keepalive goes to the socket only, every 2 seconds while the
program runs. After the terminal record the launcher shuts the socket down,
closes it, calls `socExit` and frees the buffer. If the connection fails, the
run continues without the socket and the failure text is the first `output`
record after `begin`. A failed socket write drops the socket for the rest of
the run without failing it. Without a host the launcher behaves as with schema
1. The `begin` record carries the schema that was read (`1` or `2`), and
`results.py` accepts only those two values.

**`dart:io`.** Before `Dart_Initialize` the launcher bootstraps the SDK's
`dart:io` layer for CTR (patches 0034 and 0035) and starts its event handler;
after the program it cleans the layer up before `Dart_Cleanup`. The isolate
loads `dart:io` through the SDK's own `SetupDartIoLibrary`, so the I/O layer
resolves every `dart:io` native and timers run on its event handler. Areas not
yet ported fail with a catchable `OSError` naming the area ("<Area> is not
supported on CTR (dart:io)"). `exit()` throws `UnsupportedError: This embedder
disallows calling dart:io's exit()`. `print` and `Uri.base` still use the
launcher's `_ctr` hooks. soc:U and its 1 MiB buffer are owned by
`SocketService` (`link.cc`) and started only when a host link is requested.
Apps link `lib/<mode>/io.a` between the launcher objects and the runtime
archive. Host drivers keep the fallback resolver in
`runtime/ctr/source/unsupported.cc`, which reports every `dart:io` native as
unsupported; the host-VM driver accepts `CTR_TEST_VM_FLAG=--link_natives_lazily`
to exercise AOT's native linking on the host JIT VM.

## Host checks

```sh
python3 -m unittest discover -s toolchain/test -v
python3 -m unittest discover -s runtime/ctr/test -v
python3 -m unittest discover -s release/test -v
```

The runtime suite validates journal parsing and compiles the launcher's input
host check. Set `CTR_SDK_INTEGRATION=1` for the toolchain suite to reproduce
the complete managed SDK tree in a temporary directory after materialization.
Run these suites through `docker compose exec -T toolchain`.
CI runs these host checks and the CLI package's analysis and tests. It does not
run the guest.

## Build a Dart entrypoint

Applications are built with `dartbrew compile` (or built and launched with
`dartbrew run` and `dartbrew test`) from `packages/dartbrew`, shipped in the
complete native SDK; see the [release usage instructions](../../release/README.md).
`dartbrew run --verdict` prints the same pass, fail or incomplete verdict as
`results.py` for the streamed records and writes `run.json` next to the build.
Run its checks with the pinned Dart from the Compose service, keeping
`PUB_CACHE` on `/state`:

```powershell
docker compose exec -T -e PUB_CACHE=/state/pub-cache -w /work/packages/dartbrew toolchain /state/sdk/tools/sdks/dart-sdk/bin/dart pub get --enforce-lockfile
docker compose exec -T -e PUB_CACHE=/state/pub-cache -w /work/packages/dartbrew toolchain /state/sdk/tools/sdks/dart-sdk/bin/dart test
```

File/network I/O, public isolates and FFI/native packages are required by the
next compatibility milestone; the CLI does not make unsupported services work.
Dependency versions are fixed by the committed pubspec lockfile.
