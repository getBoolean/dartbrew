// U5 sample shared object. Each export exercises one loader path; the comment
// names the relocation the access produces with -fPIC -shared.
#include <string.h>

extern void host_log(const char* message);  // app export: R_ARM_JUMP_SLOT
extern int host_value;                      // app export: R_ARM_GLOB_DAT

// A data pointer to an app function: R_ARM_ABS32.
void (*sample_logger)(const char*) = host_log;

// A global defined here, read through the GOT: R_ARM_GLOB_DAT resolved
// against this object's own definition, not the app table.
int sample_global = 7;

static int initialized;  // set by .init_array (its entry is R_ARM_RELATIVE)

__attribute__((constructor)) static void sample_init(void) { initialized = 40; }

int add(int a, int b) {
  host_log("libsample: add called");
  return a + b;
}

int get_initialized(void) { return initialized; }

void call_through_pointer(void) { sample_logger("libsample: via data pointer"); }

int read_host_value(void) { return host_value; }

int read_sample_global(void) { return sample_global; }

// ARMv6K has no divide instruction: imports libgcc's __aeabi_idiv.
int divide(int a, int b) { return a / b; }

// Imports newlib's strlen.
int message_length(const char* message) { return (int)strlen(message); }

// VFP hard-float argument and return registers across the boundary.
double scale(double a, double b) { return a * b; }
