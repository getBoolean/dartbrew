#include "report.h"
#include <cassert>
#include <cstring>
#include <string>

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

void LegacyFileBegin() {
  FILE* config = Text(Identity("1"));
  FILE* journal = tmpfile();
  assert(journal);
  ctr::Report report;
  assert(report.Begin(config, journal, build));
  report.Output("quotes\" slash\\ and\nstack");
  assert(report.End(ctr::Outcome::pass, true) == ctr::Outcome::pass);
  long size = ftell(journal);
  assert(report.End(ctr::Outcome::pass, true) == ctr::Outcome::fail);
  assert(ftell(journal) == size);
  // Schema 1 keeps the exact begin record shape.
  assert(Contents(journal).rfind("CTR_RUNTIME {\"event\":\"begin\",\"schema\":1,\"run_id\":\"" +
                                 run_id + "\",", 0) == 0);
  rewind(config);
  ctr::Report mismatch;
  assert(!mismatch.Begin(config, journal, {"hello", "aot", hash.c_str(), hash.c_str()}));
  fclose(config);
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
  assert(report.End(ctr::Outcome::pass, true) == ctr::Outcome::pass);
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
  assert(report.End(ctr::Outcome::pass, true) == ctr::Outcome::pass);
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
  assert(dropped.End(ctr::Outcome::pass, true) == ctr::Outcome::pass);
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
  assert(run.values[0] == "2" && run.values[1] == run_id && run.values[2] == "hello" &&
         run.values[3] == "jit" && run.values[4] == hash && run.values[5] == hash &&
         run.values[6] == hash && run.values[7] == "hardware");
  FILE* journal = tmpfile();
  ctr::Report report;
  assert(report.Begin(run, journal, build));
  fclose(journal);
  // Linked identity values may be repeated and must then match at Begin.
  assert(Args({"--ctr-run=fixture=other", "--ctr-run=schema=2", id.c_str(), sha.c_str(),
               "--ctr-run=environment=hardware"}, host, &run) == ctr::ArgIdentity::ok);
  assert(!run.host && run.values[2] == "other");
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
  assert(report.End(ctr::Outcome::pass, true, 0) == ctr::Outcome::pass);
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
  assert(report.End(ctr::Outcome::pass, true) == ctr::Outcome::pass);
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
  assert(exited.End(ctr::Outcome::fail, true, 3) == ctr::Outcome::fail);
  assert(Contents(journal).find("\"outcome\":\"fail\",\"assertions\":1,\"exit_code\":3}") !=
         std::string::npos);
  fclose(journal);
  journal = tmpfile();
  ctr::Report plain;
  assert(plain.Begin(run, journal, build));
  assert(plain.End(ctr::Outcome::pass, true) == ctr::Outcome::pass);
  assert(Contents(journal).find("exit_code") == std::string::npos);
  fclose(journal);
}
}  // namespace

int main() {
  StandardStreams();
  PromptFlush();
  ExitCodes();
  LegacyFileBegin();
  ConfigSchemas();
  SchemaTwoBegin(Identity("2"));
  SchemaTwoBegin(Identity("2") + "host=127.0.0.1:17491\n");
  LinkedOutput();
  ArgvIdentity();
}
