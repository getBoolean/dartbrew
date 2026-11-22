import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:dartbrew/src/commands/run.dart';
import 'package:dartbrew/src/device/device.dart';
import 'package:dartbrew/src/device/transport.dart';
import 'package:dartbrew/src/targets/ctr/netloader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ctr_build_stubs.dart';
import 'support/fake_console.dart';

const _deadlines = RunDeadlines(
  connect: Duration(milliseconds: 600),
  idle: Duration(milliseconds: 400),
);

final class _Run {
  final int? code;
  final String out;
  final String err;
  final int hostPort;
  final String project;
  _Run(this.code, this.out, this.err, this.hostPort, this.project);

  String get output => p.join(project, '.dart_tool/dartbrew/run/ctr/jit');
}

String _project() {
  final root = Directory.systemTemp.createTempSync('dartbrew-run-');
  addTearDown(() => root.deleteSync(recursive: true));
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: hello\n');
  File(p.join(root.path, 'bin', 'main.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('void main() => print("hello:42");');
  return root.path;
}

NetloaderClient _loopbackClient({required int port, int replyPort = 0}) =>
    NetloaderClient(
      port: port,
      replyPort: replyPort,
      receiveAddress: InternetAddress.loopbackIPv4,
      broadcastAddress: InternetAddress.loopbackIPv4,
      interfaceAddresses: () async => [InternetAddress.loopbackIPv4],
    );

Future<int> _freeTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<int> _freeUdpPort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  socket.close();
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return port;
}

/// Runs `dartbrew run` against a fake SDK with [transport] and a free
/// loopback host port.
Future<_Run> _run(
  DeviceTransport transport,
  List<String> args, {
  String? project,
}) async {
  final sdk = ctrBuildSdk();
  final root = project ?? _project();
  final hostPort = await _freeTcpPort();
  final out = StringBuffer();
  final err = StringBuffer();
  final runner = CommandRunner<int>('dartbrew', '')
    ..addCommand(
      runCommand(
        start: startBuildStub,
        transportFor: (_) => transport,
        listenAddress: InternetAddress.loopbackIPv4,
        deadlines: _deadlines,
        settle: const Duration(milliseconds: 100),
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
    ...args,
  ]);
  return _Run(code, out.toString(), err.toString(), hostPort, root);
}

/// Starts a fake console that plays [script] and is closed after the test.
Future<FakeConsole> _console([LauncherScript? script]) async {
  final console = await FakeConsole.start(script: script);
  addTearDown(console.close);
  return console;
}

Future<void> _passing(FakeLauncher app) async {
  app
    ..begin()
    ..output('hello:42')
    ..cleanup('pass')
    ..terminal('pass');
  await app.close();
}

/// Sends a keepalive every 100 ms until the host drops the connection or
/// [limit] passes.
Future<void> _keepalives(FakeLauncher app, Duration limit) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < limit) {
    try {
      app.keepalive();
      await app.socket.flush();
    } catch (_) {
      return; // The host dropped the connection.
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Starts a fake console and its discovery responder on one port number,
/// TCP and UDP, as a real netloader uses.
///
/// The UDP port is allocated first and the console takes the same number for
/// TCP. Windows can refuse that (errno 10013) when the number falls in a
/// range reserved for TCP only, such as Hyper-V's excluded port ranges, so a
/// refused number is held open until the end, making the next allocation
/// pick a different one, and the next number is tried.
Future<FakeConsole> _discoverableConsole(
  int replyPort,
  LauncherScript script,
) async {
  final refused = <RawDatagramSocket>[];
  try {
    for (var attempt = 1; ; attempt++) {
      final responder = await fakeDiscoveryResponder(replyPort);
      try {
        final console = await FakeConsole.start(
          script: script,
          port: responder.port,
        );
        addTearDown(console.close);
        addTearDown(responder.close);
        return console;
      } on SocketException {
        refused.add(responder);
        if (attempt == 1000) rethrow;
      }
    }
  } finally {
    for (final socket in refused) {
      socket.close();
    }
  }
}

/// Emits fixed addresses, standing in for several consoles answering.
final class _FixedDiscovery implements DeviceTransport {
  final List<String> addresses;
  _FixedDiscovery(this.addresses);

  @override
  Stream<InternetAddress> discover(Duration wait) =>
      Stream.fromIterable(addresses.map(InternetAddress.new));

  @override
  Future<void> upload(
    InternetAddress device,
    File app, {
    List<String> arguments = const [],
    void Function(int sent, int total)? onProgress,
  }) => throw StateError('no upload expected');
}

void main() {
  test('a passing program prints its output and exits 0; the upload carries '
      'the identity, the host port and a stable name; JIT skips the '
      'snapshot stage', () async {
    final console = await _console(_passing);
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
    ]);

    expect(r.code, 0, reason: r.err);
    expect(r.out, 'hello:42\n');
    final upload = await console.uploaded;
    expect(upload.name, 'dartbrew-hello-jit.3dsx');
    expect(upload.argv.first, 'sdmc:/3ds/dartbrew-hello-jit.3dsx');
    expect(upload.hostPort, r.hostPort);
    expect(upload.argv, contains('--ctr-host-port=${r.hostPort}'));
    expect(upload.identity('schema'), '2');
    expect(upload.identity('environment'), 'hardware');
    expect(upload.identity('mode'), 'jit');
    expect(upload.identity('run_id'), matches(RegExp(r'^[0-9a-f]{32}$')));
    final app = File(p.join(r.output, 'dartbrew-hello-jit.3dsx'));
    expect(upload.payload, app.readAsBytesSync());
    expect(
      upload.identity('artifact_sha256'),
      sha256.convert(app.readAsBytesSync()).toString(),
    );
    final stages = [
      for (final c
          in jsonDecode(
                File(p.join(r.output, 'work/commands.json')).readAsStringSync(),
              )
              as List)
        (c as Map)['stage'],
    ];
    expect(stages, contains('kernel'));
    expect(stages, isNot(contains('snapshot')));
    expect(File(p.join(r.project, 'run.json')).existsSync(), isFalse);
  });

  test('AE1: an uncaught exception prints the error and stack and exits '
      '255', () async {
    final console = await _console((app) async {
      app
        ..begin()
        ..output(
          'Unhandled exception:\nBad state: boom\n'
          '#0      main (file:///bin/main.dart:1:20)',
        )
        ..cleanup('fail')
        ..terminal('fail');
      await app.close();
    });
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
    ]);

    expect(r.code, 255);
    expect(r.out, contains('Bad state: boom'));
    expect(r.out, contains('#0      main (file:///bin/main.dart:1:20)'));
  });

  test('exit(3) on the console makes run exit 3 and the verdict carries '
      'it', () async {
    final console = await _console((app) async {
      app
        ..begin()
        ..cleanup('pass')
        ..terminal('fail', exitCode: 3);
      await app.close();
    });
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
      '--verdict',
    ]);

    expect(r.code, 3);
    final lines = const LineSplitter().convert(r.out);
    final verdict = jsonDecode(lines.last) as Map<String, Object?>;
    expect(verdict['outcome'], 'fail');
    expect(verdict['exit_code'], 3);
  });

  test('AE2: a connection closed after begin is a lost connection', () async {
    final console = await _console((app) async {
      app.begin();
      await app.close();
    });
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
    ]);

    expect(r.code, 1);
    expect(r.err, contains('lost connection'));
  });

  test('AE2: a connection that goes silent without closing is lost after '
      'the idle deadline', () async {
    final console = await _console((app) async {
      app.begin();
      await app.socket.flush();
    });
    final watch = Stopwatch()..start();
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
    ]);

    expect(r.code, 1);
    expect(r.err, contains('lost connection'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('keepalives during a long quiet program keep the run alive', () async {
    final console = await _console((app) async {
      app.begin();
      // Quiet for twice the idle deadline, with keepalives.
      await _keepalives(app, const Duration(milliseconds: 800));
      app
        ..output('done')
        ..cleanup('pass')
        ..terminal('pass');
      await app.close();
    });
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
    ]);

    expect(r.code, 0, reason: r.err);
    expect(r.out, 'done\n');
  });

  test('an acknowledged upload never followed by a connection names the '
      'host firewall and the port', () async {
    final console = await _console();
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
    ]);

    expect(r.code, 1);
    expect(r.err, contains('firewall'));
    expect(r.err, contains('port ${r.hostPort}'));
  });

  test('--timeout stops a run that never ends', () async {
    final console = await _console((app) async {
      app.begin();
      await _keepalives(app, const Duration(seconds: 10));
    });
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
      '--timeout',
      '1',
    ]);

    expect(r.code, 1);
    expect(r.err, contains('timed out'));
  });

  test('AE5: no console answering within --wait exits 1 with guidance to '
      'press Y', () async {
    final r = await _run(
      _loopbackClient(port: await _freeUdpPort(), replyPort: 0),
      ['--wait', '0.3'],
    );

    expect(r.code, 1);
    expect(r.err, contains('Open the netloader in Homebrew Launcher'));
    expect(r.err, contains('No console answered within 0.3 s'));
    expect(r.err, contains('press Y'));
  });

  test('a console found by discovery receives the upload', () async {
    final replyPort = await _freeUdpPort();
    final console = await _discoverableConsole(replyPort, _passing);

    final r = await _run(
      _loopbackClient(port: console.port, replyPort: replyPort),
      ['-d', 'console', '--wait', '5'],
    );

    expect(r.code, 0, reason: r.err);
    expect(r.out, 'hello:42\n');
  });

  test('two consoles answering discovery exits 64 and lists both', () async {
    final r = await _run(_FixedDiscovery(['192.0.2.10', '192.0.2.11']), [
      '--wait',
      '1',
    ]);

    expect(r.code, 64);
    expect(r.err, contains('192.0.2.10'));
    expect(r.err, contains('192.0.2.11'));
    expect(r.err, contains('-d'));
  });

  test('--verdict prints a verdict matching the built app and writes '
      'run.json', () async {
    final console = await _console(_passing);
    final r = await _run(_loopbackClient(port: console.port), [
      '-d',
      '127.0.0.1',
      '--verdict',
    ]);

    expect(r.code, 0, reason: r.err);
    final lines = const LineSplitter().convert(r.out);
    expect(lines.first, 'hello:42');
    final verdict = jsonDecode(lines.last) as Map<String, Object?>;
    final upload = await console.uploaded;
    final app = File(p.join(r.output, 'dartbrew-hello-jit.3dsx'));
    expect(verdict, {
      'outcome': 'pass',
      'reason': null,
      'run_id': upload.identity('run_id'),
      'artifact_sha256': sha256.convert(app.readAsBytesSync()).toString(),
    });
    final identity =
        jsonDecode(File(p.join(r.output, 'run.json')).readAsStringSync())
            as Map<String, Object?>;
    expect(identity['run_id'], verdict['run_id']);
    expect(identity['artifact_sha256'], verdict['artifact_sha256']);
    expect(identity['schema'], 2);
  });
}
