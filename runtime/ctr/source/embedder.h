#ifndef CTR_EMBEDDER_H_
#define CTR_EMBEDDER_H_
#include "dart_api.h"
#include "report.h"
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
class Embedder final : public Application {
 public:
  // |script| is dart:io's Platform.script: the application file in the CTR
  // path model ("/3ds/x.3dsx"), or empty when argv names none.
  Embedder(const Program& program,
           Runner& runner,
           Report& report,
           const char* script = nullptr)
      : program_(program), runner_(runner), report_(report), script_(script) {}
  bool Bootstrap() override;
  bool HasLivePorts() override;
  bool HandleMessage() override;
  void ShutdownIsolate() override;

 private:
  bool Check(Dart_Handle result);
  static void Notify(Dart_Isolate isolate);
  static Dart_NativeFunction Resolve(Dart_Handle name, int argc, bool* scope);
  static void Print(Dart_NativeArguments args);
  static Embedder* Current();
  const Program& program_;
  Runner& runner_;
  Report& report_;
  const char* script_;
  Dart_Isolate isolate_ = nullptr;
};
}  // namespace ctr
#endif
