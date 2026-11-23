import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process.dart';
import 'sdk.dart';

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

/// Runs SDK tools as named build stages.
///
/// Every stage is appended to `work/commands.json` before it starts, and its
/// output is written to `work/<stage>.log`. Standard error is also echoed to
/// [progress]. A stage that exits non-zero throws a [StageFailure] that
/// names the stage and its log.
class StageRunner {
  final NativeSdk sdk;
  final Directory work;
  final ProcessStarter start;
  final IOSink progress;
  final _commands = <Map<String, Object>>[];

  StageRunner(
    this.sdk,
    this.work, {
    this.start = startProcess,
    IOSink? progress,
  }) : progress = progress ?? stderr;

  Future<void> call(
    String tool,
    List<String> args,
    String stage, {
    String? cwd,
    String? executable,
    String? failureAdvice,
  }) async {
    progress.writeln(stage);
    executable ??= sdk.tool(tool);
    _commands.add({
      'stage': stage,
      'executable': executable,
      'arguments': args,
    });
    File(
      p.join(work.path, 'commands.json'),
    ).writeAsStringSync(jsonEncode(_commands));
    final process = await start(
      executable,
      args,
      workingDirectory: cwd ?? work.path,
      environment: {
        'PATH':
            p.dirname(executable) +
            (Platform.isWindows ? ';' : ':') +
            p.join(sdk.root, 'bin'),
      },
    );
    final log = File(p.join(work.path, '$stage.log')).openWrite();
    await Future.wait([
      process.stdout.forEach(log.add),
      process.stderr.forEach((bytes) {
        log.add(bytes);
        progress.add(bytes);
      }),
    ]);
    await log.close();
    final code = await process.exitCode;
    if (code != 0) {
      throw StageFailure(
        executable,
        args,
        stage,
        '$stage failed ($code); see ${p.join(work.path, '$stage.log')}'
        "${failureAdvice == null ? '' : '\n$failureAdvice'}",
        code,
      );
    }
  }
}
