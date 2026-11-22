#ifndef CTR_SYNC_H_
#define CTR_SYNC_H_

#include "priorities.h"
#include <cstdint>
#include <cstdlib>
#if defined(__3DS__)
#include <3ds.h>
#else
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#endif

namespace ctr {
class Mutex {
 public:
#if defined(__3DS__)
  Mutex() { LightLock_Init(&native); }
  void lock() { LightLock_Lock(&native); }
  void unlock() { LightLock_Unlock(&native); }
  LightLock native;
#else
  void lock() { native.lock(); }
  void unlock() { native.unlock(); }
  std::mutex native;
#endif
};
class Lock {
 public:
  explicit Lock(Mutex& mutex) : mutex_(mutex) { mutex_.lock(); }
  ~Lock() { mutex_.unlock(); }
 private:
  Mutex& mutex_;
};
class Condition {
 public:
#if defined(__3DS__)
  Condition() { CondVar_Init(&native_); }
  void Signal() { CondVar_Broadcast(&native_); }
  void Wait(Mutex& mutex, int64_t ms = -1) {
    if (ms < 0) CondVar_Wait(&native_, &mutex.native);
    else CondVar_WaitTimeout(&native_, &mutex.native, ms * 1000000);
  }
 private:
  CondVar native_;
#else
  void Signal() { native_.notify_all(); }
  void Wait(Mutex& mutex, int64_t ms = -1) {
    std::unique_lock<std::mutex> lock(mutex.native, std::adopt_lock);
    if (ms < 0) native_.wait(lock);
    else native_.wait_for(lock, std::chrono::milliseconds(ms));
    lock.release();
  }
 private:
  std::condition_variable native_;
#endif
};

// Native-only worker: it never enters an isolate or owns Dart handles.
class Worker {
 public:
  ~Worker() { Join(); }
  bool Start(void (*entry)(void*), void* data) {
#if defined(__3DS__)
    native_ = threadCreate(entry, data, 32 * 1024, kApplicationPriority, 0, false);
    if (!native_) return false;
    handle_ = threadGetHandle(native_);
#else
    try { native_ = std::thread(entry, data); }
    catch (...) { return false; }
#endif
    return true;
  }
  void Join() {
#if defined(__3DS__)
    if (!native_) return;
    // The libctru finished flag precedes kernel exit and TLS release.
    if (R_FAILED(svcWaitSynchronization(handle_, U64_MAX))) std::abort();
    threadFree(native_);
    native_ = nullptr;
#else
    if (native_.joinable()) native_.join();
#endif
  }
 private:
#if defined(__3DS__)
  Thread native_ = nullptr;
  Handle handle_ = 0;
#else
  std::thread native_;
#endif
};
}  // namespace ctr
#endif
