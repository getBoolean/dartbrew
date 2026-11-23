import 'dart:async';
import 'dart:io';

import 'package:dartbrew/src/cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late NativeCache cache;
  setUp(() {
    root = Directory.systemTemp.createTempSync('dartbrew-cache-test-');
    cache = NativeCache(root);
    addTearDown(() => root.deleteSync(recursive: true));
  });

  test('only publishes a completed build and reuses it', () async {
    final entry = await cache.getOrBuild('a', (work) async {
      File(p.join(work.path, 'runtime.a')).writeAsStringSync('complete');
    });
    expect(
      File(p.join(entry.path, 'runtime.a')).readAsStringSync(),
      'complete',
    );
    final reused = await cache.getOrBuild('a', (_) async => fail('rebuilt'));
    expect(reused.path, entry.path);
  });

  test('failure after writing leaves no reusable entry or scratch', () async {
    await expectLater(
      cache.getOrBuild('a', (work) async {
        File(p.join(work.path, 'half')).writeAsStringSync('');
        throw const FileSystemException('interrupted');
      }),
      throwsA(isA<FileSystemException>()),
    );
    expect(root.listSync(), isEmpty);
  });

  test(
    'concurrent cache misses return one complete published directory',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      final first = cache.getOrBuild('a', (work) async {
        File(p.join(work.path, 'artifact')).writeAsStringSync('one');
        entered.complete();
        await finish.future;
      });
      await entered.future;
      final second = await cache.getOrBuild('a', (work) async {
        File(p.join(work.path, 'artifact')).writeAsStringSync('two');
      });
      finish.complete();
      expect((await first).path, second.path);
      expect(File(p.join(second.path, 'artifact')).readAsStringSync(), 'two');
      expect(root.listSync(), hasLength(1));
    },
  );
}
