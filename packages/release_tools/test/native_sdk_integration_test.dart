import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/release_check.dart';
import 'package:test/test.dart';

void main() {
  final sdk = Platform.environment['DARTBREW_NATIVE_SDK'];
  group(
    'extracted native SDK',
    () {
      late Directory project;
      late File cli, entry;
      Future<ProcessResult> run(
        List<String> args, {
        Map<String, String> env = const {},
      }) => Process.run(
        cli.path,
        args,
        workingDirectory: project.path,
        environment: {'PATH': '', ...env},
      );
      setUp(() async {
        project = await Directory.systemTemp.createTemp('dartbrew SDK ');
        addTearDown(() => project.delete(recursive: true));
        cli = File(p.join(sdk!, 'dartbrew${Platform.isWindows ? '.exe' : ''}'));
        entry = await File(
          p.join(await repositoryRoot(), 'test/programs/hello.dart'),
        ).copy(p.join(project.path, 'main.dart'));
      });
      test(
        'manifest seals the entire extraction and notices travel with an application',
        () async {
          final root = Directory(sdk!);
          final index =
              jsonDecode(
                    await File(p.join(root.path, 'sdk.json')).readAsString(),
                  )
                  as Map<String, Object?>;
          final files = (index['files']! as Map<String, Object?>).keys.toSet();
          final extracted = <String>{};
          await for (final file in root.list(
            recursive: true,
            followLinks: false,
          )) {
            if (file is File) {
              extracted.add(
                p.split(p.relative(file.path, from: root.path)).join('/'),
              );
            }
          }
          expect(extracted, {...files, 'sdk.json'});
          final notices = Directory(p.join(root.path, 'notices'));
          final readme = await File(
            p.join(notices.path, 'README.md'),
          ).readAsString();
          for (final link in RegExp(r'\]\(([^)]+)\)').allMatches(readme)) {
            final file = File(p.normalize(p.join(notices.path, link[1]!)));
            expect(
              p.isWithin(notices.path, file.path) && await file.exists(),
              isTrue,
              reason: file.path,
            );
          }
        },
      );
      test(
        'builds AOT and JIT in a path with spaces and stages matching identities',
        () async {
          final hashes = <String>{};
          for (final mode in ['aot', 'jit']) {
            final result = await run([
              'compile',
              entry.path,
              '--mode',
              mode,
              '-o',
              mode,
            ]);
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
            final root = p.join(project.path, mode);
            final bin = File(p.join(root, 'application.3dsx'));
            expect((await bin.openRead(0, 4).single), ascii.encode('3DSX'));
            final artifact =
                jsonDecode(
                      await File(p.join(root, 'artifact.json')).readAsString(),
                    )
                    as Map<String, Object?>;
            final identity =
                jsonDecode(await File(p.join(root, 'run.json')).readAsString())
                    as Map<String, Object?>;
            final digest = (await sha256.bind(bin.openRead()).single)
                .toString();
            expect(artifact, containsPair('artifact_sha256', digest));
            expect(identity, containsPair('artifact_sha256', digest));
            expect(identity['build_id'], artifact['build_id']);
            expect(
              await File(
                p.join(root, 'SDROOT', 'ctr-runtime-run.cfg'),
              ).readAsString(),
              contains('run_id=${identity['run_id']}'),
            );
            hashes.add(digest);
          }
          expect(hashes, hasLength(2));
        },
        timeout: Timeout(Duration(minutes: 40)),
      );
      test(
        'reports an invalid explicitly selected devkitPro install',
        () async {
          final missing = p.join(project.path, 'missing-devkitpro');
          final result = await run(
            ['doctor'],
            env: {
              'DEVKITPRO': missing,
              'DEVKITARM': p.join(missing, 'devkitARM'),
            },
          );
          expect(result.exitCode, isNot(0));
          expect(result.stderr.toString().toLowerCase(), contains('devkitpro'));
        },
      );
      test('retains kernel diagnostics for an invalid program', () async {
        await entry.writeAsString('void main( { syntax error');
        final result = await run(['compile', entry.path, '-o', 'invalid']);
        expect(result.exitCode, isNot(0));
        expect(
          File(
            p.join(project.path, 'invalid', 'application.3dsx'),
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            p.join(project.path, 'invalid', 'work', 'kernel.log'),
          ).existsSync(),
          isTrue,
        );
      });
      test('runs pub with the bundled Dart and retains pub errors', () async {
        final pub = File(p.join(project.path, 'pubspec.yaml'));
        await pub.writeAsString(
          "name: invalid_sdk\nenvironment:\n  sdk: '>=99.0.0 <100.0.0'\n",
        );
        final result = await run([
          'compile',
          entry.path,
          '--offline',
          '-o',
          'invalid',
        ]);
        expect(result.exitCode, isNot(0));
        expect(
          await File(
            p.join(project.path, 'invalid', 'work', 'packages.log'),
          ).readAsString(),
          contains('version solving failed'),
        );
      });
      test('resolves a local path dependency offline', () async {
        await File(p.join(project.path, 'pubspec.yaml')).writeAsString(
          "name: local_app\nenvironment:\n  sdk: '>=3.11.0 <4.0.0'\ndependencies:\n  local_dep:\n    path: dep\n",
        );
        final dep = Directory(p.join(project.path, 'dep', 'lib'))
          ..createSync(recursive: true);
        await File(p.join(dep.parent.path, 'pubspec.yaml')).writeAsString(
          "name: local_dep\nenvironment:\n  sdk: '>=3.11.0 <4.0.0'\n",
        );
        await File(
          p.join(dep.path, 'value.dart'),
        ).writeAsString('const value=42;');
        await entry.writeAsString(
          "import 'package:local_dep/value.dart';void main()=>print(value);",
        );
        final result = await run([
          'compile',
          entry.path,
          '--offline',
          '-o',
          'local',
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final commands =
            jsonDecode(
                  await File(
                    p.join(project.path, 'local/work/commands.json'),
                  ).readAsString(),
                )
                as List<Object?>;
        final pub = commands.cast<Map<String, Object?>>().singleWhere(
          (stage) => stage['stage'] == 'packages',
        );
        expect(
          p.equals(
            pub['executable']! as String,
            p.join(
              sdk!,
              'host-dart/bin/dart${Platform.isWindows ? '.exe' : ''}',
            ),
          ),
          isTrue,
        );
      }, timeout: Timeout(Duration(minutes: 20)));
      test(
        'preserves an existing output and reserves a shared output once',
        () async {
          final out = Directory(p.join(project.path, 'owned'))..createSync();
          final marker = File(p.join(out.path, 'owner'))
            ..writeAsStringSync('keep');
          expect(
            (await run(['compile', entry.path, '-o', out.path])).exitCode,
            isNot(0),
          );
          expect(out.listSync().map((file) => file.path), [marker.path]);
          final builds = await Future.wait([
            for (var i = 0; i < 2; i++)
              run(['compile', entry.path, '--mode', 'jit', '-o', 'shared']),
          ]);
          expect(builds.where((result) => result.exitCode == 0), hasLength(1));
          expect(
            File(
              p.join(project.path, 'shared', 'application.3dsx'),
            ).existsSync(),
            isTrue,
          );
        },
        timeout: Timeout(Duration(minutes: 20)),
      );
    },
    skip: sdk == null
        ? 'Set DARTBREW_NATIVE_SDK to an extracted release SDK'
        : false,
  );
}
