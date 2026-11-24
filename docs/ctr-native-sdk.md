# Native CTR SDK

The preview.5 SDK supplies the host Dart SDK, the CTR kernel compiler and
`gen_snapshot`, the `dartbrew` executable and the patched runtime sources.
Each host archive includes the same target compile plan and platform kernel.
`sdk.json` identifies the host, compatible runtime modes, ordered link inputs,
qualified devkitPro package versions and SHA-256 hashes of the sealed files.
`dartbrew doctor` verifies the files and reports the toolchain versions.

## Building an application

1. The bundled Dart resolves application packages. The CTR kernel compiler uses
   the bundled platform kernel. For AOT, `gen_snapshot` emits ARM assembly.
   For JIT, the application carries the program kernel.
2. dartbrew compiles the VM, I/O layer and launcher with the installed
   devkitARM tools and libctru headers for the requested mode. It builds the
   soft-math component from local libm and caches the native outputs. A change
   to the SDK manifest, toolchain versions or mode selects a new cache entry.
3. The local linker combines the program and native objects with startup files,
   system libraries and the linker script from devkitPro. dartbrew encodes the
   ELF as a 3DSX and can stage it for manual installation or send it to a device.

On a 16-logical-processor Windows PC the AOT spike compiled 645 translation
units and archived the VM and I/O layer in 186.234 seconds, with devkitARM r68-1
and libctru 2.7.1-1. This measurement excludes soft-math, offset validation,
linking and emulator startup. All 483 checked AOT offsets matched, and the
resulting hello app printed `hello:42` in Azahar 2126.2 and finished with a
passing cleanup assertion and terminal record. The release checklist requires
separate results for each candidate.

For SDK installation and device commands, see the [user guide](user-guide.md).
For build hosts and release evidence, see [releasing](releasing.md) and the
[qualification records](qualification/README.md).

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
the host verdict parser accepts those two schema versions.

## Runtime and result handling

The launcher initializes the SDK's CTR I/O layer before running Dart.
It starts the event handler and mounts app storage. With a host link, stdin
flows from the host to the running program and stdout and stderr flow back.
Long output lines travel in continuation records.
The host reassembles each line and validates the begin, cleanup and terminal
records against the run identity. `dartbrew run --verdict` writes run metadata
for the built artifact; a missing terminal record yields an incomplete run.
A program can return a nonzero exit code with `exit(n)`. The launcher's
terminal record includes `exit_code` for an explicit exit, and dartbrew returns
that code to its caller.

See the [supported features](ctr-supported-features.md) for the current extent
of file I/O, timers and other platform services.
