#ifndef CTR_LIFECYCLE_H_
#define CTR_LIFECYCLE_H_
#include "sync.h"
#include <cstdint>
#include <optional>
namespace ctr {
enum class Outcome { pass, fail, incomplete };
// How a run ended. exit_code is set when the program ended through exit(),
// or returned normally with a nonzero exitCode; the terminal record carries it.
struct Completion {
  Outcome outcome = Outcome::fail;
  std::optional<int64_t> exit_code;
};
struct Application {
  virtual ~Application() = default;
  virtual bool Bootstrap() = 0;
  virtual bool HasLivePorts() = 0;
  virtual bool HandleMessage() = 0;
  virtual void ShutdownIsolate() = 0;
};
class Runner {
 public:
  void Notify();
  void RequestStop();
  void Fail();
  // dart:io exit(code), called on the isolate thread before the isolate
  // unwinds: the run ends after the current message, without running the
  // pending ones. Code 0 passes; any other code fails carrying it.
  void Exit(int64_t code);
  bool exited() const { return exited_; }
  // Runs the application to its end. exit(n) ends it with n: 0 passes, any
  // other code fails. A program that otherwise passes fails when
  // read_exit_code, which returns dart:io's exitCode, is nonzero.
  Completion Run(Application& application, int (*read_exit_code)());
  void Shutdown(Application& application);
 private:
  Mutex lock_;
  Condition changed_;
  uint64_t pending_ = 0;
  bool stop_ = false, failed_ = false, shutdown_ = false, exited_ = false;
  int64_t exit_code_ = 0;
};
}
#endif
