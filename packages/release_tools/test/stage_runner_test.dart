import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:release_tools/src/stage_runner.dart';
import 'package:test/test.dart';

void main() {
  late Directory work;
  late File progressFile;
  late StageRunner run;

  setUp(() {
    work = Directory.systemTemp.createTempSync('release-tools-work-');
    progressFile = File('${work.path}.progress');
    final progress = progressFile.openWrite();
    addTearDown(() async {
      await progress.close();
      progressFile.deleteSync();
      work.deleteSync(recursive: true);
    });
    run = StageRunner(work, progress: progress);
  });

  /// A Dart script that writes `<name> stdout` and `<name> stderr` and exits
  /// with [code].
  String tool(String name, int code) {
    final script = File(p.join(work.path, '$name.dart'))
      ..writeAsStringSync('''
import 'dart:io';

void main() {
  stdout.writeln('$name stdout');
  stderr.writeln('$name stderr');
  exitCode = $code;
}
''');
    return script.path;
  }

  List<Object?> commands() =>
      jsonDecode(File(p.join(work.path, 'commands.json')).readAsStringSync())
          as List<Object?>;

  test('records each stage and writes its log', () async {
    final script = tool('kernel', 0);
    await run(Platform.resolvedExecutable, [script], 'kernel');
    final log = File(p.join(work.path, 'kernel.log')).readAsStringSync();
    expect(log, contains('kernel stdout'));
    expect(log, contains('kernel stderr'));
    expect(commands(), [
      {
        'stage': 'kernel',
        'executable': Platform.resolvedExecutable,
        'arguments': [script],
      },
    ]);
  });

  test('a failing tool throws with the stage name and its log', () async {
    await run(Platform.resolvedExecutable, [tool('kernel', 0)], 'kernel');
    await expectLater(
      run(Platform.resolvedExecutable, [tool('ld', 3)], 'link'),
      throwsA(
        isA<StageFailure>()
            .having((e) => e.stage, 'stage', 'link')
            .having((e) => e.errorCode, 'errorCode', 3)
            .having(
              (e) => e.message,
              'message',
              'link failed (3); see ${p.join(work.path, 'link.log')}',
            ),
      ),
    );
    expect(
      File(p.join(work.path, 'link.log')).readAsStringSync(),
      contains('ld stderr'),
    );
    expect(
      [
        for (final command in commands())
          (command! as Map<String, Object?>)['stage'],
      ],
      ['kernel', 'link'],
    );
  });
}
