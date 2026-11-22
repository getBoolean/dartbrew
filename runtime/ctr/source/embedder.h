#ifndef CTR_EMBEDDER_H_
#define CTR_EMBEDDER_H_
#include "dart_api.h"
#include "report.h"
#include "timer_worker.h"
namespace ctr {
// Packaging supplies immutable linked images (AOT) or a retained kernel (JIT).
// All buffers outlive Dart_Cleanup; the embedder does not load dynamic ELF files.
struct Program {
  const uint8_t* isolate_data;
  const uint8_t* isolate_instructions;
  const uint8_t* kernel;
  intptr_t kernel_size;
  BuildIdentity build;
};
class Embedder final : public Application, public TimerTransport {
 public:
  // |script| is dart:io's Platform.script: the application file in the CTR
  // path model ("/3ds/x.3dsx"), or empty when argv names none.
  Embedder(const Program& program, Runner& runner, Report& report,
           const char* script = nullptr)
      : program_(program), runner_(runner), report_(report), script_(script), timers_(*this) {}
  bool Bootstrap() override;
  bool HasLivePorts() override;
  bool HandleMessage() override;
  void StopTimers() override;
  void ShutdownIsolate() override;
  int64_t Now() override;
  bool Post(int64_t port) override;
  void Failed() override { post_failed_ = true; runner_.Fail(); }
 private:
  bool Check(Dart_Handle result);
  static void Notify(Dart_Isolate isolate);
  static Dart_NativeFunction Resolve(Dart_Handle name, int argc, bool* scope);
  static void Schedule(Dart_NativeArguments args);
  static void Clock(Dart_NativeArguments args);
  static void Print(Dart_NativeArguments args);
  static Embedder* Current();
  const Program& program_;
  Runner& runner_;
  Report& report_;
  const char* script_;
  TimerWorker timers_;
  Dart_Isolate isolate_ = nullptr;
  bool post_failed_ = false;  // Read by the owner only after timer-worker join.
};
}
#endif
