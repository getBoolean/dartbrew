#include <3ds.h>
#include <algorithm>
#include <arpa/inet.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <unistd.h>
#include "bin/dart_io_api.h"
#include "embedder.h"
#include "input.h"
#include "keyboard.h"
#include "link.h"
#include "storage.h"
#include "vm/os.h"
#include "vm/os_thread.h"

// Supplied by the AOT/JIT packaging layer. Linked image/kernel ownership remains
// with that layer until this launcher has joined the runner and cleaned the VM.
extern const ctr::Program ctr_program;
// Reserve real main-stack space for VM initialization; measure it on the device.
extern "C" { u32 __stacksize__ = 512 * 1024; }

namespace {
// dart:io's Directory.systemTemp: a folder on the SD card cleared at start.
constexpr char kTemp[] = "sdmc:/dartbrew/tmp";
constexpr char kTempDart[] = "/dartbrew/tmp";
struct Run {
  ctr::Runner runner;
  ctr::Report report;
  ctr::Outcome outcome = ctr::Outcome::fail;
  // Set when the program ended through exit() or a nonzero exitCode.
  std::optional<int64_t> exit_code;
  std::string script;
  std::atomic<bool> done{false};
  dart::ThreadJoinId join = dart::OSThread::kInvalidThreadJoinId;
};
void Execute(dart::uword parameter) {
  auto* run = reinterpret_cast<Run*>(parameter);
  run->join = dart::OSThread::GetCurrentThreadJoinId(dart::OSThread::Current());
  ctr::Embedder application(ctr_program, run->runner, run->report, run->script.c_str());
  run->outcome = run->runner.Run(application);
  if (run->runner.exited()) {
    run->exit_code = run->runner.exit_code();
  } else if (run->outcome == ctr::Outcome::pass) {
    // As on other platforms, a program that sets exitCode ends with it.
    if (const int code = dart::bin::GetExitCode()) {
      run->exit_code = code;
      run->outcome = ctr::Outcome::fail;
    }
  }
  run->done.store(true, std::memory_order_release);
}
// dart:io's standard streams (SetCtrStdio) and exit() (SetExitHook) reach the
// run through these. stdin comes from the host link when one is connected,
// and from the software keyboard otherwise (R3).
struct Streams {
  ctr::Report* report = nullptr;
  ctr::Link* link = nullptr;
  ctr::Keyboard* keyboard = nullptr;
  ctr::Runner* runner = nullptr;
  ctr::Mutex reading;  // One stdin reader at a time; guards the buffer.
  // Bytes received from the host and not read yet: readLineSync reads one
  // byte at a time, and each link read may wait for a poll slice.
  uint8_t buffered[4096];
  size_t start = 0, end = 0;
} streams;
bool WriteStdio(intptr_t fd, const uint8_t* buffer, intptr_t length) {
  streams.report->Stdio(static_cast<int>(fd), reinterpret_cast<const char*>(buffer),
                        static_cast<size_t>(length));
  return true;
}
intptr_t ReadStdin(uint8_t* buffer, intptr_t length) {
  // Show a prompt written without a newline before waiting for input.
  streams.report->Flush();
  ctr::Lock lock(streams.reading);
  if (!streams.link) return streams.keyboard->Read(buffer, length);
  if (streams.start == streams.end) {
    const intptr_t received = streams.link->Read(streams.buffered, sizeof(streams.buffered));
    if (received <= 0) return received;
    streams.start = 0;
    streams.end = static_cast<size_t>(received);
  }
  const size_t count = std::min(streams.end - streams.start, static_cast<size_t>(length));
  memcpy(buffer, streams.buffered + streams.start, count);
  streams.start += count;
  return static_cast<intptr_t>(count);
}
void Exited(int64_t code) { streams.runner->Exit(code); }
// Dart threads and this main thread both run at priority 0x30 on core 0, and
// the scheduler does not time-slice equal priorities, so a CPU-bound program
// would starve a main-loop keepalive. A higher-priority thread preempts it.
constexpr s32 kKeepalivePriority = 0x2F;
void SendKeepalives(void* parameter) {
  auto* run = static_cast<Run*>(parameter);
  while (!run->done.load(std::memory_order_acquire)) {
    svcSleepThread(2000000000LL);
    if (!run->done.load(std::memory_order_acquire)) run->report.Keepalive();
  }
}
bool Entropy(uint8_t* buffer, intptr_t length) {
  return dart::OS::GetEntropy(buffer, length);
}
}
int main(int argc, char** argv) {
  gfxInitDefault();
  consoleInit(GFX_TOP, nullptr);
  Result filesystem = fsInit();
  if (R_FAILED(filesystem)) { gfxExit(); return 1; }
  Run run;
  // Directory.current starts in the application's folder from argv[0], or at
  // the SD card root when argv names none (KTD6).
  const char* executable = argc > 0 ? argv[0] : nullptr;
  const std::string folder = ctr::AppFolder(executable);
  const bool in_folder = chdir(folder.empty() ? "sdmc:/" : folder.c_str()) == 0;
  // Platform.script and Platform.executable: the application file, in the
  // path model's form for the script. Without argv both are empty, and
  // Platform.script is then Uri.base.
  if (!folder.empty()) run.script = executable + strlen("sdmc:");
  else if (executable) run.script = executable;
  // libctru's default argv setup moved the netloader's trailing host token into
  // __3dslink_host (zero for SD-card and Azahar launches).
  uint8_t link_host[4];
  memcpy(link_host, &__3dslink_host.s_addr, sizeof(link_host));
  ctr::RunConfig identity;
  ctr::ArgIdentity from_args = ctr::ReadArgs(argc, argv, ctr_program.build, link_host, &identity);
  bool identified = from_args == ctr::ArgIdentity::ok;
  if (from_args == ctr::ArgIdentity::absent) {
    FILE* config = fopen("sdmc:/ctr-runtime-run.cfg", "r");
    identified = ctr::ReadConfig(config, &identity);
    if (config) fclose(config);
  }
  // Connect before begin so every record reaches the host; a connect failure is
  // reported as the first output record once begin has succeeded. Only the
  // link uses soc:U today; dart:io's event handler makes no soc calls until
  // sockets are registered with it.
  ctr::SocketService sockets;
  ctr::Link link;
  std::string link_error;
  if (identified && identity.host) {
    sockets.Start();
    if (link.Open(sockets, identity.address, identity.port, &link_error))
      run.report.Attach(&link);
  }
  FILE* journal = fopen("sdmc:/ctr-runtime.log", "a");
  bool began = identified && run.report.Begin(identity, journal, ctr_program.build, link_error);
  bool initialized = false, io = false, cleanup = true;
  ctr::Input input;
  ctr::Keyboard keyboard(ctr::Keyboard::SystemPrompt);
  streams.report = &run.report;
  streams.link = link.connected() ? &link : nullptr;
  streams.keyboard = &keyboard;
  streams.runner = &run.runner;
  if (began) {
    if (!in_folder) run.report.Output("CTR working directory could not be set");
    if (!ctr::ClearDirectory(kTemp))
      run.report.Output("CTR temporary directory sdmc:/dartbrew/tmp could not be cleared");
    const bool input_ready = input.Start();
    if (!input_ready) {
      char message[160];
      snprintf(message, sizeof(message),
               "CTR input initialization failed: result=0x%08x shared_memory=%p",
               static_cast<unsigned int>(input.status()),
               static_cast<void*>(const_cast<u32*>(hidSharedMem)));
      run.report.Output(message);
    }
    const bool precompiled = Dart_IsPrecompiledRuntime();
    bool mode = !strcmp(ctr_program.build.mode, precompiled ? "aot" : "jit");
    const bool start = mode && input_ready;
    // Match the SDK AOT launcher: stack walking and native linking use this mode.
    const char* aot_flags[] = {"--precompilation"};
    char* error = start ? Dart_SetVMFlags(precompiled ? 1 : 0,
                                          precompiled ? aot_flags : nullptr) : nullptr;
    if (!mode) run.report.Output("artifact mode differs from linked runtime");
    if (error) { run.report.Output(error); free(error); }
    else if (start) {
      // dart:io's event handler thread, started before the VM as the SDK's
      // embedder does.
      dart::bin::SetExecutableName(executable ? executable : "");
      dart::bin::SetSystemTempDirectory(kTempDart);
      dart::bin::SetCtrStdio({WriteStdio, ReadStdin});
      dart::bin::SetExitHook(Exited);
      dart::bin::BootstrapDartIo();
      io = true;
      Dart_InitializeParams params = {};
      params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
      params.entropy_source = Entropy;
      // No service/kernel isolate or executable-page probe.
      error = Dart_Initialize(&params);
      if (error) { run.report.Output(error); free(error); }
      else initialized = true;
    }
    if (initialized) {
      if (dart::OSThread::TryStart("CTR application", Execute,
                                  reinterpret_cast<dart::uword>(&run)) != 0) {
        run.report.Output("application runner creation failed");
      } else {
        bool input_lost = false;
        Thread keepalives = threadCreate(SendKeepalives, &run, 4 * 1024,
                                         kKeepalivePriority, 0, false);
        // Stopping also ends stdin, so a program blocked reading it returns.
        auto end_input = [&] { keyboard.Stop(); link.StopReading(); };
        while (!run.done.load(std::memory_order_acquire)) {
          if (!aptMainLoop()) { run.runner.RequestStop(); end_input(); }
          else if (!input_lost) {
            u32 keys = 0;
            if (!input.Poll(&keys)) {
              input_lost = true;
              cleanup = false;
              run.runner.Fail();
              end_input();
            } else if (keys & KEY_START) { run.runner.RequestStop(); end_input(); }
          }
          // A stdin read without a host link opens the keyboard here.
          keyboard.Serve();
          gspWaitForVBlank();
        }
        dart::OSThread::Join(run.join);
        if (keepalives) {
          threadJoin(keepalives, U64_MAX);
          threadFree(keepalives);
        }
        if (input_lost)
          run.report.Output("CTR input shared memory became unavailable");
      }
      // The isolate is gone: release dart:io threads still waiting for stdin,
      // then stop the event handler before the VM, so no late timer or socket
      // event posts into a VM being torn down.
      keyboard.Stop();
      link.StopReading();
      dart::bin::CleanupDartIo();
      io = false;
      error = Dart_Cleanup();
      if (error) { cleanup = false; run.report.Output(error); free(error); }
    }
    if (io) dart::bin::CleanupDartIo();
    input.Stop();
    run.outcome = run.report.End(run.outcome, cleanup, run.exit_code);
  }
  run.report.Attach(nullptr);
  link.Close();
  sockets.Stop();
  if (journal && fclose(journal)) run.outcome = ctr::Outcome::fail;
  fsExit();
  gfxExit();
  return began && run.outcome == ctr::Outcome::pass ? 0 : 1;
}
