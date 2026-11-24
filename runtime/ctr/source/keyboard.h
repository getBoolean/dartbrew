#ifndef CTR_KEYBOARD_H_
#define CTR_KEYBOARD_H_
#include "stdin_source.h"
#include "sync.h"
#include <cstddef>
#include <cstdint>
#include <string>
namespace ctr {
// stdin from the system software keyboard applet when no host is connected:
// one line per entry, ending with LF. The applet runs on the main thread, so
// a reader asks the main loop for a line and waits; the keyboard opens only
// when the program reads. Cancelling the keyboard ends the input.
class Keyboard final : public Source {
 public:
  // Shows the keyboard and stores the entered text in |line|; false when
  // the entry was cancelled.
  using Prompt = bool (*)(std::string* line);
  explicit Keyboard(Prompt prompt);
  // Any thread: blocks until entered bytes are available. Returns the number
  // copied (at most |length|), or 0 once the input has ended.
  intptr_t Read(uint8_t* buffer, intptr_t length) override;
  // Main loop: shows the keyboard when a reader waits. Returns whether it did.
  bool Serve();
  // Ends the input: waiting and later reads return 0.
  void StopReading() override;
  // The system applet (CTR builds only).
  static bool SystemPrompt(std::string* line);
 private:
  Prompt prompt_;
  Mutex mutex_;
  Condition changed_;
  std::string line_;  // The current entry; offset_ bytes are already read.
  size_t offset_ = 0;
  bool requested_ = false, ended_ = false;
};
}
#endif
