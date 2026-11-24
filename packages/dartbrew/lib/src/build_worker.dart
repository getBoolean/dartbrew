import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tool_group.dart';

const buildWorkerArgument = '--dartbrew-build-worker';

/// Handles a build worker invocation in an AOT CLI or runtime producer.
/// Returns false when the caller should continue normal command dispatch.
Future<bool> serveBuildWorker(List<String> arguments) async {
  if (arguments.length != 1 || arguments.single != buildWorkerArgument) {
    return false;
  }
  await runBuildWorker();
  return true;
}

/// The SDK executable also serves as the command's build worker. Tools are
/// started directly from argv. The parent alone can write to the request pipe.
Future<void> runBuildWorker() async {
  enterToolGroup();
  stdout.writeln('ready');
  await stdout.flush();

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, Object?>;
    unawaited(_run(request));
  }
  stopOrphanedToolGroup();
}

Future<void> _run(Map<String, Object?> request) async {
  final id = request['id']! as int;
  void send(String event, Object value) {
    stdout.writeln(jsonEncode([id, event, value]));
  }

  try {
    final process = await Process.start(
      request['exe']! as String,
      (request['args']! as List<Object?>).cast<String>(),
      workingDirectory: request['cwd'] as String?,
      environment: (request['env'] as Map<String, Object?>?)
          ?.cast<String, String>(),
    );
    send('pid', process.pid);
    await process.stdin.close();
    final (_, _, code) = await (
      process.stdout.forEach((chunk) => send('out', base64Encode(chunk))),
      process.stderr.forEach((chunk) => send('err', base64Encode(chunk))),
      process.exitCode,
    ).wait;
    send('exit', code);
  } on ProcessException catch (e) {
    send('failure', [e.message, e.errorCode]);
  }
}

/// Entry point used when running dartbrew or release_tools from source.
Future<void> main() => runBuildWorker();
