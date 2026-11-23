import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/runtime_build.dart';
import 'package:test/test.dart';

void main() {
  test(
    'refuses an existing destination before querying producer inputs',
    () async {
      final existing = Directory.systemTemp.createTempSync('existing-runtime-');
      addTearDown(() => existing.deleteSync(recursive: true));
      final sentinel = File(p.join(existing.path, 'owner'))
        ..writeAsStringSync('keep');
      await expectLater(
        buildRuntime(
          repository: existing,
          source: existing,
          buildRoot: existing,
          output: existing,
          genSnapshot: File(p.join(existing.path, 'no-snapshot')),
        ),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('already exists'),
          ),
        ),
      );
      expect(existing.listSync().single.path, sentinel.path);
      expect(sentinel.readAsStringSync(), 'keep');
    },
  );
  final runtime = Platform.environment['DARTBREW_RUNTIME_COMPONENT'];
  test(
    'published component contains only sealed native sources and host-independent metadata',
    () async {
      final root = Directory(runtime!);
      final record =
          jsonDecode(File(p.join(root.path, 'runtime.json')).readAsStringSync())
              as Map<String, Object?>;
      final plan =
          jsonDecode(
                File(p.join(root.path, 'compile-plan.json')).readAsStringSync(),
              )
              as Map<String, Object?>;
      final sealed = (record['files']! as Map<String, Object?>)
          .cast<String, String>();
      final actual = <String>{};
      for (final file
          in root
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()) {
        final path = p.split(p.relative(file.path, from: root.path)).join('/');
        expect(path, isNot(matches(RegExp(r'\.(?:o|a|so|elf|3dsx|ld)$'))));
        if (['runtime.json', 'probe.json', 'probe.dill'].contains(path)) {
          continue;
        }
        expect(
          sealed[path],
          (await sha256.bind(file.openRead()).first).toString(),
          reason: path,
        );
        actual.add(path);
      }
      expect(sealed.keys.toSet(), actual);
      final modes = plan['modes']! as Map<String, Object?>;
      expect(modes.keys.toSet(), {'jit', 'aot'});
      final probe =
          jsonDecode(File(p.join(root.path, 'probe.json')).readAsStringSync())
              as Map<String, Object?>;
      final proof = probe['native_build']! as Map<String, Object?>;
      final digest = matches(r'^[a-f0-9]{64}$');
      for (final name in ['aot', 'jit']) {
        final result = proof[name]! as Map<String, Object?>;
        expect(result['barrier_check'], 'pass');
        for (final key in [
          'runtime_archive_sha256',
          'io_archive_sha256',
          'whole_io_link_sha256',
          if (name == 'aot') 'hello_elf_sha256',
        ]) {
          expect(result[key], digest, reason: '$name $key');
        }
      }
      for (final mode in modes.values) {
        final units = (mode! as List<Object?>).cast<Map<String, Object?>>();
        expect(units.map((u) => u['group']).toSet(), {
          'runtime',
          'io',
          'launcher',
          'check',
        });
        for (final unit in units) {
          expect(sealed.keys, contains('native-src/${unit['source']}'));
          final flags = (unit['flags']! as List<Object?>).cast<String>();
          expect(flags, isNot(contains('-Werror')));
          for (final flag in flags.where((f) => f.startsWith('-I'))) {
            expect(flag, matches(r'^-I@(src|devkitpro)@(/|$)'));
          }
        }
      }
    },
    skip: runtime == null
        ? 'Set DARTBREW_RUNTIME_COMPONENT to a directory produced by build_runtime.'
        : false,
  );
}
