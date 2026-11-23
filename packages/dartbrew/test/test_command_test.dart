import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartbrew/src/commands/run.dart';
import 'package:dartbrew/src/commands/test.dart';
import 'package:dartbrew/src/device/device.dart';
import 'package:dartbrew/src/process.dart';
import 'package:dartbrew/src/stage_runner.dart';
import 'package:dartbrew/src/targets/ctr/netloader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ctr_build_stubs.dart';
import 'support/fake_console.dart';
import 'support/test_events.dart';

const _deadlines = RunDeadlines(
  connect: Duration(milliseconds: 600),
  idle: Duration(milliseconds: 400),
);

typedef _Result = ({int? code, String out, String err, String project});

String _project(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('dartbrew-test-');
  addTearDown(() => root.deleteSync(recursive: true));
  final files0 = {'pubspec.yaml': 'name: hello\n', ...files};
  files0.forEach((path, contents) {
    File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  });
  return root.resolveSymbolicLinksSync();
}

const _testFile = "import 'package:test/test.dart';\nvoid main() {}\n";

Future<int> _freeTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// A console that plays [stream]'s lines as output records and ends the run
/// normally.
Future<FakeConsole> _console(RecordedStream stream) async {
  final console = await FakeConsole.start(
    script: (app) async {
      app.begin();
      for (final line in stream.lines) {
        app.output(line);
      }
      app
        ..cleanup('pass')
        ..terminal('pass');
      await app.close();
    },
  );
  addTearDown(console.close);
  return console;
}

Future<_Result> _test(
  String project,
  List<String> args, {
  FakeConsole? console,
  ProcessStarter start = startBuildStub,
  String command = 'test',
  StringBuffer? out,
  Stream<Object?> Function()? interrupts,
  Future<void> Function(int exitCode)? exitProcess,
}) async {
  final sdk = ctrBuildSdk();
  out ??= StringBuffer();
  final err = StringBuffer();
  NetloaderClient transport() => NetloaderClient(
    port: console?.port ?? 1,
    receiveAddress: InternetAddress.loopbackIPv4,
    broadcastAddress: InternetAddress.loopbackIPv4,
    interfaceAddresses: () async => [InternetAddress.loopbackIPv4],
  );
  final runner = CommandRunner<int>('dartbrew', '')
    ..addCommand(
      testCommand(
        environment: sdk.environment,
        start: start,
        transport: transport,
        listenAddress: InternetAddress.loopbackIPv4,
        deadlines: _deadlines,
        interrupts: interrupts,
        exitProcess: exitProcess ?? (_) => fail('exitProcess called'),
        out: out,
        err: err,
      ),
    )
    ..addCommand(
      runCommand(
        environment: sdk.environment,
        start: start,
        transport: transport,
        listenAddress: InternetAddress.loopbackIPv4,
        deadlines: _deadlines,
        out: out,
        err: err,
      ),
    );
  final code = await runner.run([
    command,
    '--sdk',
    sdk.root.path,
    '--project-directory',
    project,
    '--host-port',
    '${await _freeTcpPort()}',
    '-d',
    '127.0.0.1',
    ...args,
  ]);
  return (code: code, out: '$out', err: '$err', project: project);
}

String _entrypoint(String project) => File(
  p.join(project, '.dart_tool', 'dartbrew', 'test', 'dartbrew_test.dart'),
).readAsStringSync();

/// Wraps [startBuildStub] so the kernel stage fails for [bad] and for any
/// entrypoint importing it, like a syntax error in that file.
ProcessStarter _failingKernelFor(String bad) {
  final script =
      File(
        p.join(
          Directory.systemTemp.createTempSync('dartbrew-kfail-').path,
          'k.dart',
        ),
      )..writeAsStringSync('''
import 'dart:io';
void main() {
  stderr.writeln("$bad:2:1: Error: Expected ';' after this.");
  exitCode = 254;
}
''');
  addTearDown(() => script.parent.deleteSync(recursive: true));
  return (
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    final entry = arguments.isEmpty ? '' : arguments.last;
    final failing =
        p.basenameWithoutExtension(executable) == 'kernel' &&
        (p.basename(entry) == bad ||
            (entry.endsWith('dartbrew_test.dart') &&
                File(entry).readAsStringSync().contains(bad)));
    if (failing) {
      return Process.start(Platform.resolvedExecutable, [
        script.path,
      ], workingDirectory: workingDirectory);
    }
    return startBuildStub(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: mode,
    );
  };
}

void main() {
  test('three passing tests on the console report "All tests passed!" and '
      'exit 0; the app is a test build of the project', () async {
    final project = _project({
      'test/a_test.dart': _testFile,
      'test/nested/b_test.dart': _testFile,
      'test/helper.dart': '',
    });
    final console = await _console(RecordedStream.passing(3));
    final r = await _test(project, [], console: console);

    expect(r.code, 0, reason: r.err);
    expect(r.out, endsWith('+3: All tests passed!\n'));
    expect((await console.uploaded).name, 'dartbrew-hello-test-jit.3dsx');
    final source = _entrypoint(project);
    expect(source, contains('test/a_test.dart" as t0;'));
    expect(source, contains('test/nested/b_test.dart" as t1;'));
    expect(source, isNot(contains('helper.dart')));
  });

  test('AE3: one pure test and one socket connect report sockets as '
      'unsupported, 1 passed 1 failed, exit 1', () async {
    final project = _project({'test/net_test.dart': _testFile});
    final console = await _console(RecordedStream.unsupportedSocket());
    final r = await _test(project, [], console: console);

    expect(r.code, 1);
    expect(r.out, contains('net_test.dart: connects [E]'));
    expect(r.out, contains('sockets is not supported on CTR'));
    expect(r.out, endsWith('+1 -1: Some tests failed.\n'));
  });

  test('a test program that calls exit(3) after its tests makes test exit '
      '3 and says so', () async {
    final project = _project({'test/a_test.dart': _testFile});
    final stream = RecordedStream.passing(1);
    final console = await FakeConsole.start(
      script: (app) async {
        app.begin();
        stream.lines.forEach(app.output);
        app
          ..cleanup('pass')
          ..terminal('fail', exitCode: 3);
        await app.close();
      },
    );
    addTearDown(console.close);
    final r = await _test(project, [], console: console);

    expect(r.code, 3);
    expect(r.out, contains('exit code 3'));
  });

  test('a run that stops without done fails the unfinished tests', () async {
    final project = _project({'test/a_test.dart': _testFile});
    final stream = RecordedStream();
    final suite = stream.suite('test/a_test.dart');
    stream
      ..plan(suite, ['one', 'two', 'three'])
      ..pass(suite, 'one')
      ..start(suite, 'two');
    final console = await FakeConsole.start(
      script: (app) async {
        app.begin();
        stream.lines.forEach(app.output);
        app.output("Failed to resolve native function 'Socket_CreateConnect'");
        await app.close(); // No terminal record: the VM died.
      },
    );
    addTearDown(console.close);
    final r = await _test(project, [], console: console);

    expect(r.code, 1);
    expect(r.out, contains('sockets is not supported on CTR'));
    expect(r.out, endsWith('+1 -2: Some tests failed.\n'));
  });

  test('--name and --plain-name are baked into the entrypoint', () async {
    final project = _project({'test/a_test.dart': _testFile});
    final console = await _console(RecordedStream.passing(1));
    final r = await _test(project, [
      '--name',
      'parse',
      '--plain-name',
      'int, really',
      'test/a_test.dart',
    ], console: console);

    expect(r.code, 0, reason: r.err);
    final source = _entrypoint(project);
    expect(source, contains('RegExp("parse"),'));
    expect(source, contains('"int, really",'));
  });

  test('--reporter json writes protocol events to stdout', () async {
    final project = _project({'test/a_test.dart': _testFile});
    final console = await _console(RecordedStream.passing(2));
    final r = await _test(project, ['--reporter', 'json'], console: console);

    expect(r.code, 0, reason: r.err);
    final lines = r.out.trim().split('\n');
    expect(
      lines.first,
      startsWith('{"type":"start","protocolVersion":"0.1.1"'),
    );
    expect(lines[1], startsWith('{"type":"allSuites","count":1'));
    expect(lines.last, startsWith('{"type":"done","success":true'));
  });

  group('--reporter json ends with done', () {
    Map<String, Object?> lastEvent(String out) =>
        jsonDecode(const LineSplitter().convert(out).last)
            as Map<String, Object?>;

    test('when a test fails', () async {
      final project = _project({'test/net_test.dart': _testFile});
      final console = await _console(RecordedStream.unsupportedSocket());
      final r = await _test(project, ['-r', 'json'], console: console);

      expect(r.code, 1);
      expect(lastEvent(r.out), containsPair('type', 'done'));
      expect(lastEvent(r.out), containsPair('success', false));
    });

    test('when the device drops mid-run', () async {
      final project = _project({'test/a_test.dart': _testFile});
      final stream = RecordedStream();
      final suite = stream.suite('test/a_test.dart');
      stream
        ..plan(suite, ['one', 'two'])
        ..start(suite, 'one');
      final console = await FakeConsole.start(
        script: (app) async {
          app.begin();
          stream.lines.forEach(app.output);
          await app.close();
        },
      );
      addTearDown(console.close);
      final r = await _test(project, ['-r', 'json'], console: console);

      expect(r.code, 1);
      expect(lastEvent(r.out), containsPair('type', 'done'));
      expect(lastEvent(r.out), containsPair('success', false));
    });

    test(
      'when the app cannot be sent, keeping the message and exit code',
      () async {
        final project = _project({'test/a_test.dart': _testFile});
        final r = await _test(project, ['-r', 'json']);

        expect(r.code, 1);
        expect(r.err, contains('Could not connect to the netloader'));
        expect(lastEvent(r.out), {
          'type': 'done',
          'success': false,
          'time': isA<int>(),
        });
      },
    );

    test('when the build fails', () async {
      final project = _project({'test/a_test.dart': _testFile});
      final out = StringBuffer();
      await expectLater(
        _test(
          project,
          ['-r', 'json'],
          start: _failingKernelFor('dartbrew_test.dart'),
          out: out,
        ),
        throwsA(isA<StageFailure>()),
      );
      expect(lastEvent('$out'), containsPair('type', 'done'));
      expect(lastEvent('$out'), containsPair('success', false));
    });

    test('interrupting native compilation cleans staging before exit', () async {
      final project = _project({'test/a_test.dart': _testFile});
      final interrupts = StreamController<Object?>();
      addTearDown(interrupts.close);
      final exit = Completer<({int code, bool staged})>();
      Directory? staging;
      final result = await _test(
        project,
        ['-r', 'json'],
        interrupts: () => interrupts.stream,
        exitProcess: (code) async {
          exit.complete((code: code, staged: staging!.existsSync()));
        },
        start:
            (
              exe,
              args, {
              workingDirectory,
              environment,
              mode = ProcessStartMode.normal,
            }) async {
              if (args.length == 1 &&
                  args.single.startsWith('@') &&
                  staging == null) {
                final response = File(args.single.substring(1));
                staging = response.parent.parent;
                final script = File(p.join(project, 'pending.dart'))
                  ..writeAsStringSync(
                    'Future<void> main() => Future<void>.delayed(const Duration(seconds: 20));',
                  );
                final child = await Process.start(Platform.resolvedExecutable, [
                  script.path,
                ]);
                interrupts.add(null);
                return child;
              }
              return startBuildStub(
                exe,
                args,
                workingDirectory: workingDirectory,
                environment: environment,
                mode: mode,
              );
            },
      );
      expect(result.code, 130);
      expect(await exit.future, (code: 130, staged: false));
      expect(lastEvent(result.out), containsPair('type', 'done'));
    });

    test('when the user interrupts the run, then exits 130', () async {
      final project = _project({'test/a_test.dart': _testFile});
      final interrupts = StreamController<Object?>();
      final stream = RecordedStream();
      final suite = stream.suite('test/a_test.dart');
      stream
        ..plan(suite, ['one', 'two'])
        ..start(suite, 'one');
      final console = await FakeConsole.start(
        script: (app) async {
          app.begin();
          stream.lines.forEach(app.output);
          await app.socket.flush();
          interrupts.add(null);
        },
      );
      addTearDown(console.close);
      final exits = <int>[];
      final r = await _test(
        project,
        ['-r', 'json'],
        console: console,
        interrupts: () => interrupts.stream,
        exitProcess: (code) async => exits.add(code),
      );

      expect(exits, [130]);
      final done = [
        for (final line in const LineSplitter().convert(r.out))
          if (line.startsWith('{"type":"done"')) line,
      ];
      expect(done, hasLength(1));
      expect(lastEvent(r.out), containsPair('type', 'done'));
      expect(lastEvent(r.out), containsPair('success', false));
    });

    test('compact output gains nothing when the app cannot be sent', () async {
      final project = _project({'test/a_test.dart': _testFile});
      final r = await _test(project, []);

      expect(r.code, 1);
      expect(r.out, isEmpty);
    });
  });

  test('a syntax error in one of three files is a load error; the other two '
      'run and the command exits 1', () async {
    final project = _project({
      'test/a_test.dart': _testFile,
      'test/bad_test.dart': 'void main() {',
      'test/c_test.dart': _testFile,
    });
    // The rebuilt entrypoint numbers its events after the host load error.
    final stream = RecordedStream(firstId: 2);
    final a = stream.suite('test/a_test.dart');
    final c = stream.suite('test/c_test.dart');
    stream
      ..plan(a, ['a'])
      ..plan(c, ['c'])
      ..pass(a, 'a')
      ..pass(c, 'c')
      ..done();
    final console = await _console(stream);
    final r = await _test(
      project,
      [],
      console: console,
      start: _failingKernelFor('bad_test.dart'),
    );

    expect(r.code, 1, reason: r.err);
    expect(
      r.out,
      contains(
        '+0 -1: loading test/bad_test.dart [E]\n'
        '  Failed to load "test/bad_test.dart":\n',
      ),
    );
    expect(r.out, contains("Error: Expected ';' after this."));
    expect(r.out, contains('test/a_test.dart: a'));
    expect(r.out, contains('test/c_test.dart: c'));
    expect(r.out, endsWith('+2 -1: Some tests failed.\n'));
    final source = _entrypoint(project);
    expect(source, isNot(contains('bad_test.dart')));
    expect(source, contains('int _nextId = 2;'));
  });

  test('a kernel failure no single file explains is rethrown', () async {
    final project = _project({'test/a_test.dart': _testFile});
    await expectLater(
      _test(project, [], start: _failingKernelFor('dartbrew_test.dart')),
      throwsA(
        isA<StageFailure>()
            .having((e) => e.stage, 'stage', 'kernel')
            .having((e) => e.message, 'message', startsWith('kernel failed')),
      ),
    );
  });

  test('test and run build into separate directories, so neither deletes '
      "the other's build", () async {
    final project = _project({
      'test/a_test.dart': _testFile,
      'bin/main.dart': 'void main() {}',
    });
    final testApp = File(
      p.join(
        project,
        '.dart_tool/dartbrew/test/ctr/jit/dartbrew-hello-test-jit.3dsx',
      ),
    );
    final runApp = File(
      p.join(
        project,
        '.dart_tool/dartbrew/run/ctr/jit/dartbrew-hello-jit.3dsx',
      ),
    );

    Future<void> build(String command) async {
      final console = await _console(RecordedStream.passing(1));
      final r = await _test(project, [], console: console, command: command);
      expect(r.code, 0, reason: r.err);
    }

    await build('test');
    expect(testApp.existsSync(), isTrue);
    await build('run');
    expect(runApp.existsSync(), isTrue);
    expect(testApp.existsSync(), isTrue, reason: 'run kept the test build');
    await build('test');
    expect(runApp.existsSync(), isTrue, reason: 'test kept the run build');
  });

  test('no test files exits 79', () async {
    final project = _project({'test/helper.dart': ''});
    final r = await _test(project, []);

    expect(r.code, 79);
    expect(r.err, contains('No test files were found'));
  });

  test('a test_api outside the tested range warns', () async {
    final project = _project({
      'test/a_test.dart': _testFile,
      'pubspec.lock':
          'packages:\n  test_api:\n    dependency: transitive\n'
          '    source: hosted\n    version: "0.8.0"\n',
    });
    final console = await _console(RecordedStream.passing(1));
    final r = await _test(project, [], console: console);

    expect(r.code, 0, reason: r.err);
    expect(r.err, contains('Warning: this project resolves test_api 0.8.0'));
  });

  test('a test path outside the project is a usage error', () async {
    final project = _project({'test/a_test.dart': _testFile});
    await expectLater(_test(project, ['..']), throwsA(isA<UsageException>()));
  });

  test(
    'the per-file kernel checks use the platform and packages of the build',
    () async {
      final project = _project({
        'test/a_test.dart': _testFile,
        'test/bad_test.dart': '',
      });
      final console = await _console(RecordedStream.passing(1));
      await _test(
        project,
        [],
        console: console,
        start: _failingKernelFor('bad_test.dart'),
      );
      final checks = File(
        p.join(
          project,
          '.dart_tool',
          'dartbrew',
          'test',
          'check',
          'commands.json',
        ),
      ).readAsStringSync();
      expect(checks, contains('--platform='));
      expect(checks, contains('--packages='));
      expect(checks, contains('check-0'));
      expect(checks, contains('check-1'));
    },
  );
}
