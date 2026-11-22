#include "stdin_source.h"
#include <algorithm>
#include <cstring>
namespace ctr {
intptr_t StdinSource::Read(uint8_t* buffer, intptr_t length) {
  Lock lock(reading_);
  if (start_ == end_) {
    const intptr_t received = source_.Read(buffered_, sizeof(buffered_));
    if (received <= 0) return received;
    start_ = 0;
    end_ = static_cast<size_t>(received);
  }
  const size_t count = std::min(end_ - start_, static_cast<size_t>(length));
  memcpy(buffer, buffered_ + start_, count);
  start_ += count;
  return static_cast<intptr_t>(count);
}
}  // namespace ctr
