// Host build of the CTR event handler's poll set (runtime/bin/eventhandler_ctr_poll.cc). Plain host sockets with the host's
// poll() stand in for dart:io sockets; this is not a console check.
#include "bin/eventhandler_ctr_poll.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <thread>

using dart::bin::CtrPollSet;

static int64_t Now() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}

// A loopback UDP socket with one datagram waiting, so it stays readable.
static int Readable() {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  assert(fd >= 0);
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  assert(bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
  socklen_t size = sizeof(address);
  assert(getsockname(fd, reinterpret_cast<sockaddr*>(&address), &size) == 0);
  assert(sendto(fd, "x", 1, 0, reinterpret_cast<sockaddr*>(&address), size) == 1);
  pollfd check = {fd, POLLIN, 0};
  assert(poll(&check, 1, 1000) == 1);
  return fd;
}

static bool HasReady(const CtrPollSet& set, int fd, int events) {
  for (intptr_t i = 0; i < set.ready_count(); i++)
    if (set.ready(i).fd == fd && (set.ready(i).revents & events) == events) return true;
  return false;
}

// Runs |action| on another thread after |ms|, so that a Wait that would
// otherwise block forever returns with a message instead.
template <typename F>
static std::thread After(int ms, F action) {
  return std::thread([ms, action] {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
    action();
  });
}

static void ReadableSocketReportsOnceUntilRearmed() {
  CtrPollSet set(Now);
  int fd = Readable();
  set.Update(fd, POLLIN, true);
  assert(set.Wait());
  assert(set.ready_count() == 1 && HasReady(set, fd, POLLIN));
  // Still readable, but the edge was reported: only the bounding message wakes.
  std::thread wake = After(50, [&] { set.Send(1, 2, 3); });
  assert(set.Wait());
  wake.join();
  assert(set.ready_count() == 0 && set.message_count() == 1);
  // The socket consumed nothing yet re-arms: the level is reported again.
  std::thread rearm = After(20, [&] { set.Rearm(fd, POLLIN); });
  assert(set.Wait());
  rearm.join();
  assert(set.ready_count() == 1 && HasReady(set, fd, POLLIN));
  close(fd);
}

// An open UDP socket with nothing to read: registered, it keeps poll() busy.
static int Idle() {
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  assert(fd >= 0);
  return fd;
}

static void InterruptWakesBlockedWaitInOneCycle() {
  // With no descriptor the wait is on the condition variable; with one, on
  // poll() slices. Either way the first Wait returns with the message, soon.
  for (bool polling : {false, true}) {
    CtrPollSet set(Now);
    const int idle = polling ? Idle() : -1;
    if (polling) set.Update(idle, POLLIN, true);
    int64_t sent = 0;
    std::thread wake = After(50, [&] {
      sent = Now();
      set.Send(7, 8, 9);
    });
    assert(set.Wait());
    const int64_t woke = Now();
    wake.join();
    assert(woke - sent < 10 * CtrPollSet::kPollSliceMillis);
    assert(set.message_count() == 1 && set.ready_count() == 0 && set.timer_count() == 0);
    assert(set.message(0).id == 7 && set.message(0).dart_port == 8 && set.message(0).data == 9);
    if (polling) close(idle);
  }
}

static void TimerFiresOnceAndIsNotRearmed() {
  CtrPollSet set(Now);
  const int64_t start = Now();
  set.SetTimer(42, start + 50);
  assert(set.Wait());
  assert(Now() - start >= 50);
  assert(set.timer_count() == 1 && set.timer(0) == 42);
  std::thread wake = After(150, [&] { set.Send(1, 2, 3); });
  assert(set.Wait());
  wake.join();
  assert(set.timer_count() == 0 && set.message_count() == 1);
}

static void CancelledTimerDoesNotFire() {
  CtrPollSet set(Now);
  set.SetTimer(42, Now() + 20);
  set.SetTimer(42, -1);
  std::thread wake = After(100, [&] { set.Send(1, 2, 3); });
  assert(set.Wait());
  wake.join();
  assert(set.timer_count() == 0 && set.message_count() == 1);
}

static void ClosedRegisteredSocketLeavesWithoutStaleEvent() {
  CtrPollSet set(Now);
  int fd = Readable();
  set.Update(fd, POLLIN, true);
  set.Update(fd, 0, true);
  close(fd);
  // The next socket usually reuses the number; it is readable but unregistered.
  int reused = Readable();
  std::thread wake = After(50, [&] { set.Send(1, 2, 3); });
  assert(set.Wait());
  wake.join();
  assert(set.ready_count() == 0 && set.message_count() == 1);
  close(reused);
}

static void HangupIsReportedOnceWithoutSpinning() {
  CtrPollSet set(Now);
  int pair[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
  close(pair[1]);
  set.Update(pair[0], POLLIN, true);
  assert(set.Wait());
  assert(set.ready_count() == 1 && HasReady(set, pair[0], POLLHUP));
  // POLLHUP cannot be masked: a set that kept the descriptor would return at once.
  set.Rearm(pair[0], POLLIN);
  std::thread wake = After(50, [&] { set.Send(1, 2, 3); });
  assert(set.Wait());
  wake.join();
  assert(set.ready_count() == 0 && set.message_count() == 1);
  close(pair[0]);
}

int main() {
  ReadableSocketReportsOnceUntilRearmed();
  InterruptWakesBlockedWaitInOneCycle();
  TimerFiresOnceAndIsNotRearmed();
  CancelledTimerDoesNotFire();
  ClosedRegisteredSocketLeavesWithoutStaleEvent();
  HangupIsReportedOnceWithoutSpinning();
  puts("eventhandler host test passed");
  return 0;
}
