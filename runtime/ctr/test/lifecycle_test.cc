#include "lifecycle.h"
#include <cassert>
#include <optional>
#include <vector>

struct VM : ctr::Application {
  bool bootstrap = true, live = true, error = false;
  int messages = 0;
  // exit(code) during this message: the hook runs, then the isolate unwinds
  // with an error, as Process_Exit does on CTR.
  int exit_at = 0;
  int64_t exit_code = 0;
  ctr::Runner* runner = nullptr;
  std::vector<int> cleanup;
  bool Bootstrap() override { return bootstrap; }
  bool HasLivePorts() override { return live; }
  bool HandleMessage() override {
    ++messages;
    if (messages == exit_at) {
      runner->Exit(exit_code);
      return false;
    }
    if (messages == 2) live = false;
    return !error;
  }
  void StopTimers() override { cleanup.push_back(1); }
  void ShutdownIsolate() override { cleanup.push_back(2); }
};
// dart:io's exitCode as the program left it.
int exit_code_setting = 0;
int ExitCodeSetting() { return exit_code_setting; }
bool Is(const ctr::Completion& completion, ctr::Outcome outcome,
        std::optional<int64_t> exit_code = std::nullopt) {
  return completion.outcome == outcome && completion.exit_code == exit_code;
}
int main() {
  ctr::Runner runner;
  VM vm;
  // Main returning is not a completion signal: the live port survives it.
  runner.Notify(); runner.Notify();
  assert(Is(runner.Run(vm, ExitCodeSetting), ctr::Outcome::pass));
  assert(vm.messages == 2);
  assert((vm.cleanup == std::vector<int>{1, 2}));
  runner.Shutdown(vm);
  assert(vm.cleanup.size() == 2);
  ctr::Runner failed;
  VM partial; partial.bootstrap = false;
  assert(Is(failed.Run(partial, ExitCodeSetting), ctr::Outcome::fail));
  assert((partial.cleanup == std::vector<int>{1, 2}));
  ctr::Runner uncaught;
  VM bad; bad.error = true; uncaught.Notify();
  assert(Is(uncaught.Run(bad, ExitCodeSetting), ctr::Outcome::fail));
  ctr::Runner stopped;
  VM periodic; stopped.RequestStop();
  assert(Is(stopped.Run(periodic, ExitCodeSetting), ctr::Outcome::incomplete));
  assert(periodic.messages == 0 && periodic.live);
  assert(!stopped.exited());

  // exit(0) ends the run as a pass, without handling the pending messages.
  ctr::Runner exiting;
  VM zero; zero.runner = &exiting; zero.exit_at = 1;
  exiting.Notify(); exiting.Notify(); exiting.Notify();
  assert(Is(exiting.Run(zero, ExitCodeSetting), ctr::Outcome::pass, 0));
  assert(zero.messages == 1 && exiting.exited());
  assert((zero.cleanup == std::vector<int>{1, 2}));
  // Any other code fails carrying the code.
  ctr::Runner failing;
  VM three; three.runner = &failing; three.exit_at = 1; three.exit_code = 3;
  failing.Notify();
  assert(Is(failing.Run(three, ExitCodeSetting), ctr::Outcome::fail, 3));
  assert(failing.exited());

  // A program that returns normally with a nonzero exitCode fails carrying it.
  exit_code_setting = 3;
  ctr::Runner returning;
  VM normal; returning.Notify(); returning.Notify();
  assert(Is(returning.Run(normal, ExitCodeSetting), ctr::Outcome::fail, 3));
  // exit(n) decides over exitCode, and exitCode never turns a failure or a
  // stop into a different completion.
  ctr::Runner exit_wins;
  VM exited; exited.runner = &exit_wins; exited.exit_at = 1;
  exit_wins.Notify();
  assert(Is(exit_wins.Run(exited, ExitCodeSetting), ctr::Outcome::pass, 0));
  ctr::Runner still_failed;
  VM error; error.error = true; still_failed.Notify();
  assert(Is(still_failed.Run(error, ExitCodeSetting), ctr::Outcome::fail));
  ctr::Runner still_stopped;
  VM stopping; still_stopped.RequestStop();
  assert(Is(still_stopped.Run(stopping, ExitCodeSetting), ctr::Outcome::incomplete));
}
