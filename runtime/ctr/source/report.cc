#include "report.h"
#include <algorithm>
#include <cstring>
namespace ctr {
static std::string Quote(std::string_view text) {
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
// The identity keys in begin record and cfg line order.
struct IdentityKey {
  const char* name;
  std::string RunConfig::*value;
  // The linked build value an argv identity may omit, or null when required.
  const char* BuildIdentity::*linked;
};
static const IdentityKey kIdentity[] = {
    {"schema", &RunConfig::schema, nullptr},
    {"run_id", &RunConfig::run_id, nullptr},
    {"fixture", &RunConfig::fixture, &BuildIdentity::fixture},
    {"mode", &RunConfig::mode, &BuildIdentity::mode},
    {"compatibility", &RunConfig::compatibility, &BuildIdentity::compatibility},
    {"artifact_sha256", &RunConfig::artifact_sha256, nullptr},
    {"build_id", &RunConfig::build_id, &BuildIdentity::build_id},
    {"environment", &RunConfig::environment, nullptr},
};
constexpr unsigned kIdentityCount = sizeof(kIdentity) / sizeof(kIdentity[0]);
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
  for (const IdentityKey& key : kIdentity) {
    if (!fgets(line, sizeof(line), config) || !strchr(line, '\n')) return false;
    line[strcspn(line, "\r\n")] = 0;
    char* value = strchr(line, '=');
    if (!value) return false;
    *value++ = 0;
    if (strcmp(line, key.name)) return false;
    run->*key.value = value;
  }
  if (run->schema == "2" && fgets(line, sizeof(line), config)) {
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
  bool seen[kIdentityCount] = {}, any = false, port = false;
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
    while (index < kIdentityCount &&
           (strlen(kIdentity[index].name) != static_cast<size_t>(value - key) ||
            strncmp(kIdentity[index].name, key, value - key))) ++index;
    if (index == kIdentityCount || seen[index]) return ArgIdentity::invalid;
    seen[index] = true;
    run->*kIdentity[index].value = value + 1;
  }
  if (!any) return ArgIdentity::absent;
  for (unsigned i = 0; i < kIdentityCount; ++i) {
    if (seen[i]) continue;
    if (!kIdentity[i].linked) return ArgIdentity::invalid;
    run->*kIdentity[i].value = build.*kIdentity[i].linked;
  }
  if (run->schema != "2") return ArgIdentity::invalid;
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
  const std::string line = "CTR_RUNTIME " + record + "\n";
  for (FILE* file : {stdout, journal_}) {
    if (fwrite(line.data(), 1, line.size(), file) != line.size() || fflush(file)) failed_ = true;
  }
  if (sink_ && !sink_->Write(line.data(), line.size())) sink_ = nullptr;
}
void Report::Attach(Sink* sink) {
  Lock lock(mutex_);
  sink_ = sink;
}
void Report::Keepalive() {
  Lock lock(mutex_);
  if (sink_ && !sink_->Write("\n", 1)) sink_ = nullptr;
}
bool Report::Begin(const RunConfig& run, FILE* journal, const BuildIdentity& build,
                   const std::string& notice) {
  if (active_ || !journal) return false;
  if ((run.schema != "1" && run.schema != "2") || (run.host && run.schema != "2") ||
      !Hex(run.run_id, 32) ||
      run.fixture != build.fixture || run.mode != build.mode ||
      run.compatibility != build.compatibility || !Hex(run.compatibility, 64) ||
      !Hex(run.artifact_sha256, 64) || run.build_id != build.build_id ||
      !Hex(run.build_id, 64) ||
      (run.environment != "hardware" && run.environment != "azahar" &&
       run.environment != "host")) return false;
  if (run.mode != "aot" && run.mode != "jit") return false;
  journal_ = journal;
  run_ = run.run_id;
  active_ = true;
  // The schema is a number; every other value is a string.
  std::string begin = "{\"event\":\"begin\",\"schema\":" + run.schema;
  for (unsigned i = 1; i < kIdentityCount; ++i)
    begin += "," + Quote(kIdentity[i].name) + ":" + Quote(run.*kIdentity[i].value);
  Emit(begin + "}");
  if (!failed_ && !notice.empty()) Output(notice.c_str());
  return !failed_;
}
// The length of text without a UTF-8 sequence cut off at its end.
static size_t WholeCharacters(std::string_view text) {
  for (size_t back = 1; back <= 3 && back <= text.size(); ++back) {
    const unsigned char c = text[text.size() - back];
    if ((c & 0xC0) == 0x80) continue;
    const size_t length = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
    return length > back ? text.size() - back : text.size();
  }
  return text.size();
}
void Report::OutputRecordLocked(std::string_view text, bool continues) {
  EmitLocked("{\"event\":\"output\",\"run_id\":" + Quote(run_) + ",\"text\":" + Quote(text) +
             (continues ? ",\"continues\":true}" : "}"));
}
void Report::OutputLocked(std::string_view text) {
  while (text.size() > kOutputChunk) {
    const size_t cut = WholeCharacters(text.substr(0, kOutputChunk));
    OutputRecordLocked(text.substr(0, cut), true);
    text.remove_prefix(cut);
  }
  OutputRecordLocked(text, false);
}
// Emits a full stream buffer as a continued record. Called only when more of
// the line is about to be appended, so the record that continues it is never
// empty.
void Report::ContinueLocked(int stream) {
  EndContinuationLocked(stream);
  std::string& line = stdio_[stream];
  const size_t cut = WholeCharacters(line);
  OutputRecordLocked(std::string_view(line).substr(0, cut), true);
  line.erase(0, cut);
  continued_ = stream;
}
// Ends another stream's open continuation with its remaining bytes, so no
// other record comes between a continued record and its continuation.
void Report::EndContinuationLocked(int stream) {
  if (continued_ < 0 || continued_ == stream) return;
  std::string& line = stdio_[continued_];
  continued_ = -1;
  OutputRecordLocked(line, false);
  line.clear();
}
void Report::FlushStdioLocked() {
  EndContinuationLocked(-1);
  for (std::string& line : stdio_) {
    if (line.empty()) continue;
    OutputRecordLocked(line, false);
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
  const int stream = fd - 1;
  std::string& line = stdio_[stream];
  while (size) {
    const char* newline = static_cast<const char*>(memchr(data, '\n', size));
    for (size_t take = newline ? static_cast<size_t>(newline - data) : size; take;) {
      if (line.size() == kOutputChunk) ContinueLocked(stream);
      const size_t count = std::min(take, kOutputChunk - line.size());
      line.append(data, count);
      data += count;
      size -= count;
      take -= count;
    }
    if (!newline) break;
    EndContinuationLocked(stream);
    OutputRecordLocked(line, false);
    line.clear();
    continued_ = -1;
    ++data;
    --size;
  }
}
Outcome Report::End(const Completion& completion, bool cleanup) {
  if (!active_ || ended_) return Outcome::fail;
  Outcome execution = completion.outcome;
  {
    Lock lock(mutex_);
    FlushStdioLocked();
  }
  if (!cleanup || failed_) execution = Outcome::fail;
  const char* outcome = execution == Outcome::pass ? "pass" : execution == Outcome::fail ? "fail" : "incomplete";
  Emit("{\"event\":\"assert\",\"run_id\":" + Quote(run_) +
       ",\"name\":\"cleanup\",\"status\":" + Quote(cleanup ? "pass" : "fail") + "}");
  if (failed_) { execution = Outcome::fail; outcome = "fail"; }
  std::string code = completion.exit_code
      ? ",\"exit_code\":" + std::to_string(*completion.exit_code) : "";
  Emit("{\"event\":\"terminal\",\"run_id\":" + Quote(run_) + ",\"outcome\":" + Quote(outcome) +
       ",\"assertions\":1" + code + "}");
  ended_ = true;
  return failed_ ? Outcome::fail : execution;
}
}
