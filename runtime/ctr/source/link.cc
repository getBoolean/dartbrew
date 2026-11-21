#include "link.h"
#include <cstdio>
#if defined(__3DS__)
#include <3ds.h>
#include <arpa/inet.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <malloc.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif
namespace ctr {
#if defined(__3DS__)
static constexpr u32 kBufferSize = 0x100000;
bool SocketService::Start() {
  if (buffer_) return true;
  char text[64];
  buffer_ = static_cast<uint32_t*>(memalign(0x1000, kBufferSize));
  if (!buffer_) {
    snprintf(text, sizeof(text), "socket buffer allocation (%ld)", 0L);
    error_ = text;
    return false;
  }
  Result result = socInit(buffer_, kBufferSize);
  if (R_FAILED(result)) {
    free(buffer_);
    buffer_ = nullptr;
    snprintf(text, sizeof(text), "socInit (%ld)", static_cast<long>(result));
    error_ = text;
    return false;
  }
  return true;
}
void SocketService::Stop() {
  if (!buffer_) return;
  socExit();
  free(buffer_);
  buffer_ = nullptr;
}
bool Link::Open(const SocketService& service, const uint8_t address[4], uint16_t port,
                std::string* error) {
  char text[160];
  const int written = snprintf(text, sizeof(text), "CTR host link to %u.%u.%u.%u:%u failed: ",
                               address[0], address[1], address[2], address[3], port);
  auto fail = [&](const char* detail, long code) {
    snprintf(text + written, sizeof(text) - written, "%s (%ld)", detail, code);
    *error = text;
    Close();
    return false;
  };
  if (!service.ready()) {
    // The same text as when the link started soc itself.
    snprintf(text + written, sizeof(text) - written, "%s", service.error().c_str());
    *error = text;
    return false;
  }
  socket_ = socket(AF_INET, SOCK_STREAM, 0);
  if (socket_ < 0) return fail("socket", errno);
  sockaddr_in host = {};
  host.sin_family = AF_INET;
  host.sin_port = htons(port);
  memcpy(&host.sin_addr.s_addr, address, 4);
  if (connect(socket_, reinterpret_cast<sockaddr*>(&host), sizeof(host)) < 0)
    return fail(strerror(errno), errno);
  return true;
}
bool Link::Write(const char* data, size_t size) {
  while (socket_ >= 0 && size) {
    ssize_t sent = send(socket_, data, size, 0);
    if (sent <= 0) return false;
    data += sent;
    size -= static_cast<size_t>(sent);
  }
  return socket_ >= 0;
}
void Link::Close() {
  if (socket_ >= 0) {
    shutdown(socket_, SHUT_WR);
    close(socket_);
    socket_ = -1;
  }
}
#else
// Host builds have no soc:U; host checks attach their own Sink to Report.
bool SocketService::Start() {
  error_ = "socket service unavailable on this platform";
  return false;
}
void SocketService::Stop() {}
bool Link::Open(const SocketService&, const uint8_t[4], uint16_t, std::string* error) {
  *error = "CTR host link is unavailable on this platform";
  return false;
}
bool Link::Write(const char*, size_t) { return false; }
void Link::Close() {}
#endif
}
