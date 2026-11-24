#include "keyboard.h"
#include "stdin_source.h"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstring>
#include <string>
#include <thread>

namespace {
// Host-link stand-in: what the host sent, delivered in one read.
struct HostLink final : ctr::Source {
  intptr_t Read(uint8_t* buffer, intptr_t length) override {
    ++reads;
    if (sent.empty() || stopped) return 0;
    const size_t count = std::min(sent.size(), static_cast<size_t>(length));
    memcpy(buffer, sent.data(), count);
    sent.erase(0, count);
    return static_cast<intptr_t>(count);
  }
  void StopReading() override { stopped = true; }
  std::string sent;
  int reads = 0;
  bool stopped = false;
};
// stdin.readLineSync(): one byte at a time up to LF; false at end of input.
bool ReadLine(ctr::StdinSource& input, std::string* line) {
  line->clear();
  uint8_t byte;
  while (input.Read(&byte, 1) == 1) {
    if (byte == '\n') return true;
    *line += static_cast<char>(byte);
  }
  return !line->empty();
}
bool Entry(std::string* line) {
  *line = "typed";
  return true;
}
}  // namespace

int main() {
  // Host-link stdin reaches the reader line by line from one link read.
  HostLink link;
  link.sent = "first\nsecond\n";
  ctr::StdinSource from_host(link);
  std::string line;
  assert(ReadLine(from_host, &line) && line == "first");
  assert(ReadLine(from_host, &line) && line == "second");
  assert(link.reads == 1);
  assert(!ReadLine(from_host, &line));
  from_host.Stop();
  assert(link.stopped);

  // Keyboard stdin: the reader waits while the main loop shows the keyboard.
  ctr::Keyboard keyboard(Entry);
  ctr::StdinSource from_keyboard(keyboard);
  std::atomic<bool> finished{false};
  std::string typed;
  std::thread reader([&] {
    assert(ReadLine(from_keyboard, &typed));
    finished = true;
  });
  while (!finished) {
    keyboard.Serve();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  reader.join();
  assert(typed == "typed");

  // Stop releases a reader waiting on the keyboard with the end of input.
  std::thread waiting([&] {
    uint8_t byte;
    assert(from_keyboard.Read(&byte, 1) == 0);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  from_keyboard.Stop();
  waiting.join();
}
