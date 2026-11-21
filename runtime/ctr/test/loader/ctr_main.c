// U5 spike app: loads ELF shared objects from the SD card at runtime.
//
// The two sample objects are embedded in the .3dsx and written to the SD card
// first, so one netloader upload is enough. Every step is logged and the log
// file is closed after each line, so a crash still leaves the last step.
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

#include "loader_core.h"

#define DIR_PATH "sdmc:/3ds/loader-spike"
#define LOG_PATH DIR_PATH "/loader-spike.log"
#define SAMPLE_PATH DIR_PATH "/libsample.so"
#define BAD_PATH DIR_PATH "/libbadreloc.so"
#define PAGE 0x1000u

extern const uint8_t libsample_so[], libsample_so_end[];
extern const uint8_t libbadreloc_so[], libbadreloc_so_end[];

static void say(const char* format, ...) {
  char line[600];
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

// ---- Exports the app offers to loaded objects (KTD11's table, by hand). ----

static int host_log_calls;
static char host_log_last[96];

void host_log(const char* message) {
  host_log_calls++;
  snprintf(host_log_last, sizeof(host_log_last), "%s", message);
  say("  host_log(\"%s\") called", message);
}

int host_value = 1234;

extern int __aeabi_idiv(int, int);

typedef struct {
  const char* name;
  const void* address;
} export_entry;

static const export_entry exports[] = {
    {"host_log", (const void*)host_log},
    {"host_value", &host_value},
    {"__aeabi_idiv", (const void*)__aeabi_idiv},
    {"strlen", (const void*)strlen},
};

static int resolve_export(void* context, const char* name, uint32_t* out) {
  (void)context;
  for (size_t i = 0; i < sizeof(exports) / sizeof(exports[0]); ++i) {
    if (strcmp(exports[i].name, name) == 0) {
      *out = (uint32_t)exports[i].address;
      return 1;
    }
  }
  return 0;
}

// ---- Patch 0009's memory path: Luma SVC 0x80 cache flush + MEMOP_PROT. ----

int32_t SpikeFlushEntireCache(void);
asm(".pushsection .text\n"
    ".arm\n"
    ".balign 4\n"
    ".global SpikeFlushEntireCache\n"
    ".type SpikeFlushEntireCache, %function\n"
    "SpikeFlushEntireCache:\n"
    "push {r4, lr}\n"
    "adr r0, .Lspike_cache_kernel\n"
    "svc 0x80\n"
    "pop {r4, pc}\n"
    ".size SpikeFlushEntireCache, .-SpikeFlushEntireCache\n"
    ".Lspike_cache_kernel:\n"
    "mrs r3, cpsr\n"
    "cpsid aif\n"
    "mov r0, #0\n"
    "mcr p15, 0, r0, c7, c10, 0\n"  // clean D-cache
    "mcr p15, 0, r0, c7, c10, 4\n"  // drain write buffer
    "mcr p15, 0, r0, c7, c5, 0\n"   // invalidate I-cache/branch targets
    "mcr p15, 0, r0, c7, c5, 4\n"   // prefetch flush
    "msr cpsr_c, r3\n"
    "bx lr\n"
    ".popsection\n");

static Result protect(uint32_t address, uint32_t length, uint32_t permissions) {
  Handle process = 0;
  Result result = svcDuplicateHandle(&process, CUR_PROCESS_HANDLE);
  if (R_FAILED(result)) {
    say("  svcDuplicateHandle -> 0x%08lx", result);
    return result;
  }
  result = svcControlProcessMemory(process, address, 0, length, MEMOP_PROT, permissions);
  svcCloseHandle(process);
  return result;
}

// ---- Loading. ----

typedef struct {
  ldr_module module;
  uint8_t* memory;
} loaded;

static uint8_t* read_file(const char* path, size_t* length) {
  FILE* file = fopen(path, "rb");
  if (!file) return NULL;
  fseek(file, 0, SEEK_END);
  long size = ftell(file);
  fseek(file, 0, SEEK_SET);
  uint8_t* data = size > 0 ? malloc((size_t)size) : NULL;
  if (data && fread(data, 1, (size_t)size, file) != (size_t)size) {
    free(data);
    data = NULL;
  }
  fclose(file);
  *length = (size_t)size;
  return data;
}

static int write_file(const char* path, const uint8_t* begin, const uint8_t* end) {
  FILE* file = fopen(path, "wb");
  if (!file) return 0;
  size_t length = (size_t)(end - begin);
  int ok = fwrite(begin, 1, length, file) == length;
  return fclose(file) == 0 && ok;
}

// Maps, checks and relocates. Returns 1, or 0 with `error` set.
static int load(const char* path, loaded* out, char* error) {
  size_t length = 0;
  uint8_t* file = read_file(path, &length);
  if (!file) {
    snprintf(error, LDR_ERROR_SIZE, "cannot read %s", path);
    return 0;
  }
  ldr_module* m = &out->module;
  int ok = ldr_plan(file, length, m, error);
  if (ok) {
    // Whole pages only, so no malloc metadata shares a page we protect.
    out->memory = memalign(PAGE, m->span);
    if (!out->memory) {
      snprintf(error, LDR_ERROR_SIZE, "memalign(0x%lx) failed", (unsigned long)m->span);
      ok = 0;
    }
  }
  if (ok) {
    say("  read %u bytes; span 0x%lx at %p", (unsigned)length, (unsigned long)m->span, out->memory);
    // ldr_relocate rejects unsupported types before resolving any symbol.
    ok = ldr_map(file, length, out->memory, (uint32_t)out->memory, m, error) &&
         ldr_relocate(m, resolve_export, NULL, error);
  }
  free(file);
  if (!ok && out->memory) {
    free(out->memory);
    out->memory = NULL;
  }
  return ok;
}

static int checks_failed;

static void expect(int ok, const char* label) {
  if (!ok) checks_failed++;
  say("%s %s", ok ? "PASS" : "FAIL", label);
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

enum verdict { NO_GO, GO, BLOCKED };

// Text pages made executable, restored to RW before exit as patch 0009 does.
static uint32_t published_text, published_size;

static enum verdict run(void) {
  char error[LDR_ERROR_SIZE];

  int written = write_file(SAMPLE_PATH, libsample_so, libsample_so_end) &&
                write_file(BAD_PATH, libbadreloc_so, libbadreloc_so_end);
  say("Wrote %s (%u bytes) and %s (%u bytes): %s", SAMPLE_PATH,
      (unsigned)(libsample_so_end - libsample_so), BAD_PATH,
      (unsigned)(libbadreloc_so_end - libbadreloc_so), written ? "ok" : "FAILED");
  if (!written) return BLOCKED;  // environment, not a loader result

  // Scenario 3 first: it executes no loaded code.
  say("[3] load libbadreloc.so (expect rejection)");
  loaded bad = {0};
  int bad_loaded = load(BAD_PATH, &bad, error);
  if (!bad_loaded) say("  error: %s", error);
  expect(!bad_loaded && strstr(error, "R_ARM_TLS_DTPMOD32") != NULL,
         "[3] unsupported relocation rejected, naming R_ARM_TLS_DTPMOD32");

  say("load libsample.so");
  loaded sample = {0};
  if (!load(SAMPLE_PATH, &sample, error)) {
    say("NO-GO: load failed: %s", error);
    return NO_GO;
  }
  ldr_module* m = &sample.module;
  say("  relocs: RELATIVE=%lu ABS32=%lu GLOB_DAT=%lu JUMP_SLOT=%lu",
      (unsigned long)m->count_relative, (unsigned long)m->count_abs32,
      (unsigned long)m->count_glob_dat, (unsigned long)m->count_jump_slot);

  // Scenario 3 and loading need no Luma; publishing code does.
  s64 luma = 0;
  Result detected = svcGetSystemInfo(&luma, 0x10000, 0);
  say("Luma3DS detect: result=0x%08lx version=0x%llx", detected, (unsigned long long)luma);
  if (R_FAILED(detected) || luma == 0) {
    say("BLOCKED: Luma3DS custom SVCs not detected; cannot publish code.");
    return BLOCKED;
  }

  // Publish: clean D-cache / invalidate I-cache, then make text executable.
  Result flushed = SpikeFlushEntireCache();
  say("  cache flush (svc 0x80) -> 0x%08lx", flushed);
  if (R_FAILED(flushed)) {
    say("NO-GO: cache flush failed");
    return NO_GO;
  }
  uint32_t text = (uint32_t)sample.memory + m->exec_lo;
  uint32_t text_size = m->exec_hi - m->exec_lo;
  int overlaps = m->write_lo < m->exec_hi && m->exec_lo < m->write_hi && m->write_lo != m->write_hi;
  uint32_t permissions = overlaps ? MEMPERM_READWRITE | MEMPERM_EXECUTE
                                  : MEMPERM_READ | MEMPERM_EXECUTE;
  Result protected = protect(text, text_size, permissions);
  say("  MEMOP_PROT 0x%08lx+0x%lx %s -> 0x%08lx", text, (unsigned long)text_size,
      overlaps ? "RWX" : "RX", protected);
  if (R_FAILED(protected) && !overlaps) {
    // Patch 0009's proven path uses RWX; record whether only that works.
    permissions = MEMPERM_READWRITE | MEMPERM_EXECUTE;
    protected = protect(text, text_size, permissions);
    say("  retry MEMOP_PROT RWX -> 0x%08lx", protected);
  }
  if (R_FAILED(protected)) {
    say("NO-GO: cannot make text executable");
    return NO_GO;
  }
  published_text = text;
  published_size = text_size;

  for (uint32_t i = 0; i < ldr_init_count(m); ++i) {
    uint32_t entry = ldr_init_entry(m, i);
    say("  about to run init_array[%lu] at 0x%08lx", (unsigned long)i, entry);
    ((void (*)(void))entry)();
  }
  say("  init_array done");

  uint32_t addr = 0;
#define LOOKUP(name)                                             \
  if (!ldr_lookup(m, #name, &addr)) {                            \
    say("NO-GO: symbol " #name " not exported");                 \
    return NO_GO;                                                \
  }                                                              \
  say("  about to call " #name " at 0x%08lx", addr);

  LOOKUP(add);
  int calls_before = host_log_calls;
  int sum = ((int (*)(int, int))addr)(2, 3);
  say("  add(2, 3) = %d", sum);
  expect(sum == 5, "[1] add(2, 3) == 5 through a function pointer");
  expect(host_log_calls == calls_before + 1 && strcmp(host_log_last, "libsample: add called") == 0,
         "[2] libsample called the app's host_log");

  LOOKUP(get_initialized);
  expect(((int (*)(void))addr)() == 40, ".init_array ran (get_initialized() == 40)");

  LOOKUP(call_through_pointer);
  calls_before = host_log_calls;
  ((void (*)(void))addr)();
  expect(host_log_calls == calls_before + 1, "R_ARM_ABS32 data pointer to host_log");

  LOOKUP(read_host_value);
  expect(((int (*)(void))addr)() == 1234, "R_ARM_GLOB_DAT import (host_value == 1234)");

  LOOKUP(read_sample_global);
  expect(((int (*)(void))addr)() == 7, "R_ARM_GLOB_DAT local definition (sample_global == 7)");

  LOOKUP(divide);
  expect(((int (*)(int, int))addr)(84, 2) == 42, "libgcc import __aeabi_idiv (84 / 2 == 42)");

  LOOKUP(message_length);
  expect(((int (*)(const char*))addr)("dartbrew") == 8, "newlib import strlen (== 8)");

  LOOKUP(scale);
  expect(((double (*)(double, double))addr)(1.5, 4.0) == 6.0, "VFP hard-float scale(1.5, 4.0) == 6.0");
#undef LOOKUP
  return checks_failed == 0 ? GO : NO_GO;
}

int main(void) {
  gfxInitDefault();
  consoleInit(GFX_TOP, NULL);
  mkdir("sdmc:/3ds", 0777);
  mkdir(DIR_PATH, 0777);
  remove(LOG_PATH);
  say("dartbrew U5 runtime loader spike");
  enum verdict verdict = run();
  static const char* const names[] = {"NO-GO", "GO", "BLOCKED"};
  say("VERDICT: %s (%d check(s) failed)", names[verdict], checks_failed);
  if (published_size) {
    Result restored = protect(published_text, published_size, MEMPERM_READWRITE);
    say("restore text to RW -> 0x%08lx", restored);
  }
  serve_log();
  gfxExit();
  return 0;
}
