#ifndef CTR_REPORT_H_
#define CTR_REPORT_H_
#include "lifecycle.h"
#include "link.h"
#include "sync.h"
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
namespace ctr {
struct BuildIdentity {
  const char* fixture;
  const char* mode;
  const char* compatibility;
  const char* build_id;
};
// Run identity: the begin record's keys, plus the optional host.
struct RunConfig {
  std::string schema, run_id, fixture, mode, compatibility, artifact_sha256, build_id,
      environment;
  bool host = false;
  uint8_t address[4] = {};
  uint16_t port = 0;
};
// Reads sdmc:/ctr-runtime-run.cfg syntax: eight key lines, then for schema 2
// one optional host=<ipv4>:<port> line. Values are validated by Report::Begin.
bool ReadConfig(FILE* config, RunConfig* run);
enum class ArgIdentity { absent, ok, invalid };
// Reads netloader argv identity tokens (docs/ctr-native-sdk.md). The
// host comes from the netloader address (libctru __3dslink_host, zero when
// absent) plus --ctr-host-port. Linked build values fill omitted keys.
ArgIdentity ReadArgs(int argc, char** argv, const BuildIdentity& build,
                     const uint8_t link_host[4], RunConfig* run);
// The most text bytes one output record carries. Quote writes a control byte
// as six, so a record line stays under the host's 64 KiB line limit
// (RuntimeLineParser.maxLineLength in packages/dartbrew).
constexpr size_t kOutputChunk = 8 * 1024;
// Longer text goes out as several output records. Each but the last is marked
// "continues":true, and the record that continues it always follows it
// directly, so the host can join them. Splits fall between UTF-8 characters.
class Report {
 public:
  ~Report();
  // A non-empty notice is emitted as the first output record after begin.
  bool Begin(const RunConfig& run, FILE* journal, const BuildIdentity& build,
             const std::string& notice = {});
  // A print record. Partial stdout/stderr lines are emitted first, so the
  // records keep the program's order.
  void Output(const char* text);
  // dart:io stdout (fd 1) or stderr (fd 2) bytes. Each completed line becomes
  // an output record without its LF; the rest waits for its LF, the next
  // print or End. At most kOutputChunk bytes of a stream wait: a longer line
  // is emitted in continued records as it arrives.
  void Stdio(int fd, const char* data, size_t size);
  // Emits partial stdout/stderr lines now, so a prompt shows before the
  // program waits for stdin.
  void Flush();
  // The terminal record carries the completion's outcome and exit code.
  Outcome End(const Completion& completion, bool cleanup);
  // Records also go to the attached sink; a failed write detaches it.
  void Attach(Sink* sink);
  // Bare newline to the attached sink only, never stdout or the journal.
  void Keepalive();
 private:
  void Emit(const std::string& record);
  void EmitLocked(const std::string& record);
  void OutputRecordLocked(std::string_view text, bool continues);
  void OutputLocked(std::string_view text);
  void ContinueLocked(int stream);
  void EndContinuationLocked(int stream);
  void FlushStdioLocked();
  Mutex mutex_;  // Serializes every record and keepalive, and the stdio lines.
  std::string stdio_[2];  // Partial stdout and stderr lines.
  int continued_ = -1;  // The stream whose last record continues, or -1.
  Sink* sink_ = nullptr;
  FILE* journal_ = nullptr;  // Borrowed; launcher closes after VM cleanup.
  std::string run_;
  bool active_ = false, ended_ = false, failed_ = false;
};
}
#endif
