import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errors.dart';

/// Starts a child process. Commands take one of these so tests can run them
/// against stub executables.
typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      ProcessStartMode mode,
    });

/// The real [ProcessStarter]: [Process.start] without a shell.
Future<Process> startProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  ProcessStartMode mode = ProcessStartMode.normal,
}) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  runInShell: false,
  mode: mode,
);

/// Tracks build subprocesses from discovery through linking. Cancellation
/// also covers processes whose asynchronous startup has not returned yet.
final class BuildProcesses {
  final ProcessStarter _start;
  final _children = <Process>{};
  final _active = <Completer<void>>{};
  final _cancellation = Completer<void>();
  Future<void> get cancelled => _cancellation.future;
  bool get _cancelled => _cancellation.isCompleted;

  BuildProcesses(this._start);

  /// Joins the command's cancellation scope, or watches OS signals when
  /// called directly. The scope stays active until output and staging close.
  static Future<T> scoped<T>(
    ProcessStarter start,
    Future<T> Function(BuildProcesses processes) build, {
    BuildProcesses? parent,
    Stream<Object?>? interrupts,
  }) async {
    final scope = parent ?? BuildProcesses(start);
    scope.check();
    final done = Completer<void>();
    scope._active.add(done);
    final signal = parent == null
        ? (interrupts ?? ProcessSignal.sigint.watch()).listen(
            (_) => scope._cancel(),
            onDone: scope._cancel,
          )
        : null;
    final terminate =
        parent == null && interrupts == null && !Platform.isWindows
        ? ProcessSignal.sigterm.watch().listen((_) => scope._cancel())
        : null;
    try {
      final result = await build(scope);
      scope.check();
      return result;
    } catch (_) {
      scope.check();
      rethrow;
    } finally {
      await signal?.cancel();
      await terminate?.cancel();
      scope._active.remove(done);
      done.complete();
    }
  }

  /// Stops any running build and waits for it to finish its cleanup.
  Future<void> cancelAndWait() async {
    _cancel();
    await Future.wait([for (final active in _active) active.future]);
  }

  void _cancel() {
    if (_cancelled) return;
    _cancellation.complete();
    for (final child in _children) {
      child.kill(ProcessSignal.sigkill);
    }
  }

  void check() {
    if (_cancelled) {
      throw const DartbrewException(130, 'Build interrupted.');
    }
  }

  /// Starts a child owned by this scope. Callers consume the output streams
  /// and await exit as usual, including when the child has been interrupted.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    check();
    final child = await _start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: mode,
    );
    _children.add(child);
    if (_cancelled) child.kill(ProcessSignal.sigkill);
    child.exitCode.whenComplete(() => _children.remove(child)).ignore();
    return child;
  }

  /// Runs a native tool to completion and returns its stdout.
  Future<String> run(String executable, List<String> arguments) async {
    final process = await start(executable, arguments);
    final (out, err, code) = await (
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join(),
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join(),
      process.exitCode,
    ).wait;
    check();
    if (code != 0) {
      throw ProcessException(
        executable,
        arguments,
        err.isEmpty ? out : err,
        code,
      );
    }
    return out;
  }
}
