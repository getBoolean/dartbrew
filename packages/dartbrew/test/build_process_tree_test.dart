import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartbrew/src/errors.dart';
import 'package:dartbrew/src/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'parallel tools retain argv, cwd, environment and separate byte streams',
    () async {
      final work = await Directory.systemTemp.createTemp('dartbrew-worker-');
      addTearDown(() => work.delete(recursive: true));
      final tool = File(p.join(work.path, 'echo.dart'));
      await tool.writeAsString('''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  stdout.add([0, 255, ...utf8.encode(args.single)]);
  stderr.write(Platform.environment['WORKER_LABEL']);
  exitCode = File('echo.dart').existsSync() ? 17 : 18;
}
''');
      await BuildProcesses.scoped(startProcess, (scope) async {
        await expectLater(
          scope.start(p.join(work.path, 'absent'), []),
          throwsA(isA<ProcessException>()),
        );
        await Future.wait([
          for (final label in ['one & two', 'three "four"'])
            () async {
              final child = await scope.start(
                Platform.resolvedExecutable,
                [tool.path, label],
                workingDirectory: work.path,
                environment: {'WORKER_LABEL': label},
              );
              final (out, err, code) = await (
                child.stdout.expand((bytes) => bytes).toList(),
                utf8.decodeStream(child.stderr),
                child.exitCode,
              ).wait;
              expect(out, [0, 255, ...utf8.encode(label)]);
              expect(err, label);
              expect(code, 17);
            }(),
        ]);
      });
    },
  );

  test(
    'interrupt reaps an orphaned descendant holding the build pipes',
    () async {
      final work = await Directory.systemTemp.createTemp(
        'dartbrew-process-tree-',
      );
      addTearDown(() => work.delete(recursive: true));
      final witness = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(witness.close);
      final disconnected = witness.first.then((socket) async {
        try {
          await socket.drain<void>();
        } finally {
          socket.destroy();
        }
      });
      final grandchild = File(p.join(work.path, 'grandchild.dart'));
      await grandchild.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, int.parse(args.single));
  stdout.writeln('ready');
  await stdout.flush();
  await Future<void>.delayed(const Duration(seconds: 10));
  socket.destroy();
}
''');
      final parent = File(p.join(work.path, 'parent.dart'));
      await parent.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable,args,mode: ProcessStartMode.inheritStdio);
  exit(0);
}
''');
      final interrupts = StreamController<Object?>(sync: true);
      addTearDown(interrupts.close);
      final elapsed = Stopwatch();
      final run = BuildProcesses.scoped(startProcess, (processes) async {
        final child = await processes.start(Platform.resolvedExecutable, [
          parent.path,
          grandchild.path,
          '${witness.port}',
        ]);
        final output = child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) {
              if (line == 'ready') {
                elapsed.start();
                interrupts.add(null);
              }
            });
        await Future.wait([output, child.stderr.drain<void>(), child.exitCode]);
      }, interrupts: interrupts.stream);
      await expectLater(
        run,
        throwsA(
          isA<DartbrewException>().having((e) => e.exitCode, 'exit code', 130),
        ),
      );
      expect(elapsed.isRunning, isTrue);
      await disconnected.timeout(const Duration(seconds: 2));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 8)));
    },
  );
}
