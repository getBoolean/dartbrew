#ifndef CTR_SYNC_H_
#define CTR_SYNC_H_

#include <cstdint>
#if defined(__3DS__)
#include <3ds.h>
#else
#include <chrono>
#include <condition_variable>
#include <mutex>
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
    if (ms < 0)
      CondVar_Wait(&native_, &mutex.native);
    else
      CondVar_WaitTimeout(&native_, &mutex.native, ms * 1000000);
  }

 private:
  CondVar native_;
#else
  void Signal() { native_.notify_all(); }
  void Wait(Mutex& mutex, int64_t ms = -1) {
    std::unique_lock<std::mutex> lock(mutex.native, std::adopt_lock);
    if (ms < 0)
      native_.wait(lock);
    else
      native_.wait_for(lock, std::chrono::milliseconds(ms));
    lock.release();
  }

 private:
  std::condition_variable native_;
#endif
};
}  // namespace ctr
#endif
