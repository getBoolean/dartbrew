import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartbrew/src/commands/run.dart';
import 'package:dartbrew/src/device/device.dart';
import 'package:dartbrew/src/device/run_identity.dart';
import 'package:dartbrew/src/errors.dart';
import 'package:dartbrew/src/targets/ctr/azahar.dart';
import 'package:dartbrew/src/targets/ctr/pipeline.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ctr_build_stubs.dart';
import 'support/fake_azahar.dart';

Directory _temp() {
  final dir = Directory.systemTemp.createTempSync('dartbrew-azahar-');
  addTearDown(() async {
    // Windows releases a killed stub's handles on its directory shortly
    // after the process exits.
    for (var attempt = 0; ; attempt++) {
      try {
        return dir.deleteSync(recursive: true);
      } on FileSystemException {
        if (attempt == 50) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  return dir;
}

String _mkdir(String path) {
  Directory(path).createSync(recursive: true);
  return path;
}

AzaharHost _host(
  String os,
  String cwd, [
  Map<String, String> environment = const {},
]) => AzaharHost(
  environment: environment,
  operatingSystem: os,
  currentDirectory: cwd,
);

void _emuIni(
  String userDir,
  String sdmc, {
  bool custom = true,
  String name = 'emu.ini',
  String section = 'Data Storage',
}) {
  File(p.join(userDir, 'config', name))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '[Layout]\nsdmc_directory=wrong\n\n'
      '[$section]\n'
      'use_custom_storage\\default=false\n'
      'use_custom_storage=$custom\n'
      'sdmc_directory=$sdmc\n',
    );
}

final class _Run {
  final int? code;
  final String out;
  final String err;
  final int hostPort;

  /// The fake Azahar process, if one was started.
  final Process? azahar;
  _Run(this.code, this.out, this.err, this.hostPort, this.azahar);
}

Future<int> _freeTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// Runs `dartbrew run -d azahar` on a hello project against a fake SDK,
/// with Azahar looked for only in [environment].
Future<_Run> _run(
  List<String> args, {
  Map<String, String> environment = const {},
  RunDeadlines deadlines = const RunDeadlines(
    connect: Duration(seconds: 20),
    idle: Duration(seconds: 5),
  ),
}) async {
  final root = _temp().path;
  File(p.join(root, 'pubspec.yaml')).writeAsStringSync('name: hello\n');
  File(p.join(root, 'bin', 'main.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('void main() => print("hello:42");');
  final sdk = ctrBuildSdk();
  final hostPort = await _freeTcpPort();
  final out = StringBuffer();
  final err = StringBuffer();
  Process? azahar;
  final runner = CommandRunner<int>('dartbrew', '')
    ..addCommand(
      runCommand(
        environment: sdk.environment,
        start:
            (
              executable,
              arguments, {
              workingDirectory,
              environment,
              mode = ProcessStartMode.normal,
            }) async {
              final process = await startBuildStub(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                mode: mode,
              );
              if (p.basename(executable) == 'azahar.dart') azahar = process;
              return process;
            },
        listenAddress: InternetAddress.loopbackIPv4,
        deadlines: deadlines,
        azaharHost: _host(Platform.operatingSystem, root, environment),
        out: out,
        err: err,
      ),
    );
  final code = await runner.run([
    'run',
    '--sdk',
    sdk.root.path,
    '--project-directory',
    root,
    '--host-port',
    '$hostPort',
    '-d',
    'azahar',
    ...args,
  ]);
  return _Run(code, out.toString(), err.toString(), hostPort, azahar);
}

/// Expects [process] to have been terminated rather than left running.
Future<void> _expectClosed(Process? process) async {
  expect(process, isNotNull, reason: 'Azahar was never started');
  await expectLater(
    process!.exitCode.timeout(const Duration(seconds: 10)),
    completes,
  );
}

void main() {
  group('SD card', () {
    test('DARTBREW_AZAHAR_SDMC overrides a portable user directory and '
        'emu.ini', () {
      final dir = _temp().path;
      final cwd = _mkdir(p.join(dir, 'cwd'));
      _mkdir(p.join(cwd, 'user'));
      _emuIni(p.join(cwd, 'user'), p.join(dir, 'custom'));
      final override = p.join(dir, 'override');

      expect(
        azaharSdmc(
          p.join(dir, 'bin', 'azahar'),
          _host('linux', cwd, {'DARTBREW_AZAHAR_SDMC': override, 'HOME': dir}),
        ),
        override,
      );
    });

    test('a portable user directory beats emu.ini custom storage in the '
        'default user directory and the per-OS default', () {
      final dir = _temp().path;
      final home = _mkdir(p.join(dir, 'home'));
      _emuIni(p.join(home, '.local', 'share', 'azahar-emu'), 'custom');
      final cwd = _mkdir(p.join(dir, 'cwd'));
      _mkdir(p.join(cwd, 'user'));

      expect(
        azaharSdmc('azahar', _host('linux', cwd, {'HOME': home})),
        p.join(cwd, 'user', 'sdmc'),
      );
    });

    test('on Windows the portable user directory is next to the '
        'executable, not in the working directory', () {
      final dir = _temp().path;
      final bin = _mkdir(p.join(dir, 'Azahar'));
      _mkdir(p.join(bin, 'user'));
      final cwd = _mkdir(p.join(dir, 'cwd'));
      _mkdir(p.join(cwd, 'user'));

      expect(
        azaharSdmc(
          p.join(bin, 'azahar.exe'),
          _host('windows', cwd, {'APPDATA': p.join(dir, 'Roaming')}),
        ),
        p.join(bin, 'user', 'sdmc'),
      );
    });

    test('emu.ini custom storage beats the per-OS default', () {
      final dir = _temp().path;
      final appData = p.join(dir, 'Roaming');
      final custom = p.join(dir, 'custom-sdmc');
      _emuIni(p.join(appData, 'Azahar'), custom);

      expect(
        azaharSdmc(
          p.join(dir, 'Program Files', 'azahar.exe'),
          _host('windows', dir, {'APPDATA': appData}),
        ),
        custom,
      );
    });

    test('qt-config.ini custom storage, with the encoded section name, '
        'beats emu.ini', () {
      final dir = _temp().path;
      final appData = p.join(dir, 'Roaming');
      final user = p.join(appData, 'Azahar');
      final qt = p.join(dir, 'qt-sdmc');
      _emuIni(user, p.join(dir, 'emu-sdmc'));
      _emuIni(user, qt, name: 'qt-config.ini', section: 'Data%20Storage');

      expect(
        azaharSdmc('azahar.exe', _host('windows', dir, {'APPDATA': appData})),
        qt,
      );
    });

    test('qt-config.ini without custom storage falls through to emu.ini', () {
      final dir = _temp().path;
      final appData = p.join(dir, 'Roaming');
      final user = p.join(appData, 'Azahar');
      final emu = p.join(dir, 'emu-sdmc');
      _emuIni(user, emu);
      _emuIni(user, 'x', custom: false, name: 'qt-config.ini');

      expect(
        azaharSdmc('azahar.exe', _host('windows', dir, {'APPDATA': appData})),
        emu,
      );
    });

    test('emu.ini without use_custom_storage=true is ignored', () {
      final dir = _temp().path;
      final appData = p.join(dir, 'Roaming');
      _emuIni(p.join(appData, 'Azahar'), 'custom', custom: false);

      expect(
        azaharSdmc('azahar.exe', _host('windows', dir, {'APPDATA': appData})),
        p.join(appData, 'Azahar', 'sdmc'),
      );
    });

    test('per-OS defaults', () {
      final dir = _temp().path;
      final home = p.join(dir, 'home');
      expect(
        azaharSdmc('azahar.exe', _host('windows', dir, {'APPDATA': 'R'})),
        p.join('R', 'Azahar', 'sdmc'),
      );
      expect(
        azaharSdmc('azahar', _host('linux', dir, {'HOME': home})),
        p.join(home, '.local', 'share', 'azahar-emu', 'sdmc'),
      );
      expect(
        azaharSdmc('azahar', _host('macos', dir, {'HOME': home})),
        p.join(home, 'Library', 'Application Support', 'Azahar', 'sdmc'),
      );
    });
  });

  group('executable', () {
    test('--azahar beats DARTBREW_AZAHAR, which beats PATH', () {
      final dir = _temp().path;
      final name = Platform.isWindows ? 'azahar.exe' : 'azahar';
      File flag(String sub) =>
          File(p.join(_mkdir(p.join(dir, sub)), name))..writeAsStringSync('');
      final explicit = flag('explicit');
      final env = flag('env');
      final onPath = flag('path');
      final host = _host(Platform.operatingSystem, dir, {
        'DARTBREW_AZAHAR': env.path,
        'PATH': onPath.parent.path,
      });

      expect(locateAzahar(host, path: explicit.path), explicit.path);
      expect(locateAzahar(host), env.path);
      expect(
        locateAzahar(
          _host(Platform.operatingSystem, dir, {'PATH': onPath.parent.path}),
        ),
        onPath.path,
      );
    });

    test('nothing found names --azahar and DARTBREW_AZAHAR', () {
      expect(
        () => locateAzahar(_host(Platform.operatingSystem, _temp().path)),
        throwsA(
          isA<DartbrewException>().having(
            (e) => e.message,
            'message',
            allOf(contains('--azahar'), contains('DARTBREW_AZAHAR')),
          ),
        ),
      );
    });
  });

  test('the cfg is the eight schema-2 identity lines with environment=azahar '
      'then the host line', () {
    final identity = RunIdentity(
      schema: 2,
      runId: 'a' * 32,
      fixture: 'hello',
      mode: BuildMode.jit,
      compatibility: 'b' * 64,
      artifactSha256: 'c' * 64,
      buildId: 'd' * 64,
      environment: RunEnvironment.azahar,
    );
    expect(
      identity.runConfig(
        host: (address: InternetAddress.loopbackIPv4, port: 17491),
      ),
      'schema=2\n'
      'run_id=${'a' * 32}\n'
      'fixture=hello\n'
      'mode=jit\n'
      'compatibility=${'b' * 64}\n'
      'artifact_sha256=${'c' * 64}\n'
      'build_id=${'d' * 64}\n'
      'environment=azahar\n'
      'host=127.0.0.1:17491\n',
    );
  });

  test('a fake Azahar that connects back passes, exits 0, gets a schema-2 '
      'cfg and is closed afterwards', () async {
    final dir = _temp();
    final sdmc = p.join(dir.path, 'sdmc');
    final azahar = FakeAzahar.create(
      dir,
      sdmc: sdmc,
      mode: FakeAzaharMode.socket,
    );
    final r = await _run(
      ['--azahar', azahar.script.path],
      environment: {'DARTBREW_AZAHAR_SDMC': sdmc},
    );

    expect(r.code, 0, reason: r.err);
    expect(r.out, 'hello:42\n');
    expect(r.err, contains('in Azahar'));
    await _expectClosed(r.azahar);
    final cfg = File(p.join(sdmc, 'ctr-runtime-run.cfg')).readAsLinesSync();
    expect(cfg.map((l) => l.split('=').first), [
      'schema',
      'run_id',
      'fixture',
      'mode',
      'compatibility',
      'artifact_sha256',
      'build_id',
      'environment',
      'host',
    ]);
    expect(cfg.first, 'schema=2');
    expect(cfg[7], 'environment=azahar');
    expect(cfg.last, 'host=127.0.0.1:${r.hostPort}');
    expect(cfg[3], 'mode=aot');
    expect(p.basename(azahar.appArgument), 'dartbrew-hello-aot.3dsx');
  });

  test('--mode jit in Azahar is a usage error before building, because JIT '
      'needs Luma3DS', () async {
    final dir = _temp();
    final sdmc = p.join(dir.path, 'sdmc');
    final azahar = FakeAzahar.create(
      dir,
      sdmc: sdmc,
      mode: FakeAzaharMode.socket,
    );
    await expectLater(
      _run(
        ['--azahar', azahar.script.path, '--mode', 'jit'],
        environment: {'DARTBREW_AZAHAR_SDMC': sdmc},
      ),
      throwsA(
        isA<UsageException>().having(
          (e) => e.message,
          'message',
          allOf(contains('JIT needs Luma3DS'), contains('--mode aot')),
        ),
      ),
    );
    expect(Directory(sdmc).existsSync(), isFalse);
  });

  test('a fake Azahar that never connects falls back to the journal, '
      'ignores older run IDs and exits with the journal\'s verdict', () async {
    final dir = _temp();
    final sdmc = _mkdir(p.join(dir.path, 'sdmc'));
    File(
      p.join(sdmc, 'ctr-runtime.log'),
    ).writeAsStringSync('CTR_RUNTIME {"run_id":"old","event":"begin"}\n');
    final azahar = FakeAzahar.create(
      dir,
      sdmc: sdmc,
      mode: FakeAzaharMode.journal,
    );
    final r = await _run(
      ['--azahar', azahar.script.path],
      environment: {'DARTBREW_AZAHAR_SDMC': sdmc},
      deadlines: const RunDeadlines(
        connect: Duration(seconds: 3),
        idle: Duration(seconds: 1),
      ),
    );

    expect(r.code, 0, reason: r.err);
    expect(r.out, 'from the journal\n');
    await _expectClosed(r.azahar);
  });

  test('a failing run read from the journal exits 255', () async {
    final dir = _temp();
    final sdmc = p.join(dir.path, 'sdmc');
    final azahar = FakeAzahar.create(
      dir,
      sdmc: sdmc,
      mode: FakeAzaharMode.journal,
      journalOutcome: 'fail',
    );
    final r = await _run(
      ['--azahar', azahar.script.path],
      environment: {'DARTBREW_AZAHAR_SDMC': sdmc},
      deadlines: const RunDeadlines(
        connect: Duration(seconds: 3),
        idle: Duration(seconds: 1),
      ),
    );

    expect(r.code, 255, reason: r.err);
    expect(r.out, 'from the journal\n');
    await _expectClosed(r.azahar);
  });

  test('a missing Azahar exits 1 naming --azahar and DARTBREW_AZAHAR before '
      'building', () async {
    final r = await _run([]);

    expect(r.code, 1);
    expect(r.err, contains('--azahar'));
    expect(r.err, contains('DARTBREW_AZAHAR'));
    expect(r.azahar, isNull);
  });

  test('a missing --azahar path exits 1 naming it', () async {
    final missing = p.join(_temp().path, 'nope', 'azahar.exe');
    final r = await _run(['--azahar', missing]);

    expect(r.code, 1);
    expect(r.err, contains(missing));
  });
}
