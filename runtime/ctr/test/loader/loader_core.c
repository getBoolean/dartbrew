// U5 spike: portable ELF32 ARM shared-object mapper and relocator.
#include "loader_core.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define PAGE 0x1000u
#define PT_LOAD 1u
#define PT_DYNAMIC 2u
#define PF_X 1u
#define PF_W 2u
#define ET_DYN 3u
#define EM_ARM 40u
#define SHN_UNDEF 0u
#define STB_GLOBAL 1u
#define STB_WEAK 2u

enum {
  DT_NULL = 0, DT_PLTRELSZ = 2, DT_HASH = 4, DT_STRTAB = 5, DT_SYMTAB = 6,
  DT_RELA = 7, DT_STRSZ = 10, DT_SYMENT = 11, DT_INIT = 12, DT_REL = 17,
  DT_RELSZ = 18, DT_RELENT = 19, DT_PLTREL = 20, DT_JMPREL = 23,
  DT_INIT_ARRAY = 25, DT_INIT_ARRAYSZ = 27
};

enum {
  R_ARM_ABS32 = 2, R_ARM_GLOB_DAT = 21, R_ARM_JUMP_SLOT = 22,
  R_ARM_RELATIVE = 23
};

static int fail(char* error, const char* format, ...) {
  va_list args;
  va_start(args, format);
  vsnprintf(error, LDR_ERROR_SIZE, format, args);
  va_end(args);
  return 0;
}

static uint32_t rd32(const uint8_t* p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}
static uint16_t rd16(const uint8_t* p) {
  uint16_t v;
  memcpy(&v, p, 2);
  return v;
}
static void wr32(uint8_t* p, uint32_t v) { memcpy(p, &v, 4); }

static uint32_t round_down(uint32_t v) { return v & ~(PAGE - 1u); }
static uint32_t round_up(uint32_t v) { return (v + PAGE - 1u) & ~(PAGE - 1u); }

const char* ldr_relocation_name(uint32_t type) {
  switch (type) {
    case 0: return "R_ARM_NONE";
    case 2: return "R_ARM_ABS32";
    case 3: return "R_ARM_REL32";
    case 13: return "R_ARM_TLS_DESC";
    case 17: return "R_ARM_TLS_DTPMOD32";
    case 18: return "R_ARM_TLS_DTPOFF32";
    case 19: return "R_ARM_TLS_TPOFF32";
    case 20: return "R_ARM_COPY";
    case 21: return "R_ARM_GLOB_DAT";
    case 22: return "R_ARM_JUMP_SLOT";
    case 23: return "R_ARM_RELATIVE";
    case 160: return "R_ARM_IRELATIVE";
    default: return "R_ARM_(unnamed)";
  }
}

// Header fields shared by ldr_plan and ldr_map.
typedef struct {
  uint32_t phoff, phnum;
} header;

static int read_header(const uint8_t* f, size_t n, header* h, char* error) {
  if (n < 52 || memcmp(f, "\x7f" "ELF", 4) != 0) return fail(error, "not an ELF file");
  if (f[4] != 1 || f[5] != 1) return fail(error, "not ELF32 little-endian");
  if (rd16(f + 16) != ET_DYN) return fail(error, "ELF type %u is not ET_DYN", rd16(f + 16));
  if (rd16(f + 18) != EM_ARM) return fail(error, "machine %u is not EM_ARM", rd16(f + 18));
  if ((rd32(f + 36) & 0x400u) == 0) return fail(error, "not a hard-float EABI object");
  h->phoff = rd32(f + 28);
  h->phnum = rd16(f + 44);
  if (rd16(f + 42) != 32 || h->phoff > n || (n - h->phoff) / 32 < h->phnum)
    return fail(error, "program headers out of bounds");
  return 1;
}

int ldr_plan(const uint8_t* f, size_t n, ldr_module* m, char* error) {
  header h;
  memset(m, 0, sizeof(*m));
  if (!read_header(f, n, &h, error)) return 0;
  uint32_t lo = 0xffffffffu, hi = 0;
  for (uint32_t i = 0; i < h.phnum; ++i) {
    const uint8_t* ph = f + h.phoff + 32 * i;
    if (rd32(ph) != PT_LOAD) continue;
    uint32_t vaddr = rd32(ph + 8), memsz = rd32(ph + 20);
    if (vaddr + memsz < vaddr) return fail(error, "segment wraps");
    if (vaddr < lo) lo = vaddr;
    if (vaddr + memsz > hi) hi = vaddr + memsz;
  }
  if (hi == 0) return fail(error, "no PT_LOAD segments");
  m->min_vaddr = round_down(lo);
  m->span = round_up(hi) - m->min_vaddr;
  return 1;
}

// Converts a link-time address to an image offset, checking `size` bytes fit.
static int to_offset(const ldr_module* m, uint32_t vaddr, uint32_t size, uint32_t* out) {
  if (vaddr < m->min_vaddr) return 0;
  uint32_t off = vaddr - m->min_vaddr;
  if (off > m->span || size > m->span - off) return 0;
  *out = off;
  return 1;
}

static void widen(uint32_t* lo, uint32_t* hi, uint32_t a, uint32_t b) {
  if (*lo == *hi) { *lo = a; *hi = b; return; }
  if (a < *lo) *lo = a;
  if (b > *hi) *hi = b;
}

int ldr_map(const uint8_t* f, size_t n, uint8_t* image, uint32_t base,
            ldr_module* m, char* error) {
  header h;
  if (!read_header(f, n, &h, error)) return 0;
  m->image = image;
  m->base = base;
  memset(image, 0, m->span);  // also zeroes .bss (memsz beyond filesz)
  int have_dynamic = 0;
  for (uint32_t i = 0; i < h.phnum; ++i) {
    const uint8_t* ph = f + h.phoff + 32 * i;
    uint32_t type = rd32(ph), offset = rd32(ph + 4), vaddr = rd32(ph + 8);
    uint32_t filesz = rd32(ph + 16), memsz = rd32(ph + 20), flags = rd32(ph + 24);
    if (type == PT_DYNAMIC) {
      if (!to_offset(m, vaddr, filesz, &m->dynamic)) return fail(error, "PT_DYNAMIC out of bounds");
      have_dynamic = 1;
    }
    if (type != PT_LOAD) continue;
    uint32_t dst;
    if (filesz > memsz || offset > n || filesz > n - offset || !to_offset(m, vaddr, memsz, &dst))
      return fail(error, "PT_LOAD %u out of bounds", i);
    memcpy(image + dst, f + offset, filesz);
    uint32_t lo = round_down(dst), hi = round_up(dst + memsz);
    if (flags & PF_X) widen(&m->exec_lo, &m->exec_hi, lo, hi);
    if (flags & PF_W) widen(&m->write_lo, &m->write_hi, lo, hi);
  }
  if (!have_dynamic) return fail(error, "no PT_DYNAMIC");

  uint32_t hash = 0, syment = 16, relent = 8, pltrel = DT_REL;
  int have_hash = 0;
  for (uint32_t off = m->dynamic; off + 8 <= m->span; off += 8) {
    uint32_t tag = rd32(image + off), val = rd32(image + off + 4);
    if (tag == DT_NULL) break;
    switch (tag) {
      case DT_HASH: have_hash = to_offset(m, val, 8, &hash); break;
      case DT_STRTAB: m->strtab = val; break;
      case DT_STRSZ: m->strsz = val; break;
      case DT_SYMTAB: m->symtab = val; break;
      case DT_SYMENT: syment = val; break;
      case DT_REL: m->rel = val; break;
      case DT_RELSZ: m->relsz = val; break;
      case DT_RELENT: relent = val; break;
      case DT_JMPREL: m->jmprel = val; break;
      case DT_PLTRELSZ: m->pltrelsz = val; break;
      case DT_PLTREL: pltrel = val; break;
      case DT_INIT_ARRAY: m->init_array = val; break;
      case DT_INIT_ARRAYSZ: m->init_arraysz = val; break;
      // Ignoring these would silently skip an initializer or misapply addends.
      case DT_INIT: return fail(error, "DT_INIT is not supported (use .init_array)");
      case DT_RELA: return fail(error, "DT_RELA is not supported on ARM");
      default: break;  // DT_NEEDED etc.: imports resolve against the app.
    }
  }
  if (!have_hash) return fail(error, "no DT_HASH (link with --hash-style=sysv)");
  if (syment != 16 || relent != 8 || pltrel != DT_REL) return fail(error, "unexpected dynamic entry sizes");
  m->nsyms = rd32(image + hash + 4);  // nchain == number of dynsym entries
  if (!to_offset(m, m->symtab, m->nsyms * 16, &m->symtab)) return fail(error, "DT_SYMTAB out of bounds");
  if (!to_offset(m, m->strtab, m->strsz, &m->strtab)) return fail(error, "DT_STRTAB out of bounds");
  if (m->relsz && !to_offset(m, m->rel, m->relsz, &m->rel)) return fail(error, "DT_REL out of bounds");
  if (m->pltrelsz && !to_offset(m, m->jmprel, m->pltrelsz, &m->jmprel)) return fail(error, "DT_JMPREL out of bounds");
  if (m->init_arraysz && !to_offset(m, m->init_array, m->init_arraysz, &m->init_array))
    return fail(error, "DT_INIT_ARRAY out of bounds");
  return 1;
}

static const char* sym_name(const ldr_module* m, uint32_t index) {
  uint32_t name = rd32(m->image + m->symtab + 16 * index);
  if (name >= m->strsz) return "(bad name)";
  return (const char*)m->image + m->strtab + name;
}

// Visits both relocation tables; stops when visit returns 0.
typedef int (*visit_fn)(void* state, uint32_t offset, uint32_t info);
static int each_relocation(const ldr_module* m, visit_fn visit, void* state) {
  const uint32_t tables[2][2] = {{m->rel, m->relsz}, {m->jmprel, m->pltrelsz}};
  for (int t = 0; t < 2; ++t) {
    for (uint32_t i = 0; i + 8 <= tables[t][1]; i += 8) {
      const uint8_t* r = m->image + tables[t][0] + i;
      if (!visit(state, rd32(r), rd32(r + 4))) return 0;
    }
  }
  return 1;
}

typedef struct {
  const ldr_module* m;
  char* error;
} check_state;

static int check_one(void* s, uint32_t offset, uint32_t info) {
  check_state* c = s;
  uint32_t type = info & 0xffu, sym = info >> 8;
  if (type != R_ARM_RELATIVE && type != R_ARM_ABS32 && type != R_ARM_GLOB_DAT &&
      type != R_ARM_JUMP_SLOT) {
    fail(c->error, "unsupported relocation %s (type %u) at 0x%x%s%s",
         ldr_relocation_name(type), type, offset, sym ? " for " : "",
         sym ? sym_name(c->m, sym) : "");
    return 0;
  }
  if (sym >= c->m->nsyms) {
    fail(c->error, "relocation at 0x%x names symbol %u of %u", offset, sym, c->m->nsyms);
    return 0;
  }
  return 1;
}

int ldr_check_relocations(const ldr_module* m, char* error) {
  check_state c = {m, error};
  return each_relocation(m, check_one, &c);
}

typedef struct {
  ldr_module* m;
  ldr_resolve_fn resolve;
  void* context;
  char* error;
  size_t length;
  uint32_t missing_count;
  uint32_t missing[64];  // symbol indices already named
} reloc_state;

static void add_missing(reloc_state* r, uint32_t index) {
  uint32_t known = r->missing_count < 64 ? r->missing_count : 64;
  for (uint32_t i = 0; i < known; ++i) {
    if (r->missing[i] == index) return;  // name each symbol once
  }
  if (r->missing_count < 64) r->missing[r->missing_count] = index;
  const char* name = sym_name(r->m, index);
  if (r->length < LDR_ERROR_SIZE) {
    r->length += (size_t)snprintf(r->error + r->length, LDR_ERROR_SIZE - r->length, "%s%s",
                                  r->missing_count ? ", " : "unresolved imports: ", name);
  }
  r->missing_count++;
}

static int apply_one(void* s, uint32_t offset, uint32_t info) {
  reloc_state* r = s;
  ldr_module* m = r->m;
  uint32_t type = info & 0xffu, index = info >> 8, slot;
  if (!to_offset(m, offset, 4, &slot)) {
    fail(r->error, "relocation offset 0x%x out of bounds", offset);
    r->missing_count = 0;
    return 0;
  }
  uint8_t* p = m->image + slot;
  uint32_t bias = m->base - m->min_vaddr;
  if (type == R_ARM_RELATIVE) {
    wr32(p, bias + rd32(p));
    m->count_relative++;
    return 1;
  }
  const uint8_t* sym = m->image + m->symtab + 16 * index;
  uint32_t value = 0;
  if (rd16(sym + 14) != SHN_UNDEF) {
    value = bias + rd32(sym + 4);  // defined in this object
  } else {
    const char* name = sym_name(m, index);
    if (!r->resolve(r->context, name, &value)) {
      if ((sym[12] >> 4) != STB_WEAK) add_missing(r, index);
      value = 0;
    }
  }
  if (type == R_ARM_ABS32) {
    wr32(p, value + rd32(p));  // REL: the addend is in place
    m->count_abs32++;
  } else {
    wr32(p, value);  // GLOB_DAT / JUMP_SLOT: the slot's old value is not an addend
    if (type == R_ARM_GLOB_DAT) m->count_glob_dat++; else m->count_jump_slot++;
  }
  return 1;
}

int ldr_relocate(ldr_module* m, ldr_resolve_fn resolve, void* context, char* error) {
  if (!ldr_check_relocations(m, error)) return 0;
  error[0] = '\0';
  reloc_state r = {m, resolve, context, error, 0, 0, {0}};
  if (!each_relocation(m, apply_one, &r)) return 0;
  return r.missing_count == 0;
}

int ldr_lookup(const ldr_module* m, const char* name, uint32_t* out) {
  for (uint32_t i = 1; i < m->nsyms; ++i) {
    const uint8_t* sym = m->image + m->symtab + 16 * i;
    uint32_t bind = sym[12] >> 4;
    if (rd16(sym + 14) == SHN_UNDEF || (bind != STB_GLOBAL && bind != STB_WEAK)) continue;
    if (strcmp(sym_name(m, i), name) == 0) {
      *out = m->base - m->min_vaddr + rd32(sym + 4);
      return 1;
    }
  }
  return 0;
}

uint32_t ldr_init_count(const ldr_module* m) { return m->init_arraysz / 4; }

uint32_t ldr_init_entry(const ldr_module* m, uint32_t index) {
  return rd32(m->image + m->init_array + 4 * index);
}
