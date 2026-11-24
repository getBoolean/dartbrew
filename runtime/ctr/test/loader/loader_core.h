// U5 spike: portable ELF32 ARM shared-object mapper and relocator.
//
// The core never converts pointers to target addresses. The caller supplies
// the image buffer and the 32-bit address that buffer has in the target
// process. On the console the two are the same memory; the host check maps at
// a fake base so the same code runs on a 64-bit host.
#ifndef LOADER_CORE_H_
#define LOADER_CORE_H_

#include <stddef.h>
#include <stdint.h>

#define LDR_ERROR_SIZE 512

// Returns 1 and stores the address when the app exports `name`.
typedef int (*ldr_resolve_fn)(void* context, const char* name, uint32_t* out);

typedef struct {
  // Filled by ldr_plan.
  uint32_t min_vaddr;  // page-aligned lowest PT_LOAD address
  uint32_t span;       // whole pages covering every PT_LOAD

  // Filled by ldr_map.
  uint8_t* image;
  uint32_t base;  // target address of image[0]
  uint32_t dynamic, symtab, strtab, strsz, nsyms;
  uint32_t rel, relsz, jmprel, pltrelsz;
  uint32_t init_array, init_arraysz;
  // Page-aligned [lo, hi) image offsets of the executable and writable
  // PT_LOAD ranges; equal values mean none.
  uint32_t exec_lo, exec_hi, write_lo, write_hi;

  // Filled by ldr_relocate.
  uint32_t count_relative, count_abs32, count_glob_dat, count_jump_slot;
} ldr_module;

// Validates the ELF header and computes the span the caller must allocate.
int ldr_plan(const uint8_t* file, size_t length, ldr_module* module, char* error);

// Copies PT_LOAD segments into `image` (span bytes, zeroed here) and reads
// PT_DYNAMIC.
int ldr_map(const uint8_t* file, size_t length, uint8_t* image, uint32_t base,
            ldr_module* module, char* error);

// Rejects any relocation type the prototype does not handle, naming it.
int ldr_check_relocations(const ldr_module* module, char* error);

// Applies every relocation. Undefined symbols resolve through `resolve`;
// all missing non-weak symbols are named in the error.
int ldr_relocate(ldr_module* module, ldr_resolve_fn resolve, void* context,
                 char* error);

// Finds an exported (defined, global or weak) dynamic symbol.
int ldr_lookup(const ldr_module* module, const char* name, uint32_t* out);

// Number of .init_array entries and the target address of entry `index`.
uint32_t ldr_init_count(const ldr_module* module);
uint32_t ldr_init_entry(const ldr_module* module, uint32_t index);

const char* ldr_relocation_name(uint32_t type);

#endif  // LOADER_CORE_H_
