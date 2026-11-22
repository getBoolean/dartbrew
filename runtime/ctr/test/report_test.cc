#include "report.h"
#include <algorithm>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

namespace {
const std::string hash(64, 'a');
const std::string run_id(32, 'b');
const ctr::BuildIdentity build = {"hello", "jit", hash.c_str(), hash.c_str()};

std::string Identity(const char* schema) {
  return std::string("schema=") + schema + "\nrun_id=" + run_id +
      "\nfixture=hello\nmode=jit\ncompatibility=" + hash + "\nartifact_sha256=" + hash +
      "\nbuild_id=" + hash + "\nenvironment=host\n";
}
FILE* Text(const std::string& text) {
  FILE* file = tmpfile();
  assert(file && fputs(text.c_str(), file) >= 0);
  rewind(file);
  return file;
}
std::string Contents(FILE* file) {
  std::string text;
  rewind(file);
  for (int c; (c = fgetc(file)) != EOF;) text += static_cast<char>(c);
  return text;
}
bool Read(const std::string& text, ctr::RunConfig* run) {
  FILE* config = Text(text);
  bool ok = ctr::ReadConfig(config, run);
  fclose(config);
  return ok;
}
struct Recorder final : ctr::Sink {
  bool Write(const char* data, size_t size) override {
    if (broken) return false;
    text.append(data, size);
    return true;
  }
  std::string text;
  bool broken = false;
};
ctr::ArgIdentity Args(std::initializer_list<const char*> tokens, const uint8_t host[4],
                      ctr::RunConfig* run) {
  char* argv[16] = {};
  int argc = 0;
  argv[argc++] = const_cast<char*>("sdmc:/3ds/hello.3dsx");
  for (const char* token : tokens) argv[argc++] = const_cast<char*>(token);
  return ctr::ReadArgs(argc, argv, build, host, run);
}

const ctr::Completion passed = {ctr::Outcome::pass, std::nullopt};

void SchemaOneBegin() {
  ctr::RunConfig run;
  assert(Read(Identity("1"), &run));
  FILE* journal = tmpfile();
  assert(journal);
  ctr::Report report;
  assert(report.Begin(run, journal, build));
  report.Output("quotes\" slash\\ and\nstack");
  assert(report.End(passed, true) == ctr::Outcome::pass);
  long size = ftell(journal);
  assert(report.End(passed, true) == ctr::Outcome::fail);
  assert(ftell(journal) == size);
  // Schema 1 keeps the exact begin record shape.
  assert(Contents(journal).rfind("CTR_RUNTIME {\"event\":\"begin\",\"schema\":1,\"run_id\":\"" +
                                 run_id + "\",", 0) == 0);
  ctr::Report mismatch;
  assert(!mismatch.Begin(run, journal, {"hello", "aot", hash.c_str(), hash.c_str()}));
  fclose(journal);
}

void ConfigSchemas() {
  ctr::RunConfig run;
  assert(Read(Identity("1"), &run) && !run.host);
  assert(Read(Identity("2"), &run) && !run.host);
  assert(Read(Identity("2") + "host=192.168.1.5:17491\n", &run) && run.host);
  assert(run.address[0] == 192 && run.address[1] == 168 && run.address[2] == 1 &&
         run.address[3] == 5 && run.port == 17491);
  assert(Read(Identity("2") + "host=127.0.0.1:1\n", &run) && run.host && run.port == 1);
  // The ninth line exists only in schema 2 and must be host=.
  assert(!Read(Identity("2") + "port=17491\n", &run));
  assert(!Read(Identity("1") + "host=127.0.0.1:17491\n", &run));
  assert(!Read(Identity("2") + "host=127.0.0.1:17491\nhost=127.0.0.1:17491\n", &run));
  assert(!Read(Identity("2") + "host=127.0.0.1:17491", &run));
  for (const char* bad : {"256.0.0.1:1", "1.2.3:4", "1.2.3.4", "1.2.3.4:0", "1.2.3.4:65536",
                          "1.2.3.4:+1", "1.2.3.4:1x", " 1.2.3.4:1", "1..3.4:1", "1.2.3.4.5:1",
                          "1.2.3.0004:1"}) {
    assert(!Read(Identity("2") + "host=" + bad + "\n", &run));
  }
  // Unknown schemas still fail when the launcher validates identity.
  FILE* journal = tmpfile();
  assert(Read(Identity("3"), &run));
  ctr::Report report;
  assert(!report.Begin(run, journal, build));
  assert(Contents(journal).empty());
  fclose(journal);
}

void SchemaTwoBegin(const std::string& text) {
  ctr::RunConfig run;
  assert(Read(text, &run));
  FILE* journal = tmpfile();
  ctr::Report report;
  assert(report.Begin(run, journal, build));
  assert(report.End(passed, true) == ctr::Outcome::pass);
  assert(Contents(journal).rfind("CTR_RUNTIME {\"event\":\"begin\",\"schema\":2,\"run_id\":\"" +
                                 run_id + "\",", 0) == 0);
  fclose(journal);
}

void LinkedOutput() {
  ctr::RunConfig run;
  assert(Read(Identity("2") + "host=10.0.0.2:17491\n", &run));
  FILE* journal = tmpfile();
  Recorder link;
  ctr::Report report;
  report.Attach(&link);
  // A failed connection is reported only after begin, as the first output record.
  assert(report.Begin(run, journal, build, "host link failed: connect refused"));
  report.Keepalive();
  report.Output("hello");
  assert(report.End(passed, true) == ctr::Outcome::pass);
  std::string records = Contents(journal);
  std::string begin = records.substr(0, records.find('\n') + 1);
  std::string expected_output = "CTR_RUNTIME {\"event\":\"output\",\"run_id\":\"" + run_id +
      "\",\"text\":\"host link failed: connect refused\"}\n";
  assert(records.compare(begin.size(), expected_output.size(), expected_output) == 0);
  // Every record reaches the link; the keepalive reaches only the link.
  size_t keepalive = begin.size() + expected_output.size();
  assert(link.text == records.substr(0, keepalive) + "\n" + records.substr(keepalive));
  assert(records.find("\n\n") == std::string::npos);
  fclose(journal);

  // A link that stops accepting writes is dropped without failing the run.
  journal = tmpfile();
  Recorder lost;
  ctr::Report dropped;
  dropped.Attach(&lost);
  assert(dropped.Begin(run, journal, build));
  lost.broken = true;
  dropped.Output("after loss");
  lost.broken = false;
  dropped.Keepalive();
  assert(dropped.End(passed, true) == ctr::Outcome::pass);
  assert(lost.text.find("after loss") == std::string::npos);
  assert(lost.text.find("terminal") == std::string::npos);
  assert(Contents(journal).find("terminal") != std::string::npos);
  fclose(journal);
}

void ArgvIdentity() {
  const uint8_t host[4] = {192, 168, 1, 5};
  const uint8_t none[4] = {};
  const std::string id = "--ctr-run=run_id=" + run_id;
  const std::string sha = "--ctr-run=artifact_sha256=" + hash;
  ctr::RunConfig run;
  assert(Args({}, host, &run) == ctr::ArgIdentity::absent);
  assert(Args({"user-argument"}, host, &run) == ctr::ArgIdentity::absent);
  assert(Args({"--ctr-run=schema=2", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware",
               "--ctr-host-port=17491"}, host, &run) == ctr::ArgIdentity::ok);
  assert(run.host && run.port == 17491 && !memcmp(run.address, host, 4));
  assert(run.schema == "2" && run.run_id == run_id && run.fixture == "hello" &&
         run.mode == "jit" && run.compatibility == hash && run.artifact_sha256 == hash &&
         run.build_id == hash && run.environment == "hardware");
  FILE* journal = tmpfile();
  ctr::Report report;
  assert(report.Begin(run, journal, build));
  fclose(journal);
  // Linked identity values may be repeated and must then match at Begin.
  assert(Args({"--ctr-run=fixture=other", "--ctr-run=schema=2", id.c_str(), sha.c_str(),
               "--ctr-run=environment=hardware"}, host, &run) == ctr::ArgIdentity::ok);
  assert(!run.host && run.fixture == "other");
  journal = tmpfile();
  ctr::Report mismatch;
  assert(!mismatch.Begin(run, journal, build));
  fclose(journal);
  // Without a netloader address, a port token gives no host.
  assert(Args({"--ctr-run=schema=2", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware",
               "--ctr-host-port=17491"}, none, &run) == ctr::ArgIdentity::ok && !run.host);
  // Malformed identity never falls back to the cfg file.
  const std::initializer_list<const char*> invalid[] = {
      {"--ctr-run=schema=1", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware"},
      {"--ctr-run=schema=2", sha.c_str(), "--ctr-run=environment=hardware"},
      {"--ctr-run=schema=2", id.c_str(), id.c_str(), sha.c_str(), "--ctr-run=environment=hardware"},
      {"--ctr-run=schema=2", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware", "--ctr-run=color=red"},
      {"--ctr-run=schema=2", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware", "--ctr-run"},
      {"--ctr-run=schema=2", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware", "--ctr-host-port=0"},
      {"--ctr-run=schema=2", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware", "--ctr-host-port=99999"},
      {"--ctr-run=schema=2", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware", "--ctr-host-port=1",
       "--ctr-host-port=2"},
      {"--ctr-run=schema=2", id.c_str(), sha.c_str(), "--ctr-run=environment=hardware", "--ctr-other=1"},
      {"--ctr-host-port=17491"},
  };
  for (const auto& tokens : invalid) assert(Args(tokens, host, &run) == ctr::ArgIdentity::invalid);
}
std::string OutputRecord(const std::string& text) {
  return "CTR_RUNTIME {\"event\":\"output\",\"run_id\":\"" + run_id + "\",\"text\":\"" + text +
      "\"}\n";
}

// stdout and stderr bytes become one output record per line, in order with
// print records; a partial line is flushed before the next print and at End.
void StandardStreams() {
  ctr::RunConfig run;
  assert(Read(Identity("2"), &run));
  FILE* journal = tmpfile();
  ctr::Report report;
  assert(report.Begin(run, journal, build));
  const std::string begin = Contents(journal);
  report.Stdio(1, "one\ntw", 6);
  report.Stdio(1, "o\n", 2);
  report.Stdio(2, "err\n", 4);
  report.Stdio(1, "partial", 7);
  report.Output("print");
  report.Stdio(2, "tail", 4);
  assert(report.End({ctr::Outcome::pass, 0}, true) == ctr::Outcome::pass);
  const std::string records = Contents(journal).substr(begin.size());
  const std::string expected = OutputRecord("one") + OutputRecord("two") + OutputRecord("err") +
      OutputRecord("partial") + OutputRecord("print") + OutputRecord("tail");
  assert(records.compare(0, expected.size(), expected) == 0);
  // exit(0) carries its code on the terminal record.
  assert(records.find("\"outcome\":\"pass\",\"assertions\":1,\"exit_code\":0}") != std::string::npos);
  fclose(journal);
}

// A prompt written without a newline is shown before the program reads stdin.
void PromptFlush() {
  ctr::RunConfig run;
  assert(Read(Identity("2"), &run));
  FILE* journal = tmpfile();
  ctr::Report report;
  assert(report.Begin(run, journal, build));
  report.Stdio(1, "Name: ", 6);
  report.Flush();
  assert(Contents(journal).find(OutputRecord("Name: ")) != std::string::npos);
  report.Flush();  // Nothing pending: no empty record.
  assert(report.End(passed, true) == ctr::Outcome::pass);
  assert(Contents(journal).find(OutputRecord("")) == std::string::npos);
  fclose(journal);
}

// exit(n) with n != 0 fails carrying n; without a code the terminal is unchanged.
void ExitCodes() {
  ctr::RunConfig run;
  assert(Read(Identity("2"), &run));
  FILE* journal = tmpfile();
  ctr::Report exited;
  assert(exited.Begin(run, journal, build));
  assert(exited.End({ctr::Outcome::fail, 3}, true) == ctr::Outcome::fail);
  assert(Contents(journal).find("\"outcome\":\"fail\",\"assertions\":1,\"exit_code\":3}") !=
         std::string::npos);
  fclose(journal);
  journal = tmpfile();
  ctr::Report plain;
  assert(plain.Begin(run, journal, build));
  assert(plain.End(passed, true) == ctr::Outcome::pass);
  assert(Contents(journal).find("exit_code") == std::string::npos);
  fclose(journal);
}

// A minimal JSON reader for the shared verdict vectors.
struct Json {
  std::string text;  // A string's value, or a number or literal as written.
  std::vector<std::pair<std::string, Json>> members;
  std::vector<Json> items;
  const Json* Find(const std::string& key) const {
    for (const auto& [name, value] : members)
      if (name == key) return &value;
    return nullptr;
  }
};
void AppendUtf8(unsigned code, std::string* out) {
  assert(code < 0xD800 || code > 0xDFFF);
  if (code < 0x80) {
    *out += static_cast<char>(code);
  } else if (code < 0x800) {
    *out += static_cast<char>(0xC0 | code >> 6);
    *out += static_cast<char>(0x80 | (code & 0x3F));
  } else {
    *out += static_cast<char>(0xE0 | code >> 12);
    *out += static_cast<char>(0x80 | (code >> 6 & 0x3F));
    *out += static_cast<char>(0x80 | (code & 0x3F));
  }
}
Json Parse(const char*& p) {
  while (strchr(" \t\r\n", *p) && *p) ++p;
  Json value;
  if (*p == '{' || *p == '[') {
    const char close = *p == '{' ? '}' : ']';
    for (++p;;) {
      while (strchr(" \t\r\n,", *p) && *p) ++p;
      if (*p == close) { ++p; return value; }
      if (close == ']') { value.items.push_back(Parse(p)); continue; }
      std::string key = Parse(p).text;
      while (*p != ':') ++p;
      ++p;
      value.members.emplace_back(key, Parse(p));
    }
  }
  if (*p != '"') {
    while (*p && !strchr(",]} \t\r\n", *p)) value.text += *p++;
    return value;
  }
  for (++p; *p != '"'; ++p) {
    if (*p != '\\') { value.text += *p; continue; }
    switch (*++p) {
      case 'n': value.text += '\n'; break;
      case 't': value.text += '\t'; break;
      case 'u': AppendUtf8(static_cast<unsigned>(std::stoul(std::string(p + 1, 4), nullptr, 16)),
                           &value.text);
                p += 4;
                break;
      default: value.text += *p;
    }
  }
  ++p;
  return value;
}

// Every vector with stdout: the launcher writes it to fd 1, ends the run as a
// pass, and produces exactly the vector's record lines.
void SharedVectors(const char* path) {
  std::ifstream file(path, std::ios::binary);
  assert(file);
  const std::string source((std::istreambuf_iterator<char>(file)), {});
  const char* cursor = source.c_str();
  const Json vectors = Parse(cursor);
  unsigned checked = 0;
  for (const Json& vector : vectors.Find("cases")->items) {
    const Json* stdout_text = vector.Find("stdout");
    if (!stdout_text) continue;
    const Json& id = *vector.Find("identity");
    ctr::RunConfig run;
    run.schema = id.Find("schema")->text;
    run.run_id = id.Find("run_id")->text;
    run.fixture = id.Find("fixture")->text;
    run.mode = id.Find("mode")->text;
    run.compatibility = id.Find("compatibility")->text;
    run.artifact_sha256 = id.Find("artifact_sha256")->text;
    run.build_id = id.Find("build_id")->text;
    run.environment = id.Find("environment")->text;
    const ctr::BuildIdentity linked = {run.fixture.c_str(), run.mode.c_str(),
                                       run.compatibility.c_str(), run.build_id.c_str()};
    std::string expected;
    for (const Json& line : vector.Find("lines")->items) expected += line.text + "\n";
    FILE* journal = tmpfile();
    ctr::Report report;
    assert(report.Begin(run, journal, linked));
    report.Stdio(1, stdout_text->text.data(), stdout_text->text.size());
    assert(report.End(passed, true) == ctr::Outcome::pass);
    assert(Contents(journal) == expected);
    fclose(journal);
    ++checked;
  }
  assert(checked > 0);
}

// Counts the bytes of record text that reach it; record text here is plain.
struct TextCounter final : ctr::Sink {
  bool Write(const char* data, size_t size) override {
    const std::string line(data, size);
    const size_t text = line.find("\"text\":\"");
    if (text != std::string::npos) {
      const size_t start = text + 8;
      bytes += line.find('"', start) - start;
    }
    return true;
  }
  size_t bytes = 0;
};

// Output records after begin, as journal lines.
std::vector<std::string> Records(FILE* journal) {
  std::vector<std::string> lines;
  const std::string text = Contents(journal);
  for (size_t start = text.find('\n') + 1, end; (end = text.find('\n', start)) != std::string::npos;
       start = end + 1) {
    lines.push_back(text.substr(start, end + 1 - start));
  }
  return lines;
}
std::string Continued(const std::string& text) {
  return "CTR_RUNTIME {\"event\":\"output\",\"run_id\":\"" + run_id + "\",\"text\":\"" + text +
      "\",\"continues\":true}\n";
}

// A line of exactly one chunk is one record, with no empty continuation.
void ExactChunk() {
  ctr::RunConfig run;
  assert(Read(Identity("2"), &run));
  const std::string chunk(ctr::kOutputChunk, 'x');
  for (const std::string& written : {chunk + "\n", chunk}) {
    FILE* journal = tmpfile();
    ctr::Report report;
    assert(report.Begin(run, journal, build));
    report.Stdio(1, written.data(), written.size());
    assert(report.End(passed, true) == ctr::Outcome::pass);
    const std::vector<std::string> records = Records(journal);
    assert(records.size() == 3 && records[0] == OutputRecord(chunk));
    fclose(journal);
  }
}

// At most one chunk of a stream waits on the device, however the line is
// written.
void BoundedBuffer() {
  ctr::RunConfig run;
  assert(Read(Identity("2"), &run));
  const std::string megabyte(1024 * 1024, 'x');
  for (size_t piece : {size_t{1000}, megabyte.size()}) {
    FILE* journal = tmpfile();
    TextCounter counter;
    ctr::Report report;
    report.Attach(&counter);
    assert(report.Begin(run, journal, build));
    for (size_t written = 0; written < megabyte.size();) {
      const size_t size = std::min(piece, megabyte.size() - written);
      report.Stdio(1, megabyte.data() + written, size);
      written += size;
      assert(written - counter.bytes <= ctr::kOutputChunk);
    }
    report.Stdio(1, "\n", 1);
    assert(counter.bytes == megabyte.size());
    assert(report.End(passed, true) == ctr::Outcome::pass);
    fclose(journal);
  }
}

// A control byte is quoted as six bytes; a record line still fits the host's
// 64 KiB line limit.
void QuotedChunkFits() {
  ctr::RunConfig run;
  assert(Read(Identity("2"), &run));
  FILE* journal = tmpfile();
  ctr::Report report;
  assert(report.Begin(run, journal, build));
  const std::string controls(3 * ctr::kOutputChunk, '\x01');
  report.Stdio(2, controls.data(), controls.size());
  assert(report.End(passed, true) == ctr::Outcome::pass);
  const std::vector<std::string> records = Records(journal);
  assert(records.size() == 5);
  for (const std::string& record : records) assert(record.size() <= 64 * 1024);
  fclose(journal);
}

// Another stream's line or a print ends an open continuation first, so the
// record after a continued one always continues it.
void ContinuationsStayAdjacent() {
  ctr::RunConfig run;
  assert(Read(Identity("2"), &run));
  FILE* journal = tmpfile();
  ctr::Report report;
  assert(report.Begin(run, journal, build));
  const std::string chunk(ctr::kOutputChunk, 'a');
  const std::string long_line = chunk + "tail";
  report.Stdio(1, long_line.data(), long_line.size());
  report.Stdio(2, "err\n", 4);
  report.Stdio(1, "next\n", 5);
  const std::string print(2 * ctr::kOutputChunk + 1, 'p');
  report.Output(print.c_str());
  assert(report.End(passed, true) == ctr::Outcome::pass);
  const std::vector<std::string> records = Records(journal);
  const std::vector<std::string> expected = {
      Continued(chunk), OutputRecord("tail"), OutputRecord("err"), OutputRecord("next"),
      Continued(std::string(ctr::kOutputChunk, 'p')),
      Continued(std::string(ctr::kOutputChunk, 'p')), OutputRecord("p")};
  assert(records.size() == expected.size() + 2);
  assert(std::equal(expected.begin(), expected.end(), records.begin()));
  fclose(journal);
}
}  // namespace

int main(int argc, char** argv) {
  assert(argc == 2);
  // Records also go to stdout; the tests read them from the journal and sinks.
  assert(freopen("/dev/null", "w", stdout));
  SharedVectors(argv[1]);
  ExactChunk();
  BoundedBuffer();
  QuotedChunkFits();
  ContinuationsStayAdjacent();
  StandardStreams();
  PromptFlush();
  ExitCodes();
  SchemaOneBegin();
  ConfigSchemas();
  SchemaTwoBegin(Identity("2"));
  SchemaTwoBegin(Identity("2") + "host=127.0.0.1:17491\n");
  LinkedOutput();
  ArgvIdentity();
}
