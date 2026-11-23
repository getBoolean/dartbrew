import 'dart:async';
import 'dart:convert';
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
    expect(root.listSync().map((f) => p.basename(f.path)), ['.locks']);
  });

  test(
    'only one builder runs for concurrent misses in the same isolate',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      final first = cache.getOrBuild('a', (work) async {
        File(p.join(work.path, 'artifact')).writeAsStringSync('one');
        entered.complete();
        await finish.future;
      });
      await entered.future;
      final second = cache.getOrBuild(
        'a',
        (_) async => fail('duplicate builder'),
      );
      finish.complete();
      final winner = await first;
      expect((await second).path, winner.path);
      expect(File(p.join(winner.path, 'artifact')).readAsStringSync(), 'one');
    },
  );

  test(
    'an interrupted waiter neither runs nor cancels the active builder',
    () async {
      final started = Completer<void>(), finish = Completer<void>();
      final first = cache.getOrBuild('a', (dir) async {
        started.complete();
        await finish.future;
        File(p.join(dir.path, 'artifact')).writeAsStringSync('complete');
      });
      await started.future;
      var interrupted = false;
      final waiting = cache.getOrBuild(
        'a',
        (_) async => fail('duplicate build'),
        checkCancelled: () {
          if (interrupted) throw StateError('interrupted');
        },
      );
      interrupted = true;
      try {
        await expectLater(waiting, throwsStateError);
      } finally {
        finish.complete();
      }
      expect(
        File(p.join((await first).path, 'artifact')).readAsStringSync(),
        'complete',
      );
    },
  );

  Future<({Process process, StreamIterator<String> output})> worker(
    String label, {
    bool hold = false,
  }) async {
    final proc = await Process.start(Platform.resolvedExecutable, [
      File('test/support/cache_worker.dart').absolute.path,
      root.path,
      label,
      if (hold) 'hold',
    ]);
    final errors = proc.stderr.transform(utf8.decoder).join();
    final output = StreamIterator(
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(() async {
      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode;
      await output.cancel();
      final message = await errors;
      if (message.isNotEmpty) fail(message);
    });
    return (process: proc, output: output);
  }

  Future<void> next(StreamIterator<String> output, String expected) async {
    expect(
      await output.moveNext().timeout(const Duration(seconds: 20)),
      isTrue,
    );
    expect(output.current, expected);
  }

  for (final crash in [false, true]) {
    test(
      crash
          ? 'waiter recovers after another process dies mid-build'
          : 'two processes on the same miss compile once',
      () async {
        final first = await worker('owner', hold: true);
        await next(first.output, 'building');
        final second = await worker('waiter');
        await next(second.output, 'contended');
        if (crash) {
          first.process.kill(ProcessSignal.sigkill);
          await first.process.exitCode;
          await next(second.output, 'building');
          await next(second.output, 'read:waiter');
        } else {
          first.process.stdin.writeln('finish');
          await first.process.stdin.flush();
          await next(first.output, 'read:owner');
          await next(second.output, 'read:owner');
        }
        expect(await second.process.exitCode, 0);
        expect(
          root.listSync().map((f) => p.basename(f.path)),
          unorderedEquals(['.locks', 'sample']),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
