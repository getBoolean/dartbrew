#ifndef CTR_PRIORITIES_H_
#define CTR_PRIORITIES_H_
#include <cstdint>
namespace ctr {
// Thread priorities on the console; a lower number runs first, and the
// scheduler does not time-slice threads of equal priority.
// The main thread, Dart threads and native workers.
constexpr int32_t kApplicationPriority = 0x30;
// Threads that must preempt a CPU-bound program at kApplicationPriority: the
// host-link keepalive and dart:io's event handler (patch 0035).
constexpr int32_t kServicePriority = kApplicationPriority - 1;
}  // namespace ctr
#endif
