import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/notices.dart';
import 'package:test/test.dart';

void main() {
  test(
    'indexes pinned Dart and every transitive production dependency once',
    () async {
      final root = await Directory.systemTemp.createTemp('notices-');
      addTearDown(() => root.delete(recursive: true));
      final sdk = Directory(p.join(root.path, 'sdk'))..createSync();
      final licenses = Directory(p.join(root.path, 'release', 'licenses'))
        ..createSync(recursive: true);
      for (final name in ['args', 'path']) {
        File(
          p.join(licenses.path, '$name.LICENSE'),
        ).writeAsStringSync('License for $name');
      }
      File(p.join(root.path, 'LICENSE')).writeAsStringSync('MPL');
      File(p.join(sdk.path, 'host-dart', 'LICENSE'))
        ..createSync(recursive: true)
        ..writeAsStringSync('Host Dart license');
      await writeNotices(
        repository: root,
        sdk: sdk,
        pins: {
          'dart': {'version': '1.2', 'revision': 'abcd'},
        },
        pubGraph: {
          'root': 'dartbrew',
          'packages': [
            {
              'name': 'dartbrew',
              'version': '1.1',
              'directDependencies': ['args', 'path'],
            },
            {
              'name': 'args',
              'version': '1.0',
              'dependencies': ['path'],
            },
            {'name': 'path', 'version': '2.0', 'dependencies': <String>[]},
            {'name': 'dev', 'version': '3.0', 'dependencies': <String>[]},
          ],
        },
        sourceNotices: ['source-notices/zlib.LICENSE'],
      );
      final text = await File(
        p.join(sdk.path, 'notices/README.md'),
      ).readAsString();
      expect(text, contains('Dart SDK 1.2 (upstream abcd)'));
      expect(RegExp(r'- path 2.0').allMatches(text), hasLength(1));
      expect(text, isNot(contains('dev 3.0')));
      expect(text, contains('source-notices/zlib.LICENSE'));
      expect(
        await File(p.join(sdk.path, 'notices/args.LICENSE')).readAsString(),
        'License for args',
      );
    },
  );
}
