# U4 scheduling and memory spike

Measurement prototype for plan U4 (KTD15, R10, R20). It decides where Dart threads go and at what priority, given that the console scheduler does not time-slice threads of equal priority. It also records the app memory baseline and the thread budget. This is spike code: the decision lands in `docs/ctr-native-sdk.md` and in U2, U3 or U10, and this directory is removed before the milestone ends (Definition of Done).

## Build

Run inside the toolchain container:

```sh
docker exec ctr-dart-toolchain sh /work/runtime/ctr/test/scheduling/build.sh
```

Use `MSYS_NO_PATHCONV=1` when running this from Git Bash. Output goes to `build/sched-spike.3dsx` (git-ignored), or to the directory given as the first argument. The app is one self-contained `.3dsx`.

## Run

Upload with the netloader (`3dslink build/sched-spike.3dsx`) or copy it to `sdmc:/3ds/`. The app needs no input. It runs for about 90 s of measurements, then serves its log on TCP port 17500 for 90 s (START skips), then exits. The log is also written to `sdmc:/3ds/sched-spike/sched-spike.log`, closed after every line. A `BEGIN <policy>` line is written before each run, so a hang shows which run it was in.

Fetch the log from a PC once the screen shows `Serving this log on <ip>:17500`:

```sh
python -c "import socket,sys;s=socket.create_connection((sys.argv[1],17500));print(s.makefile('rb').read().decode())" <console-ip>
```

## What each run contains

Every policy run creates these threads for its duration (10 s; the idle run is 4 s):

| Thread | Priority, core | Stands in for |
| --- | --- | --- |
| busy A, busy B | 0x30, per policy | Two CPU-bound isolates. They count iterations. |
| mutator | 0x30, core 0 | A responsive isolate: one event loop with a 50 ms timer heartbeat that also answers echo requests. This is not in the brief's list. It was added because in the real runtime the timer callback and the echo reply run on a Dart thread at 0x30 (`runtime/ctr/source/sync.h`). |
| helper hb | 0x2F, core 0 | A 50 ms heartbeat at the band `dart:io` threads and the keepalive use now. |
| handler | 0x2F, core 0 | The event handler (patch 0035): it sleeps in 10 ms slices and passes a new echo request to the mutator. |
| main (peer) | 0x2C, core 0 | The remote peer. It sends an echo request every 250 ms (only after the previous one has been answered) and samples the busy counters every 1 s. |

An echo's round trip runs from the peer's request, through the handler's next slice, to the mutator's reply.

Policies:

| Name | Busy cores | Busy-thread yield |
| --- | --- | --- |
| `idle` | none | calibration only |
| `P1-core0` | 0, 0 | none |
| `P2a-rr` | 0, 2 | none (the mutator shares core 0 with A) |
| `P2b-split` | 2, 2 | none (main isolate on core 0, spawned isolates on core 2) |
| `P3a-y0-10ms` | 0, 0 | `svcSleepThread(0)` every 10 ms |
| `P3b-y0-1ms` | 0, 0 | `svcSleepThread(0)` every 1 ms |
| `P3c-s100us-10ms` | 0, 0 | `svcSleepThread(100 us)` every 10 ms |
| `P3d-s1ms-10ms` | 0, 0 | `svcSleepThread(1 ms)` every 10 ms |
| `P4-rr-s1ms-10ms` | 0, 2 | `svcSleepThread(1 ms)` every 10 ms |

The P2 and P4 runs print `SKIP ... core 2 unavailable` if a thread cannot be created on core 2 or does not run there.

## Log format (format 1)

All lines are plain text. The machine-readable lines start with a keyword:

- `ENV new3ds= main_priority= main_core= kernel= firm=`
- `MEM app_memtype= app_region_size= app_region_used= app_region_free=`: the raw `osGetApplicationMemType()` (0 to 5 are Old 3DS layouts and 6 to 8 are New 3DS layouts) and the APPLICATION region in bytes. libctru maps the free region as heap and linear heap before `main`, so `app_region_free` reads near zero for a `.3dsx`.
- `MEM heap_size= linear_heap_size= linear_free= malloc_* heap_unsbrk= heap_available=`: what the program can still allocate. `heap_available` is the unused part of the heap plus malloc's free list.
- `RESLIMIT <name> limit= current=`: the process resource limits for priority, commit, thread, event, mutex, semaphore, timer and cputime.
- `CPU ...` and `CORE probe= core= create=ok|FAIL ran_on=`: cores 1, 2 and 3 are probed at the start. `ran_on` is `svcGetProcessorID()` inside the probe thread.
- `CORES core1=usable|refused core2=usable|refused`
- `SETUP ...`: the mutator event and main's raised priority. If either fails, an `ERROR` line follows and no policy runs.
- `THREADS limit= in_use_at_start= created_extra= in_use_at_failure= in_use_after_free= capped=`: blocked threads with 4 KiB stacks are created until `threadCreate` fails, capped at 96. The extra-thread count is the app's headroom. `in_use_after_free` should equal `in_use_at_start`.
- `PLAN ...`: the run schedule and thresholds.
- `BEGIN <policy>`, followed by detail lines for that run and one line of the form:
  `RESULT policy=<name> helper_hb_worst_ms= mutator_hb_worst_ms= mutator_hb_p99_ms= mutator_beats=<n>/<expected> handler_pickup_worst_ms= echo_worst_ms= echo_p99_ms= busyA_k= busyB_k= busyA_windows= busyB_windows= windows= helper_hb=PASS|FAIL mutator_hb=PASS|FAIL echo=PASS|FAIL busy_both=YES|NO viable=YES|NO|n/a`
- After the runs, if core 1 was refused, the app calls `APT_SetAppCpuTimeLimit(30)` and probes core 1 again (`CPU ...`, `CORE probe=core1-after-limit`, `CORES core1_with_limit=`). This happens last because the limit changes process state that the launcher never sets, and it may not be possible to reset it.
- `DONE viable_count=<n> viable=<names>`

## Pass and fail

- **Heartbeat:** worst lateness under 100 ms, with at least 90% of the expected beats delivered. Worst lateness is the larger of the maximum lateness and the longest gap between beats minus 50 ms, so a starved thread that delivers few beats still fails.
- **Echo:** every request answered (at most the last one still in flight), no request skipped, and the worst round trip, including the age of an unanswered request, is 200 ms or less.
- **Both busy threads progress:** each busy counter advanced in at least 80% of the 1 s windows.
- **viable=YES:** all of the above hold. The plan's thresholds are judged on the mutator heartbeat, because a Dart `Timer` runs on an isolate's thread. The helper heartbeat shows whether the 0x2F band stays responsive.

The `busy X ... k/s` lines give throughput, so the cost of a yield policy can be compared with `P1-core0`.
