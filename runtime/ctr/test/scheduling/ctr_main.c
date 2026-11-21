// U4 spike app: thread scheduling, thread budget and memory baseline.
//
// Measures how libctru threads share the CPU under the candidate placement
// policies of plan U4 (KTD15). The console scheduler does not time-slice
// threads of equal priority, so a CPU-bound thread can starve its peers.
//
// Per policy run, these threads exist (priority, core):
//   busy A, busy B   0x30, per policy   CPU-bound "isolates", count iterations
//   mutator          0x30, core 0       stand-in for a responsive isolate: a
//                                       50 ms timer heartbeat plus echo replies
//   helper hb        0x2F, core 0       50 ms heartbeat at the dart:io band
//   handler          0x2F, core 0       event-handler proxy: 10 ms sleep slices,
//                                       hands echo requests to the mutator
//   main (peer)      0x2C, core 0       issues an echo request every 250 ms and
//                                       samples busy counters every 1 s
//
// Results go to the screen, to LOG_PATH and over TCP port 17500 at the end.
// Nothing is logged from worker threads; the log is closed after each line.
#include <3ds.h>
#include <malloc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define DIR_PATH "sdmc:/3ds/sched-spike"
#define LOG_PATH DIR_PATH "/sched-spike.log"

extern u32 __ctru_heap, __ctru_heap_size, __ctru_linear_heap_size;

static void say(const char* format, ...) {
  char line[400];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  printf("%s\n", line);
  FILE* log = fopen(LOG_PATH, "a");
  if (log) {
    fprintf(log, "%s\n", line);
    fclose(log);
  }
  gfxFlushBuffers();
  gfxSwapBuffers();
}

// ---- Time. svcGetSystemTick runs at SYSCLOCK_ARM11 in every clock mode. ----

#define TICKS_PER_MS ((u64)SYSCLOCK_ARM11 / 1000)
static inline u64 now(void) { return svcGetSystemTick(); }
static inline u32 ticks_to_us(u64 t) { return (u32)(t * 1000000ULL / SYSCLOCK_ARM11); }
static inline s64 ticks_to_ns(u64 t) { return (s64)(t * 1000000000ULL / SYSCLOCK_ARM11); }

// ---- Lateness series. ----

#define MAX_SAMPLES 512
typedef struct {
  u32 us[MAX_SAMPLES];  // lateness per event, microseconds
  int n;
  u32 max_gap_us;  // longest time between two consecutive events
  u32 missed;      // periods skipped entirely
  u64 last;
  s32 core;
} series;

static void series_reset(series* s, u64 start) {
  memset(s, 0, sizeof(*s));
  s->last = start;
  s->core = -1;
}

static void series_add(series* s, u64 at, u64 late_ticks) {
  if (s->n < MAX_SAMPLES) s->us[s->n++] = ticks_to_us(late_ticks);
  u32 gap = ticks_to_us(at - s->last);
  if (gap > s->max_gap_us) s->max_gap_us = gap;
  s->last = at;
}

static int cmp_u32(const void* a, const void* b) {
  u32 x = *(const u32*)a, y = *(const u32*)b;
  return x < y ? -1 : x > y;
}

typedef struct {
  u32 max, p99, mean;
} stats;

static stats series_stats(const series* s) {
  static u32 sorted[MAX_SAMPLES];
  stats r = {0, 0, 0};
  if (s->n == 0) return r;
  memcpy(sorted, s->us, s->n * sizeof(u32));
  qsort(sorted, s->n, sizeof(u32), cmp_u32);
  u64 sum = 0;
  for (int i = 0; i < s->n; ++i) sum += sorted[i];
  int p99 = (s->n * 99 + 99) / 100 - 1;  // ceil(0.99 n) - 1
  r.max = sorted[s->n - 1];
  r.p99 = sorted[p99 < 0 ? 0 : p99];
  r.mean = (u32)(sum / s->n);
  return r;
}

// ---- Shared run state. ----

#define HEARTBEAT_MS 50
#define SLICE_MS 10
#define PEER_TICK_MS 250
#define MAX_REQUESTS 256

static volatile int g_stop;
static Handle g_mutator_event;
static volatile u32 g_req_seq, g_handled_seq, g_replied_seq;
static volatile u64 g_req_tick[MAX_REQUESTS];

static series s_helper_hb, s_mutator_hb, s_slice, s_pickup, s_echo;

typedef struct {
  volatile u32 count;  // units of 1000 inner iterations
  s32 core_seen;
  u64 yield_ticks;
  s64 yield_ns;
  u32 yields;
  u32 pad[8];  // keep the two counters on separate cache lines
} busy_state;

static busy_state g_busy[2];

static void busy_entry(void* arg) {
  busy_state* b = arg;
  b->core_seen = svcGetProcessorID();
  u64 last = now();
  while (!g_stop) {
    for (volatile int i = 0; i < 1000; ++i) {
    }
    b->count++;
    if (b->yield_ticks) {
      u64 t = now();
      if (t - last >= b->yield_ticks) {
        svcSleepThread(b->yield_ns);  // stand-in for a VM safepoint yield
        b->yields++;
        last = now();
      }
    }
  }
}

// Helper-band heartbeat: absolute 50 ms schedule, missed periods are skipped.
static void helper_hb_entry(void* arg) {
  (void)arg;
  s_helper_hb.core = svcGetProcessorID();
  const u64 period = HEARTBEAT_MS * TICKS_PER_MS;
  u64 next = now() + period;
  while (!g_stop) {
    u64 t = now();
    if (next > t) svcSleepThread(ticks_to_ns(next - t));
    t = now();
    series_add(&s_helper_hb, t, t > next ? t - next : 0);
    next += period;
    while (next <= t) {
      next += period;
      s_helper_hb.missed++;
    }
  }
}

// Event-handler proxy: sleeps in 10 ms slices (as patch 0035's handler polls
// with sockets registered) and forwards a new echo request to the mutator.
static void handler_entry(void* arg) {
  (void)arg;
  s_slice.core = svcGetProcessorID();
  u32 handled = g_req_seq;
  while (!g_stop) {
    u64 before = now();
    svcSleepThread((s64)SLICE_MS * 1000000);
    u64 t = now();
    u64 expected = before + SLICE_MS * TICKS_PER_MS;
    series_add(&s_slice, t, t > expected ? t - expected : 0);
    u32 r = g_req_seq;
    if (r != handled) {
      handled = r;
      series_add(&s_pickup, t, t - g_req_tick[r % MAX_REQUESTS]);
      __sync_synchronize();
      g_handled_seq = r;
      svcSignalEvent(g_mutator_event);
    }
  }
}

// Mutator-band thread: one event loop with a 50 ms timer and echo replies, as
// a responsive Dart isolate would have. Runs at the busy threads' priority.
static void mutator_entry(void* arg) {
  (void)arg;
  s_mutator_hb.core = svcGetProcessorID();
  const u64 period = HEARTBEAT_MS * TICKS_PER_MS;
  u64 next = now() + period;
  while (!g_stop) {
    u64 t = now();
    if (next > t) svcWaitSynchronization(g_mutator_event, ticks_to_ns(next - t));
    if (g_stop) break;
    t = now();
    u32 h = g_handled_seq;
    if (h != g_replied_seq) {
      series_add(&s_echo, t, t - g_req_tick[h % MAX_REQUESTS]);
      g_replied_seq = h;
    }
    if (t >= next) {
      series_add(&s_mutator_hb, t, t - next);
      next += period;
      while (next <= t) {
        next += period;
        s_mutator_hb.missed++;
      }
    }
  }
}

// ---- Policies. ----

typedef struct {
  const char* name;
  const char* description;
  int busy;  // number of busy threads (0 or 2)
  int core_a, core_b;
  int yield_ms;  // 0 = never yield
  s64 yield_ns;  // argument to svcSleepThread at each yield
  int seconds;
  int needs_core2;
} policy;

static const policy policies[] = {
    {"idle", "no busy threads (sleep granularity calibration)", 0, 0, 0, 0, 0, 4, 0},
    {"P1-core0", "candidate 1: A,B on core 0, no yields", 2, 0, 0, 0, 0, 10, 0},
    {"P2a-rr", "candidate 2: A core 0, B core 2 (round-robin), no yields", 2, 0, 2, 0, 0, 10, 1},
    {"P2b-split", "candidate 2: A,B core 2, mutator core 0, no yields", 2, 2, 2, 0, 0, 10, 1},
    {"P3a-y0-10ms", "candidate 3: core 0, svcSleepThread(0) every 10 ms", 2, 0, 0, 10, 0, 10, 0},
    {"P3b-y0-1ms", "candidate 3: core 0, svcSleepThread(0) every 1 ms", 2, 0, 0, 1, 0, 10, 0},
    {"P3c-s100us-10ms", "candidate 3: core 0, svcSleepThread(100us) every 10 ms", 2, 0, 0, 10,
     100000, 10, 0},
    {"P3d-s1ms-10ms", "candidate 3: core 0, svcSleepThread(1ms) every 10 ms", 2, 0, 0, 10, 1000000,
     10, 0},
    {"P4-rr-s1ms-10ms", "candidates 2+3: A core 0, B core 2, svcSleepThread(1ms) every 10 ms", 2, 0,
     2, 10, 1000000, 10, 1},
};
#define POLICY_COUNT (int)(sizeof(policies) / sizeof(policies[0]))

#define MAIN_RUN_PRIORITY 0x2C
#define HELPER_PRIORITY 0x2F
#define MUTATOR_PRIORITY 0x30
#define STACK 16 * 1024

static int core1_usable, core2_usable;
static int verdict_count;
static char viable_names[256];

static void run_policy(const policy* p) {
  say("BEGIN %s: %s (%d s)", p->name, p->description, p->seconds);
  if (p->needs_core2 && !core2_usable) {
    say("SKIP %s: core 2 unavailable", p->name);
    say("RESULT policy=%s skipped=core2", p->name);
    return;
  }
  g_stop = 0;
  g_req_seq = g_handled_seq = g_replied_seq = 0;
  u64 start = now();
  series_reset(&s_helper_hb, start);
  series_reset(&s_mutator_hb, start);
  series_reset(&s_slice, start);
  series_reset(&s_pickup, start);
  series_reset(&s_echo, start);
  memset(g_busy, 0, sizeof(g_busy));
  svcClearEvent(g_mutator_event);

  // Main outranks every worker, so creation finishes before anything runs.
  Thread threads[5] = {0};
  int count = 0;
  threads[count++] = threadCreate(handler_entry, NULL, STACK, HELPER_PRIORITY, 0, false);
  threads[count++] = threadCreate(helper_hb_entry, NULL, STACK, HELPER_PRIORITY, 0, false);
  threads[count++] = threadCreate(mutator_entry, NULL, STACK, MUTATOR_PRIORITY, 0, false);
  for (int i = 0; i < p->busy; ++i) {
    g_busy[i].core_seen = -1;
    g_busy[i].yield_ticks = (u64)p->yield_ms * TICKS_PER_MS;
    g_busy[i].yield_ns = p->yield_ns;
    threads[count++] = threadCreate(busy_entry, &g_busy[i], STACK, MUTATOR_PRIORITY,
                                    i == 0 ? p->core_a : p->core_b, false);
  }
  for (int i = 0; i < count; ++i) {
    if (!threads[i]) {
      g_stop = 1;
      svcSignalEvent(g_mutator_event);
      for (int j = 0; j < count; ++j) {
        if (threads[j]) {
          threadJoin(threads[j], U64_MAX);
          threadFree(threads[j]);
        }
      }
      say("RESULT policy=%s error=threadCreate_failed index=%d", p->name, i);
      return;
    }
  }

  // Peer loop: echo request every 250 ms, busy counters sampled every 1 s.
  u32 sent = 0, skipped = 0;
  int windows = 0, progressed[2] = {0, 0};
  u32 last_count[2] = {0, 0};
  const int ticks_total = p->seconds * 1000 / PEER_TICK_MS;
  u64 next = now();
  for (int tick = 1; tick <= ticks_total; ++tick) {
    next += PEER_TICK_MS * TICKS_PER_MS;
    u64 t = now();
    if (next > t) svcSleepThread(ticks_to_ns(next - t));
    t = now();
    if (g_replied_seq == g_req_seq) {
      u32 seq = g_req_seq + 1;
      g_req_tick[seq % MAX_REQUESTS] = t;
      __sync_synchronize();
      g_req_seq = seq;
      sent++;
    } else {
      skipped++;  // previous request still unanswered
    }
    if (tick % (1000 / PEER_TICK_MS) == 0) {
      windows++;
      for (int i = 0; i < p->busy; ++i) {
        u32 c = g_busy[i].count;
        if (c != last_count[i]) progressed[i]++;
        last_count[i] = c;
      }
    }
  }
  u64 end = now();
  u32 outstanding_age_us = 0;
  int outstanding = g_replied_seq != g_req_seq;
  if (outstanding) outstanding_age_us = ticks_to_us(end - g_req_tick[g_req_seq % MAX_REQUESTS]);
  int mutator_n = s_mutator_hb.n;
  u32 mutator_gap_now = ticks_to_us(end - s_mutator_hb.last);  // gap still open at stop
  u32 counts[2] = {g_busy[0].count, g_busy[1].count};

  g_stop = 1;
  svcSignalEvent(g_mutator_event);
  for (int i = 0; i < count; ++i) {
    threadJoin(threads[i], U64_MAX);
    threadFree(threads[i]);
  }

  // Only events before the stop count; the mutator may run once after stop.
  s_mutator_hb.n = mutator_n;
  if (mutator_gap_now > s_mutator_hb.max_gap_us) s_mutator_hb.max_gap_us = mutator_gap_now;

  const u32 expected = (u32)p->seconds * 1000 / HEARTBEAT_MS;
  stats helper = series_stats(&s_helper_hb);
  stats mutator = series_stats(&s_mutator_hb);
  stats slice = series_stats(&s_slice);
  stats pickup = series_stats(&s_pickup);
  stats echo = series_stats(&s_echo);
  u32 echo_worst = echo.max > outstanding_age_us ? echo.max : outstanding_age_us;
  // A starved heartbeat delivers few beats with small lateness; the gap
  // between beats is then the real jitter.
  u32 mutator_worst = mutator.max > s_mutator_hb.max_gap_us - HEARTBEAT_MS * 1000
                          ? mutator.max
                          : s_mutator_hb.max_gap_us - HEARTBEAT_MS * 1000;
  u32 helper_worst = helper.max > s_helper_hb.max_gap_us - HEARTBEAT_MS * 1000
                         ? helper.max
                         : s_helper_hb.max_gap_us - HEARTBEAT_MS * 1000;
  if (s_mutator_hb.max_gap_us < HEARTBEAT_MS * 1000) mutator_worst = mutator.max;
  if (s_helper_hb.max_gap_us < HEARTBEAT_MS * 1000) helper_worst = helper.max;

  int helper_pass = helper_worst < 100000 && (u32)s_helper_hb.n * 10 >= expected * 9;
  int mutator_pass = mutator_worst < 100000 && (u32)mutator_n * 10 >= expected * 9;
  int echo_pass = sent > 0 && echo_worst <= 200000 && s_echo.n + 1 >= (int)sent && skipped == 0;
  int both_busy = p->busy == 0 ||
                  (progressed[0] * 10 >= windows * 8 && progressed[1] * 10 >= windows * 8);
  int viable = mutator_pass && echo_pass && helper_pass && both_busy;

  say("  helper hb  (0x2F core %ld): beats %d/%lu max %lu.%03lu ms p99 %lu.%03lu ms "
      "mean %lu us gap %lu ms missed %lu",
      s_helper_hb.core, s_helper_hb.n, expected, helper.max / 1000, helper.max % 1000,
      helper.p99 / 1000, helper.p99 % 1000, helper.mean, s_helper_hb.max_gap_us / 1000,
      s_helper_hb.missed);
  say("  mutator hb (0x30 core %ld): beats %d/%lu max %lu.%03lu ms p99 %lu.%03lu ms "
      "mean %lu us gap %lu ms missed %lu",
      s_mutator_hb.core, mutator_n, expected, mutator.max / 1000, mutator.max % 1000,
      mutator.p99 / 1000, mutator.p99 % 1000, mutator.mean, s_mutator_hb.max_gap_us / 1000,
      s_mutator_hb.missed);
  say("  handler slice (0x2F core %ld): wakes %d late max %lu us p99 %lu us; "
      "pickup max %lu ms p99 %lu ms",
      s_slice.core, s_slice.n, slice.max, slice.p99, pickup.max / 1000, pickup.p99 / 1000);
  say("  echo: sent %lu answered %d skipped %lu outstanding %d (age %lu ms) "
      "rtt max %lu ms p99 %lu ms mean %lu ms",
      sent, s_echo.n, skipped, outstanding, outstanding_age_us / 1000, echo.max / 1000,
      echo.p99 / 1000, echo.mean / 1000);
  for (int i = 0; i < p->busy; ++i) {
    say("  busy %c (0x30 core %ld): %lu k-iter (%lu k/s) progressed %d/%d windows yields %lu",
        'A' + i, g_busy[i].core_seen, counts[i], counts[i] / p->seconds, progressed[i], windows,
        g_busy[i].yields);
  }
  say("RESULT policy=%s helper_hb_worst_ms=%lu mutator_hb_worst_ms=%lu mutator_hb_p99_ms=%lu "
      "mutator_beats=%d/%lu handler_pickup_worst_ms=%lu echo_worst_ms=%lu echo_p99_ms=%lu busyA_k=%lu busyB_k=%lu "
      "busyA_windows=%d busyB_windows=%d windows=%d helper_hb=%s mutator_hb=%s echo=%s "
      "busy_both=%s viable=%s",
      p->name, helper_worst / 1000, mutator_worst / 1000, mutator.p99 / 1000, mutator_n,
      expected, pickup.max / 1000, echo_worst / 1000, echo.p99 / 1000, counts[0], counts[1], progressed[0],
      progressed[1], windows, helper_pass ? "PASS" : "FAIL", mutator_pass ? "PASS" : "FAIL",
      echo_pass ? "PASS" : "FAIL", both_busy ? "YES" : "NO",
      p->busy == 0 ? "n/a" : viable ? "YES" : "NO");
  if (p->busy && viable) {
    verdict_count++;
    strncat(viable_names, " ", sizeof(viable_names) - strlen(viable_names) - 1);
    strncat(viable_names, p->name, sizeof(viable_names) - strlen(viable_names) - 1);
  }
}

// ---- Environment: cores, memory, resource limits. ----

static void reslimit(ResourceLimitType type, s64* limit, s64* current) {
  Handle handle = 0;
  *limit = *current = -1;
  if (R_FAILED(svcGetResourceLimit(&handle, CUR_PROCESS_HANDLE))) return;
  svcGetResourceLimitLimitValues(limit, handle, &type, 1);
  svcGetResourceLimitCurrentValues(current, handle, &type, 1);
  svcCloseHandle(handle);
}

static void probe_entry(void* arg) { *(volatile s32*)arg = svcGetProcessorID(); }

static int probe_core(int core, const char* label) {
  static volatile s32 seen[8];
  static int slot;
  volatile s32* out = &seen[slot++ % 8];
  *out = -99;
  Thread t = threadCreate(probe_entry, (void*)out, 4096, HELPER_PRIORITY, core, false);
  if (!t) {
    say("CORE probe=%s core=%d create=FAIL", label, core);
    return 0;
  }
  // A timeout (0x09401BFE) is not R_FAILED, so test for any non-zero result.
  Result joined = threadJoin(t, 2000000000LL);
  if (joined != 0) {
    say("CORE probe=%s core=%d create=ok ran=NO (join timeout; thread leaked)", label, core);
    return 0;
  }
  threadFree(t);
  say("CORE probe=%s core=%d create=ok ran_on=%ld", label, core, *out);
  return *out == core;
}

static void report_environment(void) {
  bool n3ds = false;
  APT_CheckNew3DS(&n3ds);
  s32 main_priority = -1;
  svcGetThreadPriority(&main_priority, CUR_THREAD_HANDLE);
  say("ENV new3ds=%d main_priority=0x%lx main_core=%ld kernel=0x%08lx firm=0x%08lx", n3ds,
      main_priority, svcGetProcessorID(), osGetKernelVersion(), osGetFirmVersion());

  // Memory. libctru maps the free APPLICATION region as heap + linear heap
  // before main, so region "free" reads near zero for a .3dsx; the heap and
  // linear numbers are what the program can still allocate.
  struct mallinfo mi = mallinfo();
  u32 heap_top = (u32)sbrk(0);
  u32 heap_unsbrk = __ctru_heap + __ctru_heap_size - heap_top;
  say("MEM app_memtype=%lu app_region_size=%lu app_region_used=%lu app_region_free=%lu",
      osGetApplicationMemType(), osGetMemRegionSize(MEMREGION_APPLICATION),
      osGetMemRegionUsed(MEMREGION_APPLICATION), osGetMemRegionFree(MEMREGION_APPLICATION));
  say("MEM sys_region_size=%lu base_region_size=%lu all_size=%lu",
      osGetMemRegionSize(MEMREGION_SYSTEM), osGetMemRegionSize(MEMREGION_BASE),
      osGetMemRegionSize(MEMREGION_ALL));
  say("MEM heap_size=%lu linear_heap_size=%lu linear_free=%lu malloc_arena=%lu "
      "malloc_used=%lu malloc_free=%lu heap_unsbrk=%lu heap_available=%lu",
      __ctru_heap_size, __ctru_linear_heap_size, linearSpaceFree(), (u32)mi.arena,
      (u32)mi.uordblks, (u32)mi.fordblks, heap_unsbrk, heap_unsbrk + (u32)mi.fordblks);
  static const struct {
    ResourceLimitType type;
    const char* name;
  } limits[] = {{RESLIMIT_PRIORITY, "priority"}, {RESLIMIT_COMMIT, "commit"},
                {RESLIMIT_THREAD, "thread"},     {RESLIMIT_EVENT, "event"},
                {RESLIMIT_MUTEX, "mutex"},       {RESLIMIT_SEMAPHORE, "semaphore"},
                {RESLIMIT_TIMER, "timer"},       {RESLIMIT_CPUTIME, "cputime"}};
  for (size_t i = 0; i < sizeof(limits) / sizeof(limits[0]); ++i) {
    s64 limit, current;
    reslimit(limits[i].type, &limit, &current);
    say("RESLIMIT %s limit=%lld current=%lld", limits[i].name, limit, current);
  }

  // Cores. Core 1 needs APT_SetAppCpuTimeLimit; core 2 needs exheader flag
  // 0x2000 (or the BASE region); core 3 is not for applications.
  u32 percent = 0;
  Result got = APT_GetAppCpuTimeLimit(&percent);
  say("CPU APT_GetAppCpuTimeLimit -> 0x%08lx percent=%lu", got, percent);
  core1_usable = probe_core(1, "core1-before-limit");
  core2_usable = probe_core(2, "core2");
  probe_core(3, "core3");
  say("CORES core1=%s core2=%s (core 1 is retried after the runs with a CPU time limit)",
      core1_usable ? "usable" : "refused", core2_usable ? "usable" : "refused");
}

// Runs after every measurement: the limit changes process state, the launcher
// never sets it, and it may not be possible to reset it.
static void probe_core1_with_limit(void) {
  if (core1_usable) return;
  u32 percent = 0;
  Result set = APT_SetAppCpuTimeLimit(30);
  Result got = APT_GetAppCpuTimeLimit(&percent);
  say("CPU APT_SetAppCpuTimeLimit(30) -> 0x%08lx; get -> 0x%08lx percent=%lu", set, got, percent);
  core1_usable = probe_core(1, "core1-after-limit");
  say("CORES core1_with_limit=%s", core1_usable ? "usable" : "refused");
}

// Creates blocked threads with 4 KiB stacks until threadCreate fails.
#define BUDGET_CAP 96
static LightEvent budget_release;
static void budget_entry(void* arg) {
  (void)arg;
  LightEvent_Wait(&budget_release);
}

static void measure_thread_budget(void) {
  s64 limit, before, at_failure, after;
  reslimit(RESLIMIT_THREAD, &limit, &before);
  LightEvent_Init(&budget_release, RESET_STICKY);
  static Thread threads[BUDGET_CAP];
  int created = 0;
  while (created < BUDGET_CAP) {
    Thread t = threadCreate(budget_entry, NULL, 4096, MUTATOR_PRIORITY, 0, false);
    if (!t) break;
    threads[created++] = t;
  }
  reslimit(RESLIMIT_THREAD, &limit, &at_failure);
  struct mallinfo mi = mallinfo();
  LightEvent_Signal(&budget_release);
  for (int i = 0; i < created; ++i) {
    threadJoin(threads[i], U64_MAX);
    threadFree(threads[i]);
  }
  reslimit(RESLIMIT_THREAD, &limit, &after);
  say("THREADS limit=%lld in_use_at_start=%lld created_extra=%d in_use_at_failure=%lld "
      "in_use_after_free=%lld capped=%s malloc_free_at_failure=%lu",
      limit, before, created, at_failure, after, created == BUDGET_CAP ? "yes" : "no",
      (u32)mi.fordblks);
}

// Serves the log file to the first TCP client on LOG_PORT, so the result can be
// read from a PC without touching the SD card (the PC connects out, so no host
// firewall rule is needed). Gives up after 90 s or on START.
#define LOG_PORT 17500
static void serve_log(void) {
  static u32* soc_buffer;
  soc_buffer = (u32*)memalign(0x1000, 0x100000);
  if (!soc_buffer || R_FAILED(socInit(soc_buffer, 0x100000))) {
    say("log server: socInit failed");
    return;
  }
  int server = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address = {0};
  address.sin_family = AF_INET;
  address.sin_port = htons(LOG_PORT);
  address.sin_addr.s_addr = INADDR_ANY;
  if (server < 0 || bind(server, (struct sockaddr*)&address, sizeof(address)) < 0 ||
      listen(server, 1) < 0) {
    say("log server: listen failed");
  } else {
    struct in_addr self = {.s_addr = gethostid()};
    say("Serving this log on %s:%d for 90 s (START to skip).", inet_ntoa(self), LOG_PORT);
    fcntl(server, F_SETFL, fcntl(server, F_GETFL, 0) | O_NONBLOCK);
    u64 deadline = osGetTime() + 90000;
    while (aptMainLoop() && osGetTime() < deadline) {
      hidScanInput();
      if (hidKeysDown() & KEY_START) break;
      int client = accept(server, NULL, NULL);
      if (client >= 0) {
        fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) & ~O_NONBLOCK);
        FILE* log = fopen(LOG_PATH, "rb");
        char chunk[1024];
        size_t length;
        while (log && (length = fread(chunk, 1, sizeof(chunk), log)) > 0) {
          send(client, chunk, length, 0);
        }
        if (log) fclose(log);
        shutdown(client, SHUT_RDWR);
        close(client);
        break;
      }
      gspWaitForVBlank();
    }
  }
  if (server >= 0) close(server);
  socExit();
  free(soc_buffer);
}

int main(void) {
  gfxInitDefault();
  consoleInit(GFX_TOP, NULL);
  mkdir("sdmc:/3ds", 0777);
  mkdir(DIR_PATH, 0777);
  remove(LOG_PATH);
  say("dartbrew U4 scheduling spike (log format 1)");
  report_environment();
  measure_thread_budget();

  int total = 0;
  for (int i = 0; i < POLICY_COUNT; ++i) total += policies[i].seconds;
  say("PLAN %d policies, about %d s of runs; main runs at 0x%x and wakes every %d ms; "
      "heartbeat %d ms; handler slice %d ms; thresholds hb<100 ms echo<=200 ms",
      POLICY_COUNT, total, MAIN_RUN_PRIORITY, PEER_TICK_MS, HEARTBEAT_MS, SLICE_MS);

  // Without the event the mutator would spin; without the raised priority main
  // could starve behind the busy threads and never stop the run.
  Result created = svcCreateEvent(&g_mutator_event, RESET_ONESHOT);
  s32 original_priority = 0x30;
  svcGetThreadPriority(&original_priority, CUR_THREAD_HANDLE);
  Result raised = svcSetThreadPriority(CUR_THREAD_HANDLE, MAIN_RUN_PRIORITY);
  s32 run_priority = -1;
  svcGetThreadPriority(&run_priority, CUR_THREAD_HANDLE);
  svcSetThreadPriority(CUR_THREAD_HANDLE, original_priority);
  say("SETUP svcCreateEvent -> 0x%08lx; svcSetThreadPriority(0x%x) -> 0x%08lx reads 0x%lx",
      created, MAIN_RUN_PRIORITY, raised, run_priority);
  if (R_FAILED(created) || !g_mutator_event || run_priority != MAIN_RUN_PRIORITY) {
    say("ERROR setup failed; policy runs skipped");
  } else {
    for (int i = 0; i < POLICY_COUNT && aptMainLoop(); ++i) {
      svcSetThreadPriority(CUR_THREAD_HANDLE, MAIN_RUN_PRIORITY);
      run_policy(&policies[i]);
      svcSetThreadPriority(CUR_THREAD_HANDLE, original_priority);
    }
    svcCloseHandle(g_mutator_event);
  }
  probe_core1_with_limit();
  say("DONE viable_count=%d viable=%s", verdict_count, verdict_count ? viable_names : " none");
  serve_log();
  gfxExit();
  return 0;
}
