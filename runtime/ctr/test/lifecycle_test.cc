#include "lifecycle.h"
#include <cassert>
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
int main() {
  ctr::Runner runner;
  VM vm;
  // Main returning is not a completion signal: the live port survives it.
  runner.Notify(); runner.Notify();
  assert(runner.Run(vm) == ctr::Outcome::pass);
  assert(vm.messages == 2);
  assert((vm.cleanup == std::vector<int>{1, 2}));
  runner.Shutdown(vm);
  assert(vm.cleanup.size() == 2);
  ctr::Runner failed;
  VM partial; partial.bootstrap = false;
  assert(failed.Run(partial) == ctr::Outcome::fail);
  assert((partial.cleanup == std::vector<int>{1, 2}));
  ctr::Runner uncaught;
  VM bad; bad.error = true; uncaught.Notify();
  assert(uncaught.Run(bad) == ctr::Outcome::fail);
  ctr::Runner stopped;
  VM periodic; stopped.RequestStop();
  assert(stopped.Run(periodic) == ctr::Outcome::incomplete);
  assert(periodic.messages == 0 && periodic.live);
  assert(!stopped.exited());

  // exit(0) ends the run as a pass, without handling the pending messages.
  ctr::Runner exiting;
  VM zero; zero.runner = &exiting; zero.exit_at = 1;
  exiting.Notify(); exiting.Notify(); exiting.Notify();
  assert(exiting.Run(zero) == ctr::Outcome::pass);
  assert(zero.messages == 1 && exiting.exited() && exiting.exit_code() == 0);
  assert((zero.cleanup == std::vector<int>{1, 2}));
  // Any other code fails carrying the code.
  ctr::Runner failing;
  VM three; three.runner = &failing; three.exit_at = 1; three.exit_code = 3;
  failing.Notify();
  assert(failing.Run(three) == ctr::Outcome::fail);
  assert(failing.exited() && failing.exit_code() == 3);
}
