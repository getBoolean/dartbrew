import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';

/// The worker becomes its own process group before it reads any requests.
void enterToolGroup() {
  if (Platform.isWindows) {
    _WindowsJob.join(Platform.environment[_jobVariable]!);
    return;
  }
  final setsid = DynamicLibrary.process()
      .lookupFunction<Int32 Function(), int Function()>('setsid');
  if (setsid() == -1) {
    throw const ProcessException('setsid', [], 'Could not isolate build tools');
  }
}

/// On Unix the owner disappearing closes the control pipe. Tear down every
/// remaining tool even when the owner could not send a cancellation signal.
void stopOrphanedToolGroup() {
  if (!Platform.isWindows) {
    ToolGroup._kill(-pid, ProcessSignal.sigkill.signalNumber);
  }
}

typedef _WinHandle = Pointer<Void>;

const _jobVariable = 'DARTBREW_WORKER_JOB';

/// A separate isolate owns the native handle so killing a build isolate still
/// drains its compilers. The worker joins by name before accepting commands.
final class WindowsToolJob {
  final String name;
  final SendPort _stop;
  final Future<void> _done;
  WindowsToolJob._(this.name, this._stop, this._done);

  Map<String, String> get environment => {_jobVariable: name};

  static Future<WindowsToolJob> create() async {
    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final name = 'dartbrew-$pid-$suffix';
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    final done = Completer<void>();
    done.future.ignore();
    events.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is (Object, StackTrace)) {
        if (ready.isCompleted) {
          done.completeError(message.$1, message.$2);
        } else {
          ready.completeError(message.$1, message.$2);
        }
      } else if (message == null) {
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('Build guardian exited during startup'),
          );
        }
        if (!done.isCompleted) done.complete();
        events.close();
      }
    });
    try {
      await Isolate.spawn(_ownJob, (
        Isolate.current,
        events.sendPort,
        name,
      ), onExit: events.sendPort);
      return WindowsToolJob._(name, await ready.future, done.future);
    } catch (_) {
      events.close();
      rethrow;
    }
  }

  Future<void> terminate() {
    _stop.send(null);
    return _done;
  }
}

Future<void> _ownJob((Isolate, SendPort, String) args) async {
  final (owner, events, name) = args;
  final commands = ReceivePort();
  owner.addOnExitListener(commands.sendPort);
  owner.ping(commands.sendPort, response: true, priority: Isolate.immediate);
  // The owner may have exited before this guardian was scheduled.
  final startup = Timer(
    const Duration(seconds: 30),
    () => commands.sendPort.send(null),
  );
  var job = nullptr.cast<Void>();
  try {
    await for (final message in commands) {
      if (message == null) break;
      startup.cancel();
      job = _WindowsJob.create(name);
      events.send(commands.sendPort);
    }
  } catch (error, stack) {
    events.send((error, stack));
  } finally {
    startup.cancel();
    owner.removeOnExitListener(commands.sendPort);
    commands.close();
    if (job != nullptr) {
      try {
        await _WindowsJob.terminate(job);
      } catch (error, stack) {
        events.send((error, stack));
      }
    }
  }
}

/// Called by the surviving cache lock owner before releasing abandoned staging.
Future<void> finishWindowsToolJob(String name) async {
  const queryAndTerminate = 0x0004 | 0x0008;
  final job = _WindowsJob.open(name, queryAndTerminate);
  if (job != nullptr) await _WindowsJob.terminate(job);
}

abstract final class _WindowsJob {
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _close = _kernel
      .lookupFunction<Int32 Function(_WinHandle), int Function(_WinHandle)>(
        'CloseHandle',
      );
  static final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static Never _fail(String operation) => throw ProcessException(
    operation,
    [],
    'Could not manage build worker',
    _lastError(),
  );

  static _WinHandle create(String name) {
    final create = _kernel
        .lookupFunction<
          _WinHandle Function(_WinHandle, Pointer<Utf16>),
          _WinHandle Function(_WinHandle, Pointer<Utf16>)
        >('CreateJobObjectW');
    final configure = _kernel
        .lookupFunction<
          Int32 Function(_WinHandle, Int32, _WinHandle, Uint32),
          int Function(_WinHandle, int, _WinHandle, int)
        >('SetInformationJobObject');
    final job = using(
      (arena) => create(nullptr, name.toNativeUtf16(allocator: arena)),
    );
    if (job == nullptr) _fail('CreateJobObjectW');
    try {
      // JOBOBJECT_EXTENDED_LIMIT_INFORMATION on both supported 64-bit hosts.
      // The first two LARGE_INTEGER fields precede BasicLimitInformation.LimitFlags.
      const extendedLimitInformation = 9;
      const extendedLimitSize = 144;
      const limitFlagsOffset = 16;
      const killOnJobClose = 0x2000;
      using((arena) {
        final limits = arena<Uint8>(extendedLimitSize);
        (limits + limitFlagsOffset).cast<Uint32>().value = killOnJobClose;
        if (configure(
              job,
              extendedLimitInformation,
              limits.cast(),
              extendedLimitSize,
            ) ==
            0) {
          _fail('SetInformationJobObject');
        }
      });
      return job;
    } catch (_) {
      _close(job);
      rethrow;
    }
  }

  static _WinHandle open(String name, int access) {
    final openJob = _kernel
        .lookupFunction<
          _WinHandle Function(Uint32, Int32, Pointer<Utf16>),
          _WinHandle Function(int, int, Pointer<Utf16>)
        >('OpenJobObjectW');
    return using((arena) {
      final job = openJob(access, 0, name.toNativeUtf16(allocator: arena));
      if (job == nullptr && _lastError() != 2) _fail('OpenJobObjectW');
      return job;
    });
  }

  static void join(String name) {
    const assignProcess = 0x0001;
    final job = open(name, assignProcess);
    if (job == nullptr) {
      throw StateError('Build job expired before worker startup');
    }
    try {
      final currentProcess = _kernel
          .lookupFunction<_WinHandle Function(), _WinHandle Function()>(
            'GetCurrentProcess',
          );
      final assign = _kernel
          .lookupFunction<
            Int32 Function(_WinHandle, _WinHandle),
            int Function(_WinHandle, _WinHandle)
          >('AssignProcessToJobObject');
      if (assign(job, currentProcess()) == 0) _fail('AssignProcessToJobObject');
    } finally {
      _close(job);
    }
  }

  static Future<void> terminate(_WinHandle job) async {
    final terminate = _kernel
        .lookupFunction<
          Int32 Function(_WinHandle, Uint32),
          int Function(_WinHandle, int)
        >('TerminateJobObject');
    final query = _kernel
        .lookupFunction<
          Int32 Function(
            _WinHandle,
            Int32,
            _WinHandle,
            Uint32,
            Pointer<Uint32>,
          ),
          int Function(_WinHandle, int, _WinHandle, int, Pointer<Uint32>)
        >('QueryInformationJobObject');
    const basicAccountingInformation = 1;
    const accountingSize = 48;
    const activeProcessesOffset = 40;
    final info = calloc<Uint8>(accountingSize);
    try {
      if (terminate(job, 130) == 0) _fail('TerminateJobObject');
      for (;;) {
        if (query(
              job,
              basicAccountingInformation,
              info.cast(),
              accountingSize,
              nullptr,
            ) ==
            0) {
          _fail('QueryInformationJobObject');
        }
        if ((info + activeProcessesOffset).cast<Uint32>().value == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      calloc.free(info);
      _close(job);
    }
  }
}

final class ToolGroup {
  final Process worker;
  final WindowsToolJob? windowsJob;
  ToolGroup(this.worker, this.windowsJob);

  static final _kill = DynamicLibrary.process()
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'kill',
      );
  Future<void> terminate() async {
    final job = windowsJob;
    if (job != null) {
      await job.terminate();
    } else {
      final group = worker.pid;
      if (_kill(-group, ProcessSignal.sigkill.signalNumber) != 0) {
        // Worker initialization can fail before it establishes its session.
        worker.kill(ProcessSignal.sigkill);
      }
      await worker.exitCode;
      while (_kill(-group, 0) == 0) {
        // Minimal container init processes may leave zombies indefinitely.
        // A zombie has closed its files and cannot write to staging anymore.
        final status = await Process.run('/bin/ps', [
          '-ax',
          '-o',
          'pgid=,stat=',
        ]);
        if (status.exitCode != 0) {
          throw ProcessException(
            '/bin/ps',
            [],
            status.stderr.toString(),
            status.exitCode,
          );
        }
        final live = RegExp('^\\s*$group\\s+[^Z\\s]', multiLine: true);
        if (!live.hasMatch(status.stdout.toString())) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    await worker.exitCode;
  }
}
