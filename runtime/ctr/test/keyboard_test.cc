#include "keyboard.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <string>
#include <thread>

namespace {
int prompts = 0;
bool Entries(std::string* line) {
  ++prompts;
  if (prompts == 1) { *line = "hello"; return true; }
  if (prompts == 2) { *line = ""; return true; }
  return false;  // Cancelled.
}
bool Never(std::string*) {
  assert(false);
  return false;
}
}  // namespace

int main() {
  // A program that never reads never opens the keyboard.
  ctr::Keyboard idle(Never);
  assert(!idle.Serve());

  // Each entry is one line; cancelling ends the input for good.
  ctr::Keyboard keyboard(Entries);
  std::string text;
  std::atomic<bool> finished{false};
  std::thread reader([&] {
    uint8_t buffer[3];
    for (intptr_t got; (got = keyboard.Read(buffer, sizeof(buffer))) > 0;)
      text.append(reinterpret_cast<char*>(buffer), got);
    finished = true;
  });
  // The main loop serves requests as they come.
  while (!finished) {
    keyboard.Serve();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  reader.join();
  assert(text == "hello\n\n");
  assert(prompts == 3);
  uint8_t byte;
  assert(keyboard.Read(&byte, 1) == 0);
  assert(!keyboard.Serve());

  // StopReading releases a waiting reader with the end of input.
  ctr::Keyboard stopped(Never);
  std::thread waiting([&] {
    uint8_t value;
    assert(stopped.Read(&value, 1) == 0);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  stopped.StopReading();
  waiting.join();
}
