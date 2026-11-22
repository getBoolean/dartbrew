#include "report.h"
#include <cstring>
namespace ctr {
static std::string Quote(const std::string& text) {
  std::string out = "\"";
  const char* hex = "0123456789abcdef";
  for (unsigned char c : text) {
    if (c == '"' || c == '\\') { out += '\\'; out += c; }
    else if (c < 32) { out += "\\u00"; out += hex[c >> 4]; out += hex[c & 15]; }
    else out += c;
  }
  return out + '"';
}
static bool Hex(const std::string& text, size_t size) {
  return text.size() == size && text.find_first_not_of("0123456789abcdef") == std::string::npos;
}
static const char* const kKeys[] = {"schema", "run_id", "fixture", "mode", "compatibility",
                                    "artifact_sha256", "build_id", "environment"};
// Strict decimal in [low, high]: digits only, no sign, at most `width` digits.
static bool Number(const char* begin, const char* end, unsigned width, unsigned long high,
                   unsigned low, unsigned long* value) {
  if (begin == end || static_cast<unsigned>(end - begin) > width) return false;
  unsigned long result = 0;
  for (const char* c = begin; c != end; ++c) {
    if (*c < '0' || *c > '9') return false;
    result = result * 10 + static_cast<unsigned long>(*c - '0');
  }
  if (result < low || result > high) return false;
  *value = result;
  return true;
}
static bool Port(const char* text, uint16_t* port) {
  unsigned long value;
  if (!Number(text, text + strlen(text), 5, 65535, 1, &value)) return false;
  *port = static_cast<uint16_t>(value);
  return true;
}
// host=<a>.<b>.<c>.<d>:<port>, dotted-decimal IPv4 and a port in 1..65535.
static bool Host(const char* text, RunConfig* run) {
  const char* colon = strchr(text, ':');
  if (!colon || !Port(colon + 1, &run->port)) return false;
  const char* part = text;
  for (unsigned i = 0; i < 4; ++i) {
    const char* end = i < 3 ? strchr(part, '.') : colon;
    unsigned long octet;
    if (!end || end > colon || !Number(part, end, 3, 255, 0, &octet)) return false;
    run->address[i] = static_cast<uint8_t>(octet);
    part = end + 1;
  }
  run->host = true;
  return true;
}
bool ReadConfig(FILE* config, RunConfig* run) {
  *run = RunConfig();
  if (!config) return false;
  char line[192];
  for (unsigned i = 0; i < 8; ++i) {
    if (!fgets(line, sizeof(line), config) || !strchr(line, '\n')) return false;
    line[strcspn(line, "\r\n")] = 0;
    char* value = strchr(line, '=');
    if (!value) return false;
    *value++ = 0;
    if (strcmp(line, kKeys[i])) return false;
    run->values[i] = value;
  }
  if (run->values[0] == "2" && fgets(line, sizeof(line), config)) {
    if (!strchr(line, '\n')) return false;
    line[strcspn(line, "\r\n")] = 0;
    if (strncmp(line, "host=", 5) || !Host(line + 5, run)) return false;
  }
  return !fgets(line, sizeof(line), config) && !ferror(config);
}
ArgIdentity ReadArgs(int argc, char** argv, const BuildIdentity& build,
                     const uint8_t link_host[4], RunConfig* run) {
  *run = RunConfig();
  static const char kRun[] = "--ctr-run=", kPort[] = "--ctr-host-port=";
  bool seen[8] = {}, any = false, port = false;
  for (int i = 1; i < argc; ++i) {
    const char* token = argv[i];
    if (strncmp(token, "--ctr-", 6)) continue;
    any = true;
    if (!strncmp(token, kPort, sizeof(kPort) - 1)) {
      if (port || !Port(token + sizeof(kPort) - 1, &run->port)) return ArgIdentity::invalid;
      port = true;
      continue;
    }
    if (strncmp(token, kRun, sizeof(kRun) - 1)) return ArgIdentity::invalid;
    const char* key = token + sizeof(kRun) - 1;
    const char* value = strchr(key, '=');
    if (!value) return ArgIdentity::invalid;
    unsigned index = 0;
    while (index < 8 && (strlen(kKeys[index]) != static_cast<size_t>(value - key) ||
                         strncmp(kKeys[index], key, value - key))) ++index;
    if (index == 8 || seen[index]) return ArgIdentity::invalid;
    seen[index] = true;
    run->values[index] = value + 1;
  }
  if (!any) return ArgIdentity::absent;
  if (!seen[0] || run->values[0] != "2" || !seen[1] || !seen[5] || !seen[7])
    return ArgIdentity::invalid;
  const char* linked[] = {build.fixture, build.mode, build.compatibility, build.build_id};
  const unsigned linked_index[] = {2, 3, 4, 6};
  for (unsigned i = 0; i < 4; ++i)
    if (!seen[linked_index[i]]) run->values[linked_index[i]] = linked[i];
  if (port && (link_host[0] | link_host[1] | link_host[2] | link_host[3])) {
    memcpy(run->address, link_host, 4);
    run->host = true;
  } else {
    run->port = 0;
  }
  return ArgIdentity::ok;
}
Report::~Report() = default;
void Report::Emit(const std::string& record) {
  Lock lock(mutex_);
  EmitLocked(record);
}
void Report::EmitLocked(const std::string& record) {
  if (fprintf(stdout, "CTR_RUNTIME %s\n", record.c_str()) < 0 || fflush(stdout)) failed_ = true;
  if (fprintf(journal_, "CTR_RUNTIME %s\n", record.c_str()) < 0 || fflush(journal_)) failed_ = true;
  if (sink_) {
    const std::string line = "CTR_RUNTIME " + record + "\n";
    if (!sink_->Write(line.data(), line.size())) sink_ = nullptr;
  }
}
void Report::Attach(Sink* sink) {
  Lock lock(mutex_);
  sink_ = sink;
}
void Report::Keepalive() {
  Lock lock(mutex_);
  if (sink_ && !sink_->Write("\n", 1)) sink_ = nullptr;
}
bool Report::Begin(FILE* config, FILE* journal, const BuildIdentity& build) {
  RunConfig run;
  return !active_ && ReadConfig(config, &run) && Begin(run, journal, build);
}
bool Report::Begin(const RunConfig& run, FILE* journal, const BuildIdentity& build,
                   const std::string& notice) {
  if (active_ || !journal) return false;
  const std::string* values = run.values;
  if ((values[0] != "1" && values[0] != "2") || (run.host && values[0] != "2") ||
      !Hex(values[1], 32) ||
      values[2] != build.fixture || values[3] != build.mode ||
      values[4] != build.compatibility || !Hex(values[4], 64) ||
      !Hex(values[5], 64) || values[6] != build.build_id || !Hex(values[6], 64) ||
      (values[7] != "hardware" && values[7] != "azahar" && values[7] != "host")) return false;
  if (values[3] != "aot" && values[3] != "jit") return false;
  journal_ = journal;
  run_ = values[1];
  active_ = true;
  std::string begin = "{\"event\":\"begin\",\"schema\":" + values[0];
  for (unsigned i = 1; i < 8; ++i) begin += "," + Quote(kKeys[i]) + ":" + Quote(values[i]);
  Emit(begin + "}");
  if (!failed_ && !notice.empty()) Output(notice.c_str());
  return !failed_;
}
void Report::OutputLocked(const std::string& text) {
  EmitLocked("{\"event\":\"output\",\"run_id\":" + Quote(run_) + ",\"text\":" + Quote(text) + "}");
}
void Report::FlushStdioLocked() {
  for (std::string& line : stdio_) {
    if (line.empty()) continue;
    OutputLocked(line);
    line.clear();
  }
}
void Report::Output(const char* text) {
  Lock lock(mutex_);
  if (!active_ || ended_) { failed_ = true; return; }
  FlushStdioLocked();
  OutputLocked(text);
}
void Report::Flush() {
  Lock lock(mutex_);
  if (active_ && !ended_) FlushStdioLocked();
}
void Report::Stdio(int fd, const char* data, size_t size) {
  Lock lock(mutex_);
  if (!active_ || ended_ || (fd != 1 && fd != 2)) { failed_ = true; return; }
  std::string& line = stdio_[fd - 1];
  for (const char* end; size && (end = static_cast<const char*>(memchr(data, '\n', size)));) {
    line.append(data, end);
    OutputLocked(line);
    line.clear();
    size -= static_cast<size_t>(end + 1 - data);
    data = end + 1;
  }
  line.append(data, size);
}
Outcome Report::End(Outcome execution, bool cleanup, std::optional<int64_t> exit_code) {
  if (!active_ || ended_) return Outcome::fail;
  {
    Lock lock(mutex_);
    FlushStdioLocked();
  }
  if (!cleanup || failed_) execution = Outcome::fail;
  const char* outcome = execution == Outcome::pass ? "pass" : execution == Outcome::fail ? "fail" : "incomplete";
  Emit("{\"event\":\"assert\",\"run_id\":" + Quote(run_) +
       ",\"name\":\"cleanup\",\"status\":" + Quote(cleanup ? "pass" : "fail") + "}");
  if (failed_) { execution = Outcome::fail; outcome = "fail"; }
  std::string code = exit_code ? ",\"exit_code\":" + std::to_string(*exit_code) : "";
  Emit("{\"event\":\"terminal\",\"run_id\":" + Quote(run_) + ",\"outcome\":" + Quote(outcome) +
       ",\"assertions\":1" + code + "}");
  ended_ = true;
  return failed_ ? Outcome::fail : execution;
}
}
