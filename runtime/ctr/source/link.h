#ifndef CTR_LINK_H_
#define CTR_LINK_H_
#include <atomic>
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
// SocketService. The launcher sends records; the host sends the program's
// stdin as raw bytes and shuts down its sending side to end it.
class Link final : public Sink {
 public:
  ~Link() { Close(); }
  bool Open(const SocketService& service, const uint8_t address[4], uint16_t port,
            std::string* error);
  bool Write(const char* data, size_t size) override;
  bool connected() const { return socket_ >= 0; }
  // Blocks until stdin bytes arrive from the host. Returns the number read,
  // 0 once the host ended its input or StopReading was called, or -1 with
  // errno set.
  intptr_t Read(uint8_t* buffer, intptr_t length);
  // Releases readers within one poll slice; later reads return 0.
  void StopReading() { stopping_.store(true, std::memory_order_release); }
  void Close();
 private:
  int socket_ = -1;
  std::atomic<bool> stopping_{false};
};
}
#endif
