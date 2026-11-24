import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// The worker becomes its own process group before it reads any requests.
void enterToolGroup() {
  if (Platform.isWindows) return;
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

/// Windows uses a job owned by the caller. On POSIX the worker owns a new
/// session and its process group contains every non-detaching compiler child.
final class ToolGroup {
  final Process worker;
  _WinHandle _job = nullptr;
  ToolGroup(this.worker) {
    if (Platform.isWindows) _attachJob();
  }

  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _close = _kernel
      .lookupFunction<Int32 Function(_WinHandle), int Function(_WinHandle)>(
        'CloseHandle',
      );
  static final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static final _kill = DynamicLibrary.process()
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'kill',
      );
  Never _fail(String operation) => throw ProcessException(
    operation,
    [],
    'Could not manage build worker',
    _lastError(),
  );

  void _attachJob() {
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
    final open = _kernel
        .lookupFunction<
          _WinHandle Function(Uint32, Int32, Uint32),
          _WinHandle Function(int, int, int)
        >('OpenProcess');
    final assign = _kernel
        .lookupFunction<
          Int32 Function(_WinHandle, _WinHandle),
          int Function(_WinHandle, _WinHandle)
        >('AssignProcessToJobObject');
    _job = create(nullptr, nullptr);
    if (_job == nullptr) _fail('CreateJobObjectW');
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
              _job,
              extendedLimitInformation,
              limits.cast(),
              extendedLimitSize,
            ) ==
            0) {
          _fail('SetInformationJobObject');
        }
      });
      const terminateAndSetQuota = 0x0001 | 0x0100;
      final handle = open(terminateAndSetQuota, 0, worker.pid);
      if (handle == nullptr) _fail('OpenProcess');
      try {
        if (assign(_job, handle) == 0) _fail('AssignProcessToJobObject');
      } finally {
        _close(handle);
      }
    } catch (_) {
      _close(_job);
      _job = nullptr;
      rethrow;
    }
  }

  /// Called once, after the worker has announced readiness. The group is
  /// terminated before the driver, so a short-lived driver cannot orphan its
  /// compiler while its parent is draining diagnostics.
  Future<void> terminate() async {
    if (Platform.isWindows) {
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
        if (terminate(_job, 130) == 0) _fail('TerminateJobObject');
        for (;;) {
          if (query(
                _job,
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
        _close(_job);
        _job = nullptr;
      }
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
