// Each test starts the CLI from source in fresh VMs, which can exceed the
// default 30 s under a fully loaded parallel run.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartbrew/src/commands/target_option.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_sdk.dart';
import 'support/ctr_build_stubs.dart';

final hostCli = File('bin/dartbrew.dart').absolute.path;
Future<ProcessResult> invoke(
  List<String> args, {
  List<String> vm = const [],
  Map<String, String>? environment,
}) => Process.run(Platform.resolvedExecutable, [
  ...vm,
  hostCli,
  ...args,
], environment: environment);

class _TargetProbe extends Command<int> {
  @override
  String get name => 'probe';
  @override
  String get description => 'Reports the selected target.';
  _TargetProbe() {
    addTargetOption(argParser);
  }
  @override
  int run() => argResults!.option('target') == 'ctr' ? 0 : 1;
}

void main() {
  test('help lists the owned and passthrough commands', () async {
    final help = await invoke(['--help']);
    expect(help.exitCode, 0);
    expect(help.stdout, contains('Usage: dartbrew <command> [arguments]'));
    for (final command in [
      'create',
      'compile',
      'run',
      'test',
      'devices',
      'doctor',
      'pub',
      'analyze',
      'format',
      'fix',
      'doc',
      'info',
    ]) {
      expect(help.stdout, contains(command));
    }
    expect(help.stdout, isNot(contains('  install')));
    expect(help.stdout, isNot(contains('3DS')));
    expect(help.stderr, isEmpty);
    final doctorHelp = await invoke(['help', 'doctor']);
    expect(doctorHelp.exitCode, 0);
    expect(doctorHelp.stdout, isNot(contains('3DS')));
  });

  test('--version prints development without a define', () async {
    final result = await invoke(['--version']);
    expect(result.exitCode, 0);
    expect(result.stdout, 'development\n');
  });

  test('--version prints the injected version', () async {
    final result = await invoke(
      ['--version'],
      vm: ['-DDARTBREW_VERSION=9.8.7-test'],
    );
    expect(result.exitCode, 0);
    expect(result.stdout, '9.8.7-test\n');
  });

  test('an unknown command exits 64 with usage on stderr', () async {
    final result = await invoke(['frobnicate']);
    expect(result.exitCode, 64);
    expect(result.stdout, isEmpty);
    expect(
      result.stderr,
      contains('Could not find a command named "frobnicate".'),
    );
    expect(result.stderr, contains('Usage: dartbrew <command> [arguments]'));
  });

  test(
    'run -d with an invalid address exits 64 with usage on stderr',
    () async {
      final result = await invoke(['run', '-d', '300.1.1.1']);
      expect(result.exitCode, 64);
      expect(
        result.stderr,
        contains(
          '-d must be "console", "azahar" or a console\'s IPv4 address.',
        ),
      );
      expect(result.stderr, contains('Usage: dartbrew run'));
    },
  );

  test('doctor verifies a sealed SDK', () async {
    final sdk = ctrBuildSdk();
    final result = await invoke([
      'doctor',
      '--sdk',
      sdk.root.path,
    ], environment: sdk.environment);
    expect(result.stderr, isEmpty);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('Verified native SDK for '));
    expect(
      result.stdout,
      contains('Qualified: devkitARM r68-1, libctru 2.7.0-1.'),
    );
  });

  test('doctor names a modified file', () async {
    final sdk = fakeSdk(tools: {'dart': 0});
    File(p.join(sdk.root.path, 'tools', 'dart.dart')).writeAsStringSync('x');
    final result = await invoke(['doctor', '--sdk', sdk.root.path]);
    expect(result.exitCode, 65);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('SDK asset hash mismatch: tools/dart.dart'));
  });

  group('--target', () {
    CommandRunner<int> runner() =>
        CommandRunner<int>('dartbrew', '')..addCommand(_TargetProbe());

    test('defaults to ctr', () async {
      expect(await runner().run(['probe']), 0);
    });

    test('accepts ctr', () async {
      expect(await runner().run(['probe', '--target', 'ctr']), 0);
    });

    test('rejects an unknown target and lists ctr', () async {
      await expectLater(
        runner().run(['probe', '--target', 'ntr']),
        throwsA(
          isA<UsageException>()
              .having(
                (e) => e.message,
                'message',
                contains('"ntr" is not an allowed value'),
              )
              .having((e) => e.usage, 'usage', contains('[ctr] (default)')),
        ),
      );
    });
  });
}
