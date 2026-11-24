import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'build_worker.dart' show buildWorkerArgument;
import 'tool_group.dart';

/// One worker launches every tool in a build inside the same OS containment
/// boundary. The worker speaks only to its owner through its inherited pipes.
final class BuildToolWorker {
  final Process _worker;
  final ToolGroup _group;
  final _ready = Completer<void>();
  final _requests = <int, _ToolProcess>{};
  late final Future<String> _errors;
  late final Future<void> _reader;
  Future<void>? _termination;
  int _nextId = 0;

  BuildToolWorker._(this._worker, this._group) {
    _worker.stdin.done.ignore();
    _errors = _worker.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    _reader = _read();
  }

  static Future<BuildToolWorker> open() async {
    final exe = Platform.resolvedExecutable;
    final command = p.basenameWithoutExtension(exe).toLowerCase();
    final args = [buildWorkerArgument];
    if (command == 'dartaotruntime') {
      args.insert(0, Platform.script.toFilePath());
    } else if (command == 'dart' || command == 'dartvm') {
      final source = await Isolate.resolvePackageUri(
        Uri.parse('package:dartbrew/src/build_worker.dart'),
      );
      final config = await Isolate.packageConfig;
      if (source == null || config == null) {
        throw const ProcessException(
          'dart',
          [],
          'Cannot locate the dartbrew build worker.',
        );
      }
      args
        ..clear()
        ..addAll(['--packages=${config.toFilePath()}', source.toFilePath()]);
    }
    final job = Platform.isWindows ? await WindowsToolJob.create() : null;
    late final Process process;
    try {
      process = await Process.start(exe, args, environment: job?.environment);
    } catch (_) {
      await job?.terminate();
      rethrow;
    }
    final worker = BuildToolWorker._(process, ToolGroup(process, job));
    await worker._ready.future;
    return worker;
  }

  String? get windowsJobName => _group.windowsJob?.name;

  Future<void> _read() async {
    Object? failure;
    try {
      await for (final line
          in _worker.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!_ready.isCompleted) {
          if (line != 'ready') {
            throw const FormatException('Invalid build worker greeting.');
          }
          _ready.complete();
          continue;
        }
        final event = jsonDecode(line) as List<Object?>;
        final id = event[0]! as int;
        final child = _requests[id]!;
        switch (event[1]) {
          case 'pid':
            child._pid = event[2]! as int;
            child._started.complete(child);
          case 'out':
            child._out.add(base64Decode(event[2]! as String));
          case 'err':
            child._err.add(base64Decode(event[2]! as String));
          case 'exit':
            child._exit.complete(event[2]! as int);
          case 'drained':
            child.finish();
            _requests.remove(id);
          case 'failure':
            final error = event[2]! as List<Object?>;
            child.finish(error[1]! as int, error[0]! as String);
            _requests.remove(id);
          default:
            throw FormatException('Unknown build worker event: ${event[1]}');
        }
      }
    } catch (error) {
      failure = error;
    } finally {
      // Wait for the whole group before unblocking staging cleanup. The
      // worker itself may already have exited while descendants are dying.
      var diagnostics = '';
      try {
        await (_termination ??= _group.terminate());
        diagnostics = await _errors;
      } catch (error) {
        failure ??= error;
      }
      final reason =
          failure?.toString() ??
          (diagnostics.isNotEmpty ? diagnostics : 'Build worker stopped.');
      if (!_ready.isCompleted) {
        _ready.completeError(ProcessException('dartbrew', [], reason));
      }
      for (final child in _requests.values) {
        child.finish(130, reason);
      }
      _requests.clear();
    }
  }

  Future<Process> start(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (_termination != null) {
      throw ProcessException(exe, args, 'Build worker stopped.');
    }
    final id = _nextId++;
    final child = _ToolProcess(exe, args, (signal) {
      if (_termination != null || !_requests.containsKey(id)) return false;
      if (signal != ProcessSignal.sigterm && signal != ProcessSignal.sigkill) {
        return false;
      }
      _worker.stdin.writeln(
        jsonEncode({'id': id, 'signal': signal.signalNumber}),
      );
      return true;
    });
    _requests[id] = child;
    _worker.stdin.writeln(
      jsonEncode({
        'id': id,
        'exe': exe,
        'args': args,
        'cwd': workingDirectory,
        'env': environment,
      }),
    );
    return child._started.future;
  }

  Future<void> close() async {
    try {
      await (_termination ??= _group.terminate());
    } finally {
      await _reader;
      try {
        await _worker.stdin.close();
      } on IOException {
        // The worker has already closed its end of the pipe.
      }
    }
  }
}

final class _ToolProcess implements Process {
  final String executable;
  final List<String> arguments;
  final _started = Completer<Process>();
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  int? _pid;
  final bool Function(ProcessSignal signal) _signal;
  _ToolProcess(this.executable, this.arguments, this._signal);
  void finish([int code = 0, String? failure]) {
    if (!_started.isCompleted) {
      _started.completeError(
        ProcessException(
          executable,
          arguments,
          failure ?? 'Could not launch build tool.',
          code,
        ),
      );
    }
    unawaited(_out.close());
    unawaited(_err.close());
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  int get pid => _pid!;
  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  IOSink get stdin => throw UnsupportedError('Build tools do not read stdin.');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      !_exit.isCompleted && _signal(signal);
}
