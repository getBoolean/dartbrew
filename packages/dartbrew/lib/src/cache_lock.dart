import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Runs [build] while holding the OS lock. Only cold requests start a lock
/// owner. It closes its handle even when the build isolate is killed without
/// unwinding its Dart stack.
Future<T> withCacheLock<T>(
  File file,
  void Function()? checkCancelled,
  Future<T> Function() build,
) async {
  final replies = ReceivePort();
  final messages = StreamIterator<Object>(
    replies.takeWhile((message) => message != null).cast<Object>(),
  );
  SendPort? commands;
  try {
    await Isolate.spawn(_ownCacheLock, (
      Isolate.current,
      replies.sendPort,
      file.path,
    ), onExit: replies.sendPort);
    Future<Object> reply() async {
      if (!await messages.moveNext()) {
        throw StateError('Native cache lock owner exited before replying.');
      }
      final message = messages.current;
      if (message case (Object error, StackTrace trace)) {
        Error.throwWithStackTrace(error, trace);
      }
      return message;
    }

    commands = await reply() as SendPort;
    while (true) {
      checkCancelled?.call();
      commands.send(true);
      if (await reply() == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
    checkCancelled?.call();
    return await build();
  } finally {
    if (commands != null) {
      commands.send(null);
      await messages.moveNext();
    }
    replies.close();
    await messages.cancel();
  }
}

Future<void> _ownCacheLock((Isolate, SendPort, String) request) async {
  final (builder, replies, path) = request;
  final commands = ReceivePort();
  final control = commands.sendPort;
  // An immediate ping acknowledges all earlier control messages, including
  // registration of the builder's exit notification. If it already died, no
  // ping arrives. Retire the idle helper without opening a file.
  builder.addOnExitListener(control);
  builder.ping(control, response: 'ready');
  final startup = Timer(const Duration(seconds: 30), () => control.send(null));
  void Function()? release;
  try {
    await for (final command in commands) {
      if (command == null) break;
      if (command == 'ready') {
        startup.cancel();
        replies.send(control);
      } else {
        release = _tryCacheLock(File(path));
        replies.send(release != null);
      }
    }
  } catch (error, trace) {
    replies.send((error, trace));
  } finally {
    release?.call();
    startup.cancel();
    builder.removeOnExitListener(control);
    commands.close();
  }
}

/// Tries to lock one cache key. Each successful acquisition owns its own OS
/// handle, even across isolates in the same process. The OS releases the lock
/// on process exit. Never unlink lock files: a waiter could still have the
/// original inode open when its replacement gets a different lock.
void Function()? _tryCacheLock(File file) {
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
