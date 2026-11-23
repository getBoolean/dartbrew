import 'dart:convert';
import 'dart:io';

import 'package:dartbrew/src/sdk.dart';
import 'package:dartbrew/src/stage_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_sdk.dart';

void main() {
  late FakeSdk fake;
  late Directory work;
  late StageRunner run;

  setUp(() async {
    fake = fakeSdk(tools: {'kernel': 0, 'ld': 3});
    final sdk = await NativeSdk.load(fake.root.path);
    work = Directory.systemTemp.createTempSync('dartbrew-work-');
    final progressFile = File('${work.path}.progress');
    final progress = progressFile.openWrite();
    addTearDown(() async {
      await progress.close();
      progressFile.deleteSync();
      work.deleteSync(recursive: true);
    });
    run = StageRunner(sdk, work, start: startStub, progress: progress);
  });

  List<dynamic> commands() =>
      jsonDecode(File(p.join(work.path, 'commands.json')).readAsStringSync())
          as List<dynamic>;

  test('records each stage and writes its log', () async {
    await run('kernel', ['--output=a.dill', 'main.dart'], 'kernel');
    expect(fake.calls('kernel'), [
      ['--output=a.dill', 'main.dart'],
    ]);
    final log = File(p.join(work.path, 'kernel.log')).readAsStringSync();
    expect(log, contains('kernel stdout'));
    expect(log, contains('kernel stderr'));
    expect(commands(), [
      {
        'stage': 'kernel',
        'executable': p.join(
          fake.root.resolveSymbolicLinksSync(),
          'tools',
          'kernel.dart',
        ),
        'arguments': ['--output=a.dill', 'main.dart'],
      },
    ]);
  });

  test('a failing tool throws with the stage name and its log', () async {
    await run('kernel', [], 'kernel');
    await expectLater(
      run(
        'ld',
        ['-o', 'app.elf'],
        'link',
        executable: p.join(fake.root.path, 'tools', 'ld.dart'),
      ),
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
    expect(commands().map((c) => (c as Map<String, dynamic>)['stage']), [
      'kernel',
      'link',
    ]);
  });
}
