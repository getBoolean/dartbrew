#ifndef CTR_LINK_H_
#define CTR_LINK_H_
#include <cstddef>
#include <cstdint>
#include <string>
namespace ctr {
// Byte stream that receives CTR_RUNTIME record lines next to stdout and the journal.
class Sink {
 public:
  virtual bool Write(const char* data, size_t size) = 0;
 protected:
  ~Sink() = default;
};
// The one owner of soc:U and its 1 MiB, 0x1000-aligned buffer, for the host
// link and, once dart:io sockets exist, the I/O layer. It starts before its
// users and stops after them.
class SocketService {
 public:
  ~SocketService() { Stop(); }
  bool Start();
  void Stop();
  bool ready() const { return buffer_ != nullptr; }
  // The failure text after a failed Start: "<step> (<code>)".
  const std::string& error() const { return error_; }
 private:
  uint32_t* buffer_ = nullptr;
  std::string error_;
};
// TCP connection to the host that started the run (KTD5) over a started
// SocketService.
class Link final : public Sink {
 public:
  ~Link() { Close(); }
  bool Open(const SocketService& service, const uint8_t address[4], uint16_t port,
            std::string* error);
  bool Write(const char* data, size_t size) override;
  void Close();
 private:
  int socket_ = -1;
};
}
#endif
