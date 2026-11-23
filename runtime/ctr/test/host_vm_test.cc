// Host integration driver for the real VM and dart:io event handler.
// It is not a console launcher or an additional curated acceptance program.
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <thread>
#include <vector>
#include "bin/dart_io_api.h"
#include "embedder.h"

int main(int argc, char** argv) {
  assert(argc == 4 || argc == 5);
  std::ifstream file(argv[1], std::ios::binary);
  std::vector<uint8_t> kernel((std::istreambuf_iterator<char>(file)), {});
  assert(!kernel.empty());
  FILE* config = fopen(argv[2], "r");
  FILE* journal = fopen(argv[3], "a");
  std::string hash(64, 'a');
  ctr::Program program = {nullptr,
                          nullptr,
                          kernel.data(),
                          static_cast<intptr_t>(kernel.size()),
                          {"async", "jit", hash.c_str(), hash.c_str()}};
  ctr::Runner runner;
  ctr::Report report;
  ctr::RunConfig run;
  assert(ctr::ReadConfig(config, &run) &&
         report.Begin(run, journal, program.build));
  fclose(config);
  // One optional VM flag, e.g. --link_natives_lazily to take AOT's native path.
  const char* flag = getenv("CTR_TEST_VM_FLAG");
  char* error = flag ? Dart_SetVMFlags(1, &flag) : Dart_SetVMFlags(0, nullptr);
  if (error) {
    fprintf(stderr, "%s\n", error);
    free(error);
    return 1;
  }
  Dart_InitializeParams params = {};
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  dart::bin::BootstrapDartIo();
  error = Dart_Initialize(&params);
  if (error) {
    fprintf(stderr, "%s\n", error);
    free(error);
    return 1;
  }
  std::thread stop;
  if (argc == 5)
    stop = std::thread([&] {
      getchar();
      runner.RequestStop();
    });
  ctr::Completion completion;
  std::thread owner([&] {
    ctr::Embedder application(program, runner, report);
    completion = runner.Run(application, [] { return 0; });
  });
  owner.join();
  if (stop.joinable()) stop.join();
  dart::bin::CleanupDartIo();
  error = Dart_Cleanup();
  if (error) report.Output(error);
  const ctr::Outcome result = report.End(completion, error == nullptr);
  free(error);
  assert(fclose(journal) == 0);
  return result == ctr::Outcome::pass         ? 0
         : result == ctr::Outcome::incomplete ? 2
                                              : 1;
}
