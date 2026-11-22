import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A build stage that exited non-zero: [stage] names it, [message] names its
/// log and [errorCode] is the tool's exit code.
final class StageFailure extends ProcessException {
  final String stage;

  const StageFailure(
    super.executable,
    super.arguments,
    this.stage,
    super.message,
    super.errorCode,
  );
}

/// Runs release tools as named build stages in [work].
///
/// Every stage is appended to `work/commands.json` before it starts, and its
/// output is written to `work/<stage>.log`. Standard error is also echoed to
/// [progress]. A stage that exits non-zero throws a [StageFailure] that
/// names the stage and its log.
final class StageRunner {
  final Directory work;
  final IOSink progress;
  final _commands = <Map<String, Object>>[];

  StageRunner(this.work, {IOSink? progress}) : progress = progress ?? stderr;

  Future<void> call(
    String executable,
    List<String> arguments,
    String stage, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    progress.writeln(stage);
    _commands.add({
      'stage': stage,
      'executable': executable,
      'arguments': arguments,
    });
    File(
      p.join(work.path, 'commands.json'),
    ).writeAsStringSync(jsonEncode(_commands));
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory ?? work.path,
      environment: environment,
    );
    final logPath = p.join(work.path, '$stage.log');
    final log = File(logPath).openWrite();
    try {
      await Future.wait([
        process.stdout.forEach(log.add),
        process.stderr.forEach((bytes) {
          log.add(bytes);
          progress.add(bytes);
        }),
      ]);
    } finally {
      await log.close();
    }
    final code = await process.exitCode;
    if (code != 0) {
      throw StageFailure(
        executable,
        arguments,
        stage,
        '$stage failed ($code); see $logPath',
        code,
      );
    }
  }
}
