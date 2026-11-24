#include <cstddef>

#include "embedder.h"
#include "vm/compiler/runtime_api.h"
#include "vm/compiler/runtime_offsets_list.h"
#include "vm/dart_api_state.h"
#include "vm/dart_entry.h"
#include "vm/longjump.h"
#include "vm/native_arguments.h"
#include "vm/native_entry.h"
#include "vm/object.h"
#include "vm/object_store.h"
#include "vm/runtime_entry.h"
#include "vm/symbols.h"
#include "vm/timeline.h"

static_assert(sizeof(ctr::Program) == 32);
static_assert(offsetof(ctr::Program, isolate_data) == 0);
static_assert(offsetof(ctr::Program, isolate_instructions) == 4);
static_assert(offsetof(ctr::Program, kernel) == 8);
static_assert(offsetof(ctr::Program, kernel_size) == 12);
static_assert(offsetof(ctr::Program, build) == 16);
static_assert(sizeof(ctr::BuildIdentity) == 16);
static_assert(offsetof(ctr::BuildIdentity, fixture) == 0);
static_assert(offsetof(ctr::BuildIdentity, mode) == 4);
static_assert(offsetof(ctr::BuildIdentity, compatibility) == 8);
static_assert(offsetof(ctr::BuildIdentity, build_id) == 12);

namespace dart {
namespace expected {
#include "vm/compiler/runtime_offsets_extracted.h"
}

#if defined(DART_PRECOMPILED_RUNTIME)
#define MODE_OFFSETS AOT_OFFSETS_LIST
#define EXPECTED(C, N) expected::AOT_##C##_##N
#else
#define MODE_OFFSETS JIT_OFFSETS_LIST
#define EXPECTED(C, N) expected::C##_##N
#endif

// The SDK's field accessors return constants after optimization but are not
// constexpr. Assert them at assembly time, without executing target code.
#define FIELD(C, N)                                                        \
  asm volatile(".if %c0 != %c1\n.error \"offset mismatch: " #C "::" #N     \
               "\"\n.endif" : : "i"(C::N()), "i"(EXPECTED(C, N)));
#define SIZE(C, N, W) static_assert(sizeof(W) == EXPECTED(C, N), #C "::" #N);
#define CONSTANT(C, N) static_assert(C::N == EXPECTED(C, N), #C "::" #N);
#define SKIP(...)

// The SDK grants this class access to private layout fields.
class OffsetsExtractor {
 public:
  static void Check() {
    MODE_OFFSETS(FIELD, SKIP, SIZE, SKIP, SKIP, SKIP, CONSTANT, SKIP)
    COMMON_OFFSETS_LIST(FIELD, SKIP, SIZE, SKIP, SKIP, SKIP, CONSTANT, SKIP)
  }
};

extern "C" void CheckNativeLayouts() {
  OffsetsExtractor::Check();
}
}  // namespace dart
