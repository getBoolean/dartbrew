import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:dartbrew/src/commands/compile.dart';
import 'package:dartbrew/src/targets/ctr/pipeline.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ctr_build_stubs.dart';
import 'support/fake_sdk.dart';

/// A project directory with `main.dart` inside a temporary owner directory.
class _Project {
  final Directory owner;
  final String root;
  final String entry;
  _Project(this.owner, this.root, this.entry);
  String get output => p.join(owner.path, 'output');
}

_Project _project({String? pubspec}) {
  final owner = Directory.systemTemp.createTempSync('dartbrew-compile-');
  addTearDown(() => owner.deleteSync(recursive: true));
  // The CLI resolves symlinks in the project path (macOS's TMPDIR is
  // /var/folders/..., a symlink to /private/var/...), so expectations must too.
  final root = Directory(p.join(owner.resolveSymbolicLinksSync(), 'project'))
    ..createSync();
  if (pubspec != null) {
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
  }
  final entry = File(p.join(root.path, 'main.dart'))
    ..writeAsStringSync('void main() {}');
  return _Project(owner, root.path, entry.path);
}

/// Runs `compile` with stub tools and returns its standard output.
Future<String> _compile(FakeSdk sdk, List<String> args) async {
  final controller = StreamController<List<int>>();
  final text = utf8.decodeStream(controller.stream);
  final out = IOSink(controller);
  final runner = CommandRunner<int>('dartbrew', '')
    ..addCommand(CompileCommand(start: startBuildStub, out: out));
  try {
    expect(await runner.run(['compile', '--sdk', sdk.root.path, ...args]), 0);
  } finally {
    await out.close();
  }
  return text;
}

List<String> _stages(String output) => [
  for (final command
      in jsonDecode(
            File(p.join(output, 'work/commands.json')).readAsStringSync(),
          )
          as List)
    (command as Map)['stage'] as String,
];

Map<String, Object?> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

void main() {
  test('metadata assembly has exactly the native Program fields', () {
    final assembly = programAssembly('jit', 'app', 'a' * 64, 'b' * 64, 123);
    expect(assembly, contains('.word 0, 0, ctr_kernel, 123'));
    expect(assembly, contains('.size ctr_program, 32'));
    expect(
      assembly,
      contains('.word ctr_fixture, ctr_mode, ctr_compatibility, ctr_build_id'),
    );
  });

  test(
    'without --project-directory the nearest pubspec owns the entry',
    () async {
      final project = _project(pubspec: 'name: snake\n');
      final bin = Directory(p.join(project.root, 'bin'))..createSync();
      final entry = File(p.join(bin.path, 'main.dart'))
        ..writeAsStringSync('void main() {}');
      final sdk = ctrBuildSdk();
      await _compile(sdk, ['-o', project.output, entry.path]);
      expect(_stages(project.output).first, 'packages');
      expect(_json(p.join(project.output, 'run.json'))['fixture'], 'snake');
    },
  );

  test('missing SDK cannot modify the project or output', () async {
    final project = _project();
    final runner = CommandRunner<int>('dartbrew', '')
      ..addCommand(CompileCommand());
    await expectLater(
      runner.run([
        'compile',
        project.entry,
        '--sdk',
        p.join(project.owner.path, 'missing'),
        '--output',
        project.output,
      ]),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(project.entry).readAsStringSync(), 'void main() {}');
    expect(project.owner.listSync().map((f) => f.path), [project.root]);
  });

  test('aot runs every stage in order and stages the SD card', () async {
    final sdk = ctrBuildSdk();
    final project = _project(pubspec: 'name: hello_app\n');
    final message = await _compile(sdk, [
      '--mode',
      'aot',
      '-o',
      project.output,
      project.entry,
    ]);
    final output = project.output;
    expect(_stages(output), [
      'packages',
      'kernel',
      'snapshot',
      'assemble-payload',
      'assemble-program',
      'link',
    ]);
    for (final stage in _stages(output)) {
      expect(File(p.join(output, 'work/$stage.log')).existsSync(), isTrue);
    }
    final application = File(p.join(output, 'application.3dsx'));
    expect(application.readAsBytesSync().sublist(0, 4), utf8.encode('3DSX'));
    final artifactSha = sha256
        .convert(application.readAsBytesSync())
        .toString();

    final artifact = _json(p.join(output, 'artifact.json'));
    final sdkHash = sha256
        .convert(File(p.join(sdk.root.path, 'sdk.json')).readAsBytesSync())
        .toString();
    final payloadHash = sha256
        .convert(File(p.join(output, 'work/payload.S')).readAsBytesSync())
        .toString();
    expect(artifact, {
      'schema': 1,
      'scope': 'compile-link-package-only',
      'fixture': 'hello_app',
      'mode': 'aot',
      'compatibility': 'a' * 64,
      'build_id': sha256
          .convert(
            utf8.encode(jsonEncode([sdkHash, 'aot', 'hello_app', payloadHash])),
          )
          .toString(),
      'artifact_sha256': artifactSha,
      'payload_sha256': payloadHash,
      'elf_sha256': sha256
          .convert(
            File(p.join(output, 'work/application.elf')).readAsBytesSync(),
          )
          .toString(),
      'sdk_head': 'head',
      'sdk_manifest_sha256': sdkHash,
    });

    final run = _json(p.join(output, 'run.json'));
    final runId = run['run_id'] as String;
    expect(runId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(run, {
      'schema': 1,
      'run_id': runId,
      'fixture': 'hello_app',
      'mode': 'aot',
      'compatibility': 'a' * 64,
      'artifact_sha256': artifactSha,
      'build_id': artifact['build_id'],
      'environment': 'hardware',
    });
    expect(
      File(p.join(output, 'SDROOT/ctr-runtime-run.cfg')).readAsStringSync(),
      run.entries.map((e) => '${e.key}=${e.value}\n').join(),
    );
    final app = 'ctr-dart-aot-${runId.substring(0, 8)}';
    final appDirectory = p.join(output, 'SDROOT/3ds', app);
    expect(
      File(p.join(appDirectory, '$app.3dsx')).readAsBytesSync(),
      application.readAsBytesSync(),
    );
    expect(
      File(p.join(appDirectory, 'notices/LICENSE.txt')).readAsStringSync(),
      'notices/LICENSE.txt',
    );

    expect(message, contains(application.path));
    expect(message, contains('application.3dsx'));
    expect(message, contains('SDROOT'));
    expect(message.replaceAll('.3dsx', ''), isNot(contains('3DS')));
  });

  test('jit skips the snapshot stage and embeds the kernel', () async {
    final sdk = ctrBuildSdk();
    final project = _project();
    await _compile(sdk, ['--mode', 'jit', '-o', project.output, project.entry]);
    expect(_stages(project.output), [
      'kernel',
      'assemble-payload',
      'assemble-program',
      'link',
    ]);
    expect(sdk.calls('snapshot'), isEmpty);
    expect(sdk.calls('kernel').single, isNot(contains('--aot')));
    expect(
      File(p.join(project.output, 'work/payload.S')).readAsStringSync(),
      contains('.incbin "application.dill"'),
    );
    expect(_json(p.join(project.output, 'artifact.json'))['mode'], 'jit');
  });

  for (final mode in ['aot', 'jit']) {
    test(
      '$mode links the dart:io archive ahead of the runtime archive',
      () async {
        final sdk = ctrBuildSdk();
        final project = _project();
        await _compile(sdk, [
          '--mode',
          mode,
          '-o',
          project.output,
          project.entry,
        ]);
        final link = [
          for (final argument in sdk.calls('ld').single)
            argument.replaceAll(r'\', '/'),
        ];
        int position(String suffix) =>
            link.indexWhere((a) => a.endsWith(suffix));
        final io = position('/runtime/$mode-io.a');
        // The launcher objects call into the I/O layer, which calls the VM.
        expect(io, greaterThan(position('/work/payload.o')));
        expect(io, lessThan(position('/runtime/$mode.a')));
      },
    );
  }

  group('SDK verification', () {
    test('ignores a modified asset the build does not read', () async {
      final sdk = ctrBuildSdk();
      File(p.join(sdk.root.path, 'bin', 'tool')).writeAsStringSync('changed');
      final project = _project();
      await _compile(sdk, ['-o', project.output, project.entry]);
      expect(
        File(p.join(project.output, 'application.3dsx')).existsSync(),
        isTrue,
      );
    });

    test('names a modified asset the build reads', () async {
      final sdk = ctrBuildSdk();
      File(
        p.join(sdk.root.path, 'runtime', 'aot-io.a'),
      ).writeAsStringSync('changed');
      final project = _project();
      await expectLater(
        _compile(sdk, ['-o', project.output, project.entry]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'SDK asset hash mismatch: runtime/aot-io.a',
          ),
        ),
      );
    });

    test(
      'an SDK manifest without io_archive exits 65 naming the key',
      () async {
        final sdk = ctrBuildSdk();
        sdk.editManifest((json) {
          final modes = (json['runtime']! as Map)['modes']! as Map;
          for (final mode in modes.values) {
            (mode as Map).remove('io_archive');
          }
        });
        final project = _project();
        final result = await Process.run(Platform.resolvedExecutable, [
          File('bin/dartbrew.dart').absolute.path,
          'compile',
          '--sdk',
          sdk.root.path,
          '-o',
          project.output,
          project.entry,
        ]);
        expect(result.exitCode, 65);
        expect(result.stderr, contains('runtime.modes.aot.io_archive'));
        expect(
          (result.stderr as String).toLowerCase(),
          contains('update dartbrew'),
        );
        expect(Directory(project.output).existsSync(), isFalse);
      },
      // Starting the CLI from source in a fresh VM can exceed the default
      // 30 s under a fully loaded parallel run.
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  test('compiles AOT when no mode is given', () async {
    final sdk = ctrBuildSdk();
    final project = _project();
    await _compile(sdk, ['-o', project.output, project.entry]);
    expect(_stages(project.output), contains('snapshot'));
    expect(sdk.calls('kernel').single, contains('--aot'));
    expect(_json(p.join(project.output, 'artifact.json'))['mode'], 'aot');
  });

  test('without a pubspec skips packages and names the entry', () async {
    final sdk = ctrBuildSdk();
    final project = _project();
    await _compile(sdk, ['-o', project.output, project.entry]);
    expect(_stages(project.output), isNot(contains('packages')));
    expect(sdk.calls('dart'), isEmpty);
    expect(_json(p.join(project.output, 'run.json'))['fixture'], 'main');
  });

  test('the application carries the project title in its SMDH', () async {
    final sdk = ctrBuildSdk();
    final project = _project(pubspec: 'name: snake\ndescription: Eat.\n');
    await _compile(sdk, ['-o', project.output, project.entry]);
    final bytes = File(
      p.join(project.output, 'application.3dsx'),
    ).readAsBytesSync();
    final header = ByteData.sublistView(bytes);
    expect(header.getUint16(4, Endian.little), 44);
    final offset = header.getUint32(32, Endian.little);
    expect(utf8.decode(bytes.sublist(offset, offset + 4)), 'SMDH');
    // English short title.
    final title = offset + 8 + 0x200;
    expect(bytes.sublist(title, title + 12), [
      for (final unit in 'snake\x00'.codeUnits) ...[unit, 0],
    ]);
  });

  test('a missing icon fails before any stage runs', () async {
    final sdk = ctrBuildSdk();
    final project = _project(
      pubspec: 'name: snake\ndartbrew:\n  icon: icon.png\n',
    );
    final runner = CommandRunner<int>('dartbrew', '')
      ..addCommand(CompileCommand(start: startBuildStub));
    await expectLater(
      runner.run([
        'compile',
        '--sdk',
        sdk.root.path,
        '-o',
        project.output,
        project.entry,
      ]),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.path,
          'path',
          endsWith('icon.png'),
        ),
      ),
    );
    expect(sdk.calls('dart'), isEmpty);
    expect(
      File(p.join(project.output, 'application.3dsx')).existsSync(),
      isFalse,
    );
  });

  test('--offline is passed to pub get', () async {
    final sdk = ctrBuildSdk();
    final project = _project(pubspec: 'name: hello_app\n');
    await _compile(sdk, ['--offline', '-o', project.output, project.entry]);
    expect(sdk.calls('dart'), [
      ['pub', 'get', '--offline'],
    ]);
    expect(
      sdk.calls('kernel').single,
      contains(
        '--packages=${p.join(project.root, '.dart_tool/package_config.json')}',
      ),
    );

    final online = _project(pubspec: 'name: hello_app\n');
    await _compile(sdk, ['-o', online.output, online.entry]);
    expect(sdk.calls('dart').last, ['pub', 'get']);
  });

  test('the hidden --fixture option sets the identity token', () async {
    final sdk = ctrBuildSdk();
    final project = _project(pubspec: 'name: hello_app\n');
    await _compile(sdk, [
      '--fixture',
      'hello',
      '-o',
      project.output,
      project.entry,
    ]);
    expect(_json(p.join(project.output, 'run.json'))['fixture'], 'hello');
    final runner = CommandRunner<int>('dartbrew', '')
      ..addCommand(CompileCommand(start: startBuildStub));
    expect(runner.commands['compile']!.usage, isNot(contains('--fixture')));
  });

  test('an existing output fails and stays untouched', () async {
    final sdk = ctrBuildSdk();
    final project = _project();
    final owned = File(p.join(project.output, 'owner'))
      ..createSync(recursive: true)
      ..writeAsStringSync('keep');
    final runner = CommandRunner<int>('dartbrew', '')
      ..addCommand(CompileCommand(start: startBuildStub));
    await expectLater(
      runner.run([
        'compile',
        '--sdk',
        sdk.root.path,
        '-o',
        project.output,
        project.entry,
      ]),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('Output already exists'),
        ),
      ),
    );
    expect(Directory(project.output).listSync().map((f) => f.path), [
      owned.path,
    ]);
    expect(owned.readAsStringSync(), 'keep');
    expect(sdk.calls('kernel'), isEmpty);
  });

  test('an entry outside the project is a usage error', () async {
    final sdk = ctrBuildSdk();
    final project = _project();
    final other = Directory(p.join(project.owner.path, 'other'))..createSync();
    final runner = CommandRunner<int>('dartbrew', '')
      ..addCommand(CompileCommand(start: startBuildStub));
    await expectLater(
      runner.run([
        'compile',
        '--sdk',
        sdk.root.path,
        '--project-directory',
        other.path,
        '-o',
        project.output,
        project.entry,
      ]),
      throwsA(isA<UsageException>()),
    );
    expect(Directory(project.output).existsSync(), isFalse);
  });

  test('compile requires an entrypoint and an output', () async {
    final runner = CommandRunner<int>('dartbrew', '')
      ..addCommand(CompileCommand());
    await expectLater(
      runner.run(['compile', 'main.dart']),
      throwsA(isA<UsageException>()),
    );
    await expectLater(
      runner.run(['compile', '-o', 'out']),
      throwsA(isA<UsageException>()),
    );
  });

  group('fixtureFor', () {
    test('uses the pubspec name', () {
      final project = _project(pubspec: "name: 'quoted_name' # comment\n");
      expect(fixtureFor(project.root, project.entry), 'quoted_name');
    });

    test('falls back to the entry name, reduced to the token rule', () {
      final project = _project();
      expect(
        fixtureFor(project.root, p.join(project.root, 'my app.v2.dart')),
        'my_app_v2',
      );
      final long = 'a' * 80;
      expect(fixtureFor(project.root, '$long.dart'), 'a' * 64);
    });
  });
}
