import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Tries to lock one cache key. Each successful acquisition owns its own OS
/// handle, even across isolates in the same process. The OS releases the lock
/// on process exit. Never unlink lock files: a waiter could still have the
/// original inode open when its replacement gets a different lock.
void Function()? tryCacheLock(File file) {
  if (Platform.isWindows) {
    final handle = file.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.exclusive);
      return handle.closeSync;
    } on FileSystemException catch (error) {
      handle.closeSync();
      // LockFileEx reports ERROR_LOCK_VIOLATION for a conflicting lock.
      if (error.osError?.errorCode == 33) return null;
      rethrow;
    }
  }
  return _UnixLock.acquire(file);
}

// Dart File.lock uses process-scoped fcntl locks on Unix. flock instead
// associates ownership with the open file description, so two builds in the
// same process cannot both own a key or release one another's lock.
abstract final class _UnixLock {
  static final _libc = DynamicLibrary.process();
  static final _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _flock = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
      );
  static final _errno = _libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS ? '__error' : '__errno_location',
      );
  static const _readWrite = 2;
  static const _exclusiveNonBlocking = 2 | 4;
  static int get _closeOnExec => Platform.isMacOS ? 0x1000000 : 0x80000;

  static void Function()? acquire(File file) {
    final path = file.path.toNativeUtf8();
    try {
      final fd = _open(path, _readWrite | _closeOnExec);
      if (fd == -1) {
        throw FileSystemException(
          'Cannot open native cache lock',
          file.path,
          OSError('open', _errno().value),
        );
      }
      if (_flock(fd, _exclusiveNonBlocking) == 0) {
        return () {
          _close(fd);
        };
      }
      final error = _errno().value;
      _close(fd);
      final wouldBlock = Platform.isMacOS ? 35 : 11;
      if (error == wouldBlock || error == 4 /* EINTR */ ) return null;
      throw FileSystemException(
        'Cannot lock native cache key',
        file.path,
        OSError('flock', error),
      );
    } finally {
      malloc.free(path);
    }
  }
}
