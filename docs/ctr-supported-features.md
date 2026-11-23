# Current Dart CTR support

Published preview.4 has a four-host qualification record. Subsequent runs
on the development branch cover file and directory operations, platform values,
stdio and explicit exit codes. Preview.5 candidate qualification covers the
exact rebuilt host archives and device apps separately.
[Published results](qualification/0.1.0-preview.4/results.json)

| Area | Current evidence | Remaining boundary |
| --- | --- | --- |
| Native AOT | Five curated programs pass on New 3DS | Wider language/library and resource coverage |
| On-device JIT | The same five programs pass on New 3DS | Wider optimization, lifecycle and compiler stress |
| CLI packaging | Preview.4 records its four-host checks. The preview.5 Windows spike rebuilt hello AOT with a local devkitPro and ran it in Azahar. | Candidate archive and hardware results belong to their own version. [Native SDK](ctr-native-sdk.md) |
| Core language and collections | Hello, retained GC data, exception/stack and focused numeric checks | No complete language/corelib compatibility claim |
| Async/timers | Curated asynchronous work completes and cleans up in both modes | Broader timer, cancellation and long-running application coverage |
| Numeric semantics | Focused target tests plus software-helper/provider checks | Broader upstream/optimization-mode corpus; not universal numeric compatibility |
| Files and platform | The development branch ran the files, platform and exit-code programs on the console in AOT and JIT and on Azahar in AOT. | Sockets, DNS, HTTP and TLS await separate qualification. |
| Public isolates | Internal VM threading/ports support tested applications | Public isolate API, multiple-isolate semantics and resource limits are not qualified |
| FFI/native packages | Native runtime linkage and internal helper ABI checks | These are not public FFI/package qualification; dependency linking/loading and callbacks remain work |
| Flutter | Planned after universal Dart compatibility | No Flutter engine rendering or application qualification |
| Other Nintendo targets | Research scope only | Original 3DS, DS/DS Lite, Switch and Switch 2 are unqualified |

## Earlier I/O bring-up results

The initial I/O port loaded the SDK's own `dart:io` layer, ported to CTR (patches
0034 and 0035), so `dart:io` calls reach real platform code. Areas not yet
implemented fail in the shape the Dart API gives for an operating-system error,
with the OS error text `<Area> is not supported on CTR (dart:io)`: file calls
throw `FileSystemException`, sockets `SocketException`, and so on. All of them
are catchable and the run continues. Timers run on the `dart:io` event handler.

Observed on 2026-11-21 with `test/programs/unsupported_apis.dart` through
`dartbrew run`, on a New 3DS in AOT and JIT and in Azahar 2126.2 in AOT; all
three gave the same results. A timer check (a 100 ms timer while the main
isolate spins for 2 s) fired after the loop in every environment, so the event
handler neither starved the loop nor lost the timer. Before the I/O layer was
linked, every `dart:io` native threw `UnsupportedError` naming the native.

Azahar runs AOT only. The JIT VM publishes compiled code with Luma3DS's custom
cache SVC; Azahar doesn't emulate it (`svcGetSystemInfo(0x10000)` fails) and the
VM aborts right after `begin`. `dartbrew run -d azahar` and `test -d azahar`
therefore default to AOT and refuse `--mode jit`. The hello, async, exceptions
and gc_stress fixtures pass in Azahar AOT through `dartbrew run --verdict`.

| Area | Console (AOT and JIT) and Azahar (AOT) |
| --- | --- |
| File read | Catchable `FileSystemException`: Cannot open file (OS Error: File is not supported on CTR (dart:io)) |
| Socket connect | Catchable `SocketException`: Failed host lookup (OS Error: InternetAddress is not supported on CTR (dart:io)) |
| `Process.run` | Catchable `OSError`: Failed to retrieve environment variables |
| `Isolate.spawn` | Catchable `UnsupportedError`: `Isolate.spawn` |
| `DynamicLibrary.open` (FFI) | Catchable `ArgumentError`: loading dynamic libraries is not supported |
| `stdout.write` | Catchable `FileSystemException`: Failed to get type of stdio handle (OS Error: File is not supported on CTR (dart:io)) |
| `exit` | `UnsupportedError`: This embedder disallows calling dart:io's exit(). Uncaught, so the run ends as fail with a full stack trace |

`package:test` files run with `dartbrew test` and report per test (observed 2026-11-19/20 before the I/O layer was linked): on the console in AOT and JIT, where an 18.9 MB JIT test app uploads once Wi-Fi interference is reduced, and in Azahar in AOT, where a fresh `dartbrew create` project passes.

`Uri.base` is `file:///` on CTR (SDK patch 0033, installed by the launcher), so
`package:path` and `package:stack_trace` work and failing tests report full
stack traces. Confirmed on the console on 2026-11-19 with the 33-patch tree.

## Reproducibility and evidence

The source queue is pinned in `toolchain/versions.json`; target ABI/flags are in
`toolchain/target-ctr.json`. A fresh SDK patch replay passed during consolidation.
The host checks the journal identity, expected output, cleanup and terminal status for each run.

No throughput, frame-rate, battery-life, elapsed-time or peak-memory guarantee
has been measured. A diagnostic GC run observed a 32-thread resource allowance
and three startup threads on the owner's setup. The VM's normal global worker
budget is four; blocking compensation can exceed it, so this is not a strict
process-wide thread cap. Exact firmware/Luma/Homebrew Launcher versions remain
unrecorded.

The memory-region protection and input-ownership fixes are preserved as SDK
patches and launcher sources with their focused checks. Prior failed protection
and GC attempts were failures; later passing runs do not turn those attempts
into successes. Multicore cache visibility and larger concurrency and
memory/lifecycle workloads still need qualification.

Universal Dart compatibility is the next implementation milestone. It explicitly
includes broader file and network I/O, public isolates, FFI and native packages;
documenting these gaps does not satisfy that milestone. Programs also remain
subject to actual hardware resources and native dependency availability.
