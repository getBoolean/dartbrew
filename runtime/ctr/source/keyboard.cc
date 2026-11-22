#include "keyboard.h"
#include <algorithm>
#include <cstring>
namespace ctr {
Keyboard::Keyboard(Prompt prompt) : prompt_(prompt) {}
intptr_t Keyboard::Read(uint8_t* buffer, intptr_t length) {
  Lock lock(mutex_);
  while (offset_ >= line_.size() && !ended_) {
    requested_ = true;
    changed_.Signal();
    changed_.Wait(mutex_);
  }
  if (offset_ >= line_.size() || length <= 0) return 0;
  const size_t count = std::min(line_.size() - offset_, static_cast<size_t>(length));
  memcpy(buffer, line_.data() + offset_, count);
  offset_ += count;
  return static_cast<intptr_t>(count);
}
bool Keyboard::Serve() {
  {
    Lock lock(mutex_);
    if (!requested_ || ended_) return false;
  }
  // The applet blocks this thread until the entry is done; readers keep
  // waiting meanwhile.
  std::string line;
  const bool entered = prompt_(&line);
  Lock lock(mutex_);
  requested_ = false;
  if (!entered) ended_ = true;
  else if (!ended_) {
    line_ = line + "\n";
    offset_ = 0;
  }
  changed_.Signal();
  return true;
}
void Keyboard::Stop() {
  Lock lock(mutex_);
  ended_ = true;
  changed_.Signal();
}
#if defined(__3DS__)
bool Keyboard::SystemPrompt(std::string* line) {
  SwkbdState keyboard;
  swkbdInit(&keyboard, SWKBD_TYPE_NORMAL, 2, -1);
  // An empty line is input too.
  swkbdSetValidation(&keyboard, SWKBD_ANYTHING, 0, 0);
  swkbdSetHintText(&keyboard, "stdin (Cancel ends input)");
  static char text[2048];
  // Cancel, and conditions such as the HOME menu (SWKBD_BUTTON_NONE), end input.
  if (swkbdInputText(&keyboard, text, sizeof(text)) != SWKBD_BUTTON_CONFIRM) return false;
  *line = text;
  return true;
}
#endif
}
