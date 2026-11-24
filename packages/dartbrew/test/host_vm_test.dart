// Opt-in integration with the real host VM driver from
// `make -C runtime/ctr host-vm`; it never represents execution on CTR.
//
// CTR_HOST_VM names the driver, CTR_TEST_SDK the patched SDK checkout and
// CTR_TEST_PLATFORM its CTR VM platform dill. CTR_TEST_BASE_PLATFORM, the
// same-source ordinary VM platform, enables the missing-hooks case, and
// CTR_TEST_TMP chooses where programs are compiled.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartbrew/src/device/run_identity.dart';
import 'package:dartbrew/src/device/stream.dart';
import 'package:dartbrew/src/device/verdict.dart';
import 'package:dartbrew/src/targets/ctr/pipeline.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _environment = Platform.environment;

/// How long the driver may take to deliver the periodic callback and to exit.
const _driverDeadline = Duration(seconds: 20);
const _compileTimeout = Duration(minutes: 3);

/// The marker the uncancelled periodic program prints before it is stopped.
const _periodicRecord = '"text":"periodic"';

/// Compiles [body] for the host VM, runs it under the driver and returns the
/// verdict of its journal with the driver's exit code.
///
/// With [stop], the driver is asked to stop once the program's periodic
/// callback has reached stdout.
Future<({Verdict verdict, int exitCode})> runProgram(
  String body, {
  bool stop = false,
  String? platform,
  String? vmFlag,
}) async {
  final sdk = _environment['CTR_TEST_SDK']!;
  final directory = await Directory(
    _environment['CTR_TEST_TMP'] ?? Directory.systemTemp.path,
  ).createTemp('ctr-async-');
  addTearDown(() => directory.delete(recursive: true));
  final source = File(p.join(directory.path, 'application.dart'))
    ..writeAsStringSync("import 'dart:async';\n$body");
  final kernel = p.join(directory.path, 'application.dill');
  final compile =
      await Process.run(p.join(sdk, 'tools/sdks/dart-sdk/bin/dart'), [
        p.join(sdk, 'pkg/vm/bin/gen_kernel.dart'),
        '--platform=${platform ?? _environment['CTR_TEST_PLATFORM']!}',
        '--output=$kernel',
        source.path,
      ]).timeout(_compileTimeout);
  expect(compile.exitCode, 0, reason: '${compile.stdout}${compile.stderr}');

  final identity = RunIdentity(
    schema: 1,
    runId: newRunId(),
    fixture: 'async',
    mode: BuildMode.jit,
    compatibility: 'a' * 64,
    artifactSha256: 'a' * 64,
    buildId: 'a' * 64,
    environment: RunEnvironment.host,
  );
  final config = File(p.join(directory.path, 'run.cfg'))
    ..writeAsStringSync(identity.runConfig());
  final journal = File(p.join(directory.path, 'journal.log'));

  final process = await Process.start(
    _environment['CTR_HOST_VM']!,
    [kernel, config.path, journal.path, if (stop) 'stop-on-input'],
    environment: {'CTR_TEST_VM_FLAG': ?vmFlag},
  );
  final stdoutText = StringBuffer();
  final stderrText = StringBuffer();
  final periodicSeen = Completer<void>();
  final stdoutDone = process.stdout.transform(utf8.decoder).forEach((text) {
    stdoutText.write(text);
    if (!periodicSeen.isCompleted &&
        stdoutText.toString().contains(_periodicRecord)) {
      periodicSeen.complete();
    }
  });
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .forEach(stderrText.write);
  try {
    if (stop) {
      await Future.any([
        periodicSeen.future,
        process.exitCode.then(
          (_) => fail('VM exited before periodic callback: $stderrText'),
        ),
      ]).timeout(
        _driverDeadline,
        onTimeout: () => fail(
          'VM did not deliver a periodic callback before the hang deadline',
        ),
      );
      process.stdin.writeln();
      await process.stdin.flush();
    }
    final exitCode = await process.exitCode.timeout(_driverDeadline);
    await (stdoutDone, stderrDone).wait;
    expect(exitCode, isIn([0, 1, 2]), reason: '$stdoutText$stderrText');
    final verdict = _verdictOf(identity, journal.readAsBytesSync());
    expect(verdict.reason, isNull);
    return (verdict: verdict, exitCode: exitCode);
  } finally {
    process.kill();
    await process.stdin.close();
  }
}

Verdict _verdictOf(RunIdentity identity, List<int> journal) {
  final parser = RuntimeLineParser();
  final accumulator = VerdictAccumulator(identity);
  [...parser.feed(journal), ...parser.close()].forEach(accumulator.add);
  return accumulator.finish();
}

void main() {
  group(
    'host VM',
    skip: _environment['CTR_HOST_VM'] == null
        ? 'set CTR_HOST_VM, CTR_TEST_SDK and CTR_TEST_PLATFORM for real VM '
              'checks'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
    () {
      test(
        'runs microtasks, zero timers and delayed timers in order',
        () async {
          final run = await runProgram(r'''
void main(List<String> args) {
  if (args.isNotEmpty) throw StateError('unexpected arguments');
  print('main');
  scheduleMicrotask(() => print('microtask'));
  Timer(Duration.zero, () => print('zero-first'));
  Timer(Duration.zero, () => print('zero-second'));
  final cancelled = Timer(const Duration(days: 1), () => throw StateError('cancelled'));
  Timer(const Duration(milliseconds: 1), () { cancelled.cancel(); print('delayed'); });
}
''');
          expect(run.exitCode, 0);
          expect(run.verdict.output, [
            'main',
            'microtask',
            'zero-first',
            'zero-second',
            'delayed',
          ]);
        },
      );

      test(
        'cancelling the last periodic timer lets the program exit',
        () async {
          final run = await runProgram(r'''
void main() {
  Timer.periodic(const Duration(milliseconds: 1), (timer) {
    print('tick'); timer.cancel();
  });
}
''');
          expect(run.exitCode, 0);
          expect(run.verdict.output, ['tick']);
        },
      );

      test('an uncancelled periodic timer runs until stopped', () async {
        final run = await runProgram(r'''
void main() {
  var first = true;
  Timer.periodic(const Duration(milliseconds: 1), (timer) {
    if (first) { first = false; print('periodic'); }
  });
}
''', stop: true);
        expect(run.exitCode, 2);
        expect(run.verdict.outcome, Outcome.incomplete);
        expect(run.verdict.output, ['periodic']);
      });

      test('an asynchronous error fails with its stack', () async {
        final run = await runProgram(r'''
void main() {
  Timer.run(() => throw StateError('async failure'));
}
''');
        expect(run.exitCode, 1);
        expect(run.verdict.outcome, Outcome.fail);
        final output = run.verdict.output.join('\n');
        expect(output, contains('async failure'));
        expect(output, contains('application.dart'));
      });

      for (final flag in [null, '--link_natives_lazily']) {
        test('dart:io reads its own file with VM flag $flag', () async {
          final run = await runProgram(r'''
import 'dart:io';
void main() {
  final dir = Directory.systemTemp.createTempSync();
  try {
    final file = File('${dir.path}/probe')..writeAsStringSync('io-ready');
    print(file.readAsStringSync());
  } finally {
    dir.deleteSync(recursive: true);
  }
}
''', vmFlag: flag);
          expect(run.exitCode, 0);
          expect(run.verdict.outcome, Outcome.pass);
          expect(run.verdict.output, ['io-ready']);
        });
      }

      // The SDK's ordinary VM platform has no private CTR library.
      test(
        'missing private hooks fail and clean up the partial bootstrap',
        skip: _environment['CTR_TEST_BASE_PLATFORM'] == null
            ? 'set CTR_TEST_BASE_PLATFORM to the same-source ordinary VM '
                  'platform'
            : false,
        () async {
          final run = await runProgram(
            'void main() {}',
            platform: _environment['CTR_TEST_BASE_PLATFORM'],
          );
          expect(run.exitCode, 1);
          expect(run.verdict.outcome, Outcome.fail);
          expect(run.verdict.output.join('\n'), contains('dart:_ctr'));
        },
      );
    },
  );
}
