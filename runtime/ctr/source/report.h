#ifndef CTR_REPORT_H_
#define CTR_REPORT_H_
#include "lifecycle.h"
#include "link.h"
#include "sync.h"
#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>
namespace ctr {
struct BuildIdentity {
  const char* fixture;
  const char* mode;
  const char* compatibility;
  const char* build_id;
};
// Run identity in record key order: schema, run_id, fixture, mode,
// compatibility, artifact_sha256, build_id, environment; plus the optional host.
struct RunConfig {
  std::string values[8];
  bool host = false;
  uint8_t address[4] = {};
  uint16_t port = 0;
};
// Reads sdmc:/ctr-runtime-run.cfg syntax: eight key lines, then for schema 2
// one optional host=<ipv4>:<port> line. Values are validated by Report::Begin.
bool ReadConfig(FILE* config, RunConfig* run);
enum class ArgIdentity { absent, ok, invalid };
// Reads netloader argv identity tokens (docs/runbooks/ctr-runtime.md). The
// host comes from the netloader address (libctru __3dslink_host, zero when
// absent) plus --ctr-host-port. Linked build values fill omitted keys.
ArgIdentity ReadArgs(int argc, char** argv, const BuildIdentity& build,
                     const uint8_t link_host[4], RunConfig* run);
class Report {
 public:
  ~Report();
  bool Begin(FILE* config, FILE* journal, const BuildIdentity& build);
  // A non-empty notice is emitted as the first output record after begin.
  bool Begin(const RunConfig& run, FILE* journal, const BuildIdentity& build,
             const std::string& notice = {});
  // A print record. Partial stdout/stderr lines are emitted first, so the
  // records keep the program's order.
  void Output(const char* text);
  // dart:io stdout (fd 1) or stderr (fd 2) bytes. Each completed line becomes
  // an output record without its LF; the rest waits for its LF, the next
  // print or End.
  void Stdio(int fd, const char* data, size_t size);
  // Emits partial stdout/stderr lines now, so a prompt shows before the
  // program waits for stdin.
  void Flush();
  // exit_code is set when the program ended through exit() or a nonzero
  // exitCode; the terminal record then carries it.
  Outcome End(Outcome execution, bool cleanup, std::optional<int64_t> exit_code = std::nullopt);
  // Records also go to the attached sink; a failed write detaches it.
  void Attach(Sink* sink);
  // Bare newline to the attached sink only, never stdout or the journal.
  void Keepalive();
 private:
  void Emit(const std::string& record);
  void EmitLocked(const std::string& record);
  void OutputLocked(const std::string& text);
  void FlushStdioLocked();
  Mutex mutex_;  // Serializes every record and keepalive, and the stdio lines.
  std::string stdio_[2];  // Partial stdout and stderr lines.
  Sink* sink_ = nullptr;
  FILE* journal_ = nullptr;  // Borrowed; launcher closes after VM cleanup.
  std::string run_;
  bool active_ = false, ended_ = false, failed_ = false;
};
}
#endif
