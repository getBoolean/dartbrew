// U5 host driver: runs loader_core.c on the host at a fake 32-bit base so
// host_check.py can compare the relocated image with readelf's view.
//
// usage: host_check FILE.so BASE IMAGE_OUT [name=hexaddr | lookup-name]...
//   name=hexaddr  adds an app export; a bare name is looked up after loading.
// Prints "ok", "counts R A G J", "init ADDR", "lookup NAME ADDR", or
// "error MESSAGE" (exit status 2).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "loader_core.h"

typedef struct {
  int count;
  char** args;
} table;

static int resolve(void* context, const char* name, uint32_t* out) {
  table* t = context;
  size_t len = strlen(name);
  for (int i = 0; i < t->count; ++i) {
    const char* a = t->args[i];
    if (strncmp(a, name, len) == 0 && a[len] == '=') {
      *out = (uint32_t)strtoul(a + len + 1, NULL, 16);
      return 1;
    }
  }
  return 0;
}

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: host_check FILE.so BASE IMAGE_OUT [name=addr|name]...\n");
    return 1;
  }
  FILE* f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 1; }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t* file = malloc((size_t)n);
  if (fread(file, 1, (size_t)n, f) != (size_t)n) { perror("read"); return 1; }
  fclose(f);

  char error[LDR_ERROR_SIZE] = "";
  ldr_module m;
  uint32_t base = (uint32_t)strtoul(argv[2], NULL, 16);
  table t = {argc - 4, argv + 4};
  uint8_t* image = NULL;
  int ok = ldr_plan(file, (size_t)n, &m, error);
  if (ok) {
    image = malloc(m.span);
    ok = ldr_map(file, (size_t)n, image, base, &m, error) &&
         ldr_relocate(&m, resolve, &t, error);
  }
  if (!ok) {
    printf("error %s\n", error);
    return 2;
  }
  FILE* out = fopen(argv[3], "wb");
  fwrite(image, 1, m.span, out);
  fclose(out);
  printf("ok\ncounts %u %u %u %u\n", m.count_relative, m.count_abs32, m.count_glob_dat,
         m.count_jump_slot);
  printf("exec 0x%x 0x%x\n", m.exec_lo, m.exec_hi);
  for (uint32_t i = 0; i < ldr_init_count(&m); ++i) printf("init 0x%x\n", ldr_init_entry(&m, i));
  for (int i = 4; i < argc; ++i) {
    if (strchr(argv[i], '=')) continue;
    uint32_t addr;
    if (ldr_lookup(&m, argv[i], &addr)) printf("lookup %s 0x%x\n", argv[i], addr);
    else printf("lookup %s missing\n", argv[i]);
  }
  return 0;
}
