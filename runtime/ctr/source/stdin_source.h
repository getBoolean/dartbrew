#ifndef CTR_STDIN_SOURCE_H_
#define CTR_STDIN_SOURCE_H_
#include "sync.h"
#include <cstddef>
#include <cstdint>
namespace ctr {
// A blocking byte stream that can release its readers.
class Source {
 public:
  // Blocks until bytes arrive. Returns the number read (at most |length|), 0
  // once the input has ended or StopReading was called, or -1 with errno set.
  virtual intptr_t Read(uint8_t* buffer, intptr_t length) = 0;
  // Releases waiting readers; later reads return 0.
  virtual void StopReading() = 0;
 protected:
  ~Source() = default;
};
// dart:io's stdin: the host link when one is connected, otherwise the
// software keyboard. One reader at a time; bytes read from the source and
// not yet consumed are kept, since readLineSync reads one byte at a time and
// each host-link read may wait for a poll slice.
class StdinSource {
 public:
  explicit StdinSource(Source& source) : source_(source) {}
  // Any thread: as Source::Read.
  intptr_t Read(uint8_t* buffer, intptr_t length);
  // Ends the input; a reader blocked in Read returns 0.
  void Stop() { source_.StopReading(); }
 private:
  Source& source_;
  Mutex reading_;  // Guards the buffer.
  uint8_t buffered_[4096];
  size_t start_ = 0, end_ = 0;
};
}  // namespace ctr
#endif
