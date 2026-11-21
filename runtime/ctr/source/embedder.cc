#include "embedder.h"
#include "dart_native_api.h"
#include <cstdlib>
#include <cstring>
#if defined(__3DS__)
#include "bin/dart_io_api.h"
#else
#include <chrono>
#include "unsupported.h"
#endif
namespace ctr {
static Dart_Handle String(const char* text) { return Dart_NewStringFromCString(text); }
static Dart_Handle Library(const char* uri) { return Dart_LookupLibrary(String(uri)); }
static Dart_Handle Call(Dart_Handle library, const char* name, int argc = 0, Dart_Handle* argv = nullptr) {
  if (Dart_IsError(library)) return library;
  return Dart_Invoke(library, String(name), argc, argv);
}
Embedder* Embedder::Current() {
  return static_cast<Embedder*>(Dart_IsolateData(Dart_CurrentIsolate()));
}
void Embedder::Notify(Dart_Isolate isolate) {
  auto* self = static_cast<Embedder*>(Dart_IsolateData(isolate));
  self->runner_.Notify();
}
bool Embedder::Check(Dart_Handle result) {
  if (!Dart_IsError(result)) return true;
  // Dart_GetError includes the exception and stack for unhandled Dart errors.
  report_.Output(Dart_GetError(result));
  return false;
}
bool Embedder::Bootstrap() {
  char* error = nullptr;
  Dart_IsolateFlags flags;
  Dart_IsolateFlagsInitialize(&flags);
#if defined(DART_PRECOMPILED_RUNTIME)
  isolate_ = Dart_CreateIsolateGroup("ctr:application", "application",
        program_.isolate_data, program_.isolate_instructions, &flags, this, this, &error);
#else
  isolate_ = Dart_CreateIsolateGroupFromKernel("ctr:application", "application",
        program_.kernel, program_.kernel_size, &flags, this, this, &error);
#endif
  if (!isolate_) {
    report_.Output(error ? error : "isolate creation failed");
    free(error);
    return false;
  }
  Dart_SetCurrentThreadOwnsIsolate();
  Dart_EnterScope();
  Dart_SetMessageNotifyCallback(Notify);
  if (!timers_.Start()) { report_.Output("timer worker creation failed"); return false; }
  if (!Check(Dart_FinalizeLoading(false))) return false;
  Dart_Handle hooks = Library("dart:_ctr");
  if (!Check(hooks) || !Check(Dart_SetNativeResolver(hooks, Resolve, nullptr)) ||
      !Check(Call(hooks, "_installHooks"))) return false;
  Dart_Handle isolate = Library("dart:isolate");
  if (!Check(Call(isolate, "_setupHooks"))) return false;
  Dart_Handle immediate = Call(isolate, "_getIsolateScheduleImmediateClosure");
  if (!Check(immediate) || !Check(Call(Library("dart:async"), "_setScheduleImmediateClosure", 1, &immediate))) return false;
  Dart_Handle print = Call(hooks, "_getPrintClosure");
  if (!Check(print) || !Check(Dart_SetField(Library("dart:_internal"), String("_printClosure"), print))) return false;
  Dart_Handle uri_base = Call(hooks, "_getUriBaseClosure");
  if (!Check(uri_base) || !Check(Dart_SetField(Library("dart:core"), String("_uriBaseClosure"), uri_base))) return false;
#if !defined(DART_PRECOMPILED_RUNTIME)
  if (!Check(Dart_LoadScriptFromKernel(program_.kernel, program_.kernel_size))) return false;
#endif
  // An AOT image may omit an unused dart:io; then nothing can call its natives,
  // and timers stay on the _ctr hooks' worker.
  Dart_Handle io = Library("dart:io");
  if (!Dart_IsError(io)) {
#if defined(__3DS__)
    // The SDK's own dart:io setup: the ported I/O layer's natives, and io's
    // _setupHooks, which moves timers from the _ctr hooks to the dart:io event
    // handler. print and Uri.base keep the _ctr closures set above.
    dart::bin::DartIoSettings settings;
    // exit() would reach Platform::_Exit, which is not ported yet; this makes
    // it throw a catchable UnsupportedError in Dart first.
    settings.disable_exit = true;
    // There is no VM service to register the extension with.
    settings.enable_network_profiling = false;
    if (!Check(dart::bin::SetupDartIoLibrary(settings))) return false;
#else
    // Host drivers have no CTR I/O layer: every dart:io native is unsupported.
    if (!Check(Dart_SetNativeResolver(io, ResolveUnsupported, nullptr))) return false;
#endif
  }
  Dart_Handle main = Dart_GetField(Dart_RootLibrary(), String("main"));
  if (!Check(main)) return false;
  Dart_Handle string_type = Dart_GetNonNullableType(Library("dart:core"), String("String"), 0, nullptr);
  if (!Check(string_type)) return false;
  Dart_Handle arguments = Dart_NewListOfType(string_type, 0);
  if (!Check(arguments)) return false;
  Dart_Handle args[] = {main, arguments};
  // Schedule main as a VM message, so the VM drains its microtasks too.
  if (!Check(Call(isolate, "_startMainIsolate", 2, args))) return false;
  Dart_ExitScope();
  Dart_ExitIsolate();
  error = Dart_IsolateMakeRunnable(isolate_);
  Dart_EnterIsolate(isolate_);
  if (error) { report_.Output(error); free(error); return false; }
  return true;
}
bool Embedder::HasLivePorts() { return Dart_HasLivePorts(); }
bool Embedder::HandleMessage() {
  Dart_EnterScope();
  bool ok = Check(Dart_HandleMessage());
  Dart_ExitScope();
  return ok;
}
void Embedder::StopTimers() {
  timers_.Stop();
  if (post_failed_) report_.Output("native timer message publication failed");
}
void Embedder::ShutdownIsolate() {
  if (!isolate_) return;
  Dart_SetMessageNotifyCallback(nullptr);
  // Shutdown closes every remaining port and exits any partial bootstrap scope.
  Dart_ShutdownIsolate();
  isolate_ = nullptr;
}
int64_t Embedder::Now() {
#if defined(__3DS__)
  const int64_t ticks = svcGetSystemTick();
  return (ticks / SYSCLOCK_ARM11) * 1000 + (ticks % SYSCLOCK_ARM11) * 1000 / SYSCLOCK_ARM11;
#else
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
#endif
}
bool Embedder::Post(int64_t port) {
  Dart_CObject message = {};
  message.type = Dart_CObject_kNull;
  return Dart_PostCObject(port, &message);
}
static void Propagate(Dart_Handle handle) {
  if (Dart_IsError(handle)) Dart_PropagateError(handle);
}
void Embedder::Schedule(Dart_NativeArguments args) {
  Dart_Port port;
  int64_t deadline;
  Propagate(Dart_SendPortGetId(Dart_GetNativeArgument(args, 1), &port));
  Propagate(Dart_IntegerToInt64(Dart_GetNativeArgument(args, 2), &deadline));
  if (!Current()->timers_.Schedule(port, deadline))
    Dart_PropagateError(Dart_NewApiError("CTR timer scheduling failed"));
  Dart_SetReturnValue(args, Dart_Null());
}
void Embedder::Clock(Dart_NativeArguments args) {
  Dart_SetReturnValue(args, Dart_NewInteger(Current()->Now()));
}
void Embedder::Print(Dart_NativeArguments args) {
  const char* text;
  Propagate(Dart_StringToCString(Dart_GetNativeArgument(args, 0), &text));
  Current()->report_.Output(text);
  Dart_SetReturnValue(args, Dart_Null());
}
Dart_NativeFunction Embedder::Resolve(Dart_Handle name, int argc, bool* scope) {
  const char* text;
  if (Dart_IsError(Dart_StringToCString(name, &text))) return nullptr;
  *scope = true;
  if (argc == 3 && !strcmp(text, "CTR_TimerSchedule")) return Schedule;
  if (argc == 0 && !strcmp(text, "CTR_TimerClock")) return Clock;
  if (argc == 1 && !strcmp(text, "CTR_Print")) return Print;
  return nullptr;
}
}
