import 'dart:convert';

import 'package:dartbrew/src/test_runner/reporter.dart';
import 'package:test/test.dart';

import 'support/test_events.dart';

typedef _Report = ({int code, String out, String err});

_Report _render(
  List<String> lines, {
  bool json = false,
  int suites = 1,
  int runExitCode = 0,
  String? runMessage,
  void Function(TestSession session)? before,
}) {
  final out = StringBuffer();
  final err = StringBuffer();
  final session = TestSession(
    json ? JsonRenderer(out, err, pid: 42) : CompactRenderer(out),
    elapsed: () => Duration.zero,
  )..begin(suites);
  before?.call(session);
  for (final line in lines) {
    session.addOutput(line);
  }
  final code = session.finish(runExitCode: runExitCode, runMessage: runMessage);
  return (code: code, out: out.toString(), err: err.toString());
}

/// Checks [event] against the required fields of the public JSON reporter
/// schema (`pkgs/test/doc/json_reporter.schema.json`).
void _expectProtocolEvent(Map<String, Object?> event) {
  void has(Map<Object?, Object?> map, Map<String, bool Function(Object?)> f) {
    f.forEach((key, valid) {
      expect(map.containsKey(key), isTrue, reason: '$key missing in $map');
      expect(valid(map[key]), isTrue, reason: '$key invalid in $map');
    });
  }

  bool isInt(Object? v) => v is int && v >= 0;
  bool isBool(Object? v) => v is bool;
  bool isString(Object? v) => v is String;
  bool isStringOrNull(Object? v) => v == null || v is String;
  bool isMetadata(Object? v) =>
      v is Map && v['skip'] is bool && isStringOrNull(v['skipReason']);
  bool isLine(Object? v) => v == null || (v is int && v >= 1);
  final entry = <String, bool Function(Object?)>{
    'id': isInt,
    'suiteID': isInt,
    'metadata': isMetadata,
    'line': isLine,
    'column': isLine,
    'url': isStringOrNull,
  };

  has(event, {'type': isString, 'time': isInt});
  switch (event['type']) {
    case 'start':
      has(event, {
        'protocolVersion': (v) => v is String && v.startsWith('0.1.'),
        'runnerVersion': isStringOrNull,
        'pid': isInt,
      });
    case 'allSuites':
      has(event, {'count': isInt});
    case 'suite':
      has(event['suite'] as Map, {
        'id': isInt,
        'platform': isStringOrNull,
        'path': isString,
      });
    case 'group':
      has(event['group'] as Map, {
        ...entry,
        'name': isStringOrNull,
        'testCount': isInt,
      });
    case 'testStart':
      has(event['test'] as Map, {
        ...entry,
        'name': isString,
        'groupIDs': (v) => v is List && v.every(isInt),
      });
    case 'print':
      has(event, {
        'testID': isInt,
        'message': isString,
        'messageType': (v) => v == 'print' || v == 'skip',
      });
    case 'error':
      has(event, {
        'testID': isInt,
        'error': isString,
        'stackTrace': isString,
        'isFailure': isBool,
      });
    case 'testDone':
      has(event, {
        'testID': isInt,
        'result': (v) => const ['success', 'failure', 'error'].contains(v),
        'hidden': isBool,
        'skipped': isBool,
      });
    case 'done':
      has(event, {'success': isBool});
    default:
      fail('Unexpected event type in $event');
  }
}

void main() {
  test('three passing tests end with "All tests passed!" and exit 0', () {
    final r = _render(RecordedStream.passing(3).lines);

    expect(r.code, 0);
    final lines = const LineSplitter().convert(r.out);
    expect(lines, [
      '00:00 +0: test/a_test.dart: test 1',
      '00:00 +1: test/a_test.dart: test 2',
      '00:00 +2: test/a_test.dart: test 3',
      '00:00 +3: All tests passed!',
    ]);
  });

  test('AE3: a socket connect names sockets as unsupported, 1 passed 1 '
      'failed, exit 1', () {
    final r = _render(RecordedStream.unsupportedSocket().lines);

    expect(r.code, 1);
    expect(
      r.out,
      contains(
        '00:00 +1 -1: test/net_test.dart: connects [E]\n'
        '  sockets is not supported on CTR.\n'
        "  SocketException: Failed host lookup: 'example.com'",
      ),
    );
    expect(r.out, endsWith('00:00 +1 -1: Some tests failed.\n'));
  });

  test('assertion failures are never attributed to an area', () {
    final stream = RecordedStream();
    final suite = stream.suite('test/a_test.dart');
    final id = stream.start(suite, 'compares');
    stream
      ..error(
        id,
        'Expected: <8>',
        isFailure: true,
        stackTrace: 'dart:io/file_impl.dart  _File._openSync',
      )
      ..testDone(id, 'failure')
      ..done();
    final r = _render(stream.lines);

    expect(r.out, isNot(contains('not supported')));
    expect(r.code, 1);
  });

  test('a test using spawnHybridUri names the hybrid area', () {
    final stream = RecordedStream();
    final suite = stream.suite('test/hybrid_test.dart');
    final id = stream.start(suite, 'talks to the host');
    stream
      ..error(
        id,
        "Unsupported operation: Can't connect to the test runner.\n"
        'spawnHybridUri() is currently only supported within "dart test".',
        stackTrace:
            'package:test_api/src/scaffolding/spawn_hybrid.dart 109:10  '
            'spawnHybridUri',
      )
      ..testDone(id, 'error')
      ..done();
    final r = _render(stream.lines);

    expect(
      r.out,
      contains(
        'hybrid tests (spawnHybridUri and spawnHybridCode) is not supported '
        'on CTR',
      ),
    );
    expect(r.code, 1);
  });

  test('KTD10 fallback: a stream ending without done during the third of '
      'five tests fails the remaining three with the area from the last '
      'output', () {
    final names = ['one', 'two', 'three', 'four', 'five'];
    final stream = RecordedStream();
    final suite = stream.suite('test/a_test.dart');
    stream
      ..plan(suite, names)
      ..pass(suite, 'one')
      ..pass(suite, 'two')
      ..start(suite, 'three');
    final r = _render([
      ...stream.lines,
      "Failed to resolve native function 'Socket_CreateConnect'",
    ], runMessage: 'lost connection');

    expect(r.code, 1);
    expect(r.out, contains('test/a_test.dart: three [E]'));
    expect(r.out, contains('test/a_test.dart: four [E]'));
    expect(r.out, contains('test/a_test.dart: five [E]'));
    expect(
      r.out,
      contains(
        'test/a_test.dart: three [E]\n'
        '  sockets is not supported on CTR. The test program stopped after:',
      ),
    );
    expect(
      r.out,
      contains(
        'test/a_test.dart: four [E]\n'
        '  Did not run: the test program stopped during "three": lost '
        'connection',
      ),
    );
    expect(r.out, endsWith('+2 -3: Some tests failed.\n'));
  });

  test('a stopped run with no attributable output fails the remaining tests '
      'with the run\'s reason', () {
    final stream = RecordedStream();
    final suite = stream.suite('test/a_test.dart');
    stream
      ..plan(suite, ['one', 'two'])
      ..start(suite, 'one');
    final r = _render(stream.lines, runMessage: 'lost connection');

    expect(r.code, 1);
    expect(r.out, isNot(contains('not supported')));
    expect(
      r.out,
      contains('The test program stopped before this test finished: lost '),
    );
    expect(r.out, endsWith('+0 -2: Some tests failed.\n'));
  });

  test('a run that fails after done still fails', () {
    final r = _render(
      RecordedStream.passing(1).lines,
      runExitCode: 255,
      runMessage: 'uncaught error',
    );
    expect(r.code, 1);
    expect(r.out, contains('failed after its tests finished: uncaught error'));
  });

  test('--reporter json follows the public protocol with host-added start, '
      'allSuites and done, and drops dartbrew.plan', () {
    final lines = RecordedStream.unsupportedSocket().lines;
    final r = _render([...lines, 'a print outside any test'], json: true);

    expect(r.code, 1);
    final events = [
      for (final line in const LineSplitter().convert(r.out))
        jsonDecode(line) as Map<String, Object?>,
    ];
    events.forEach(_expectProtocolEvent);
    expect(events.first, {
      'type': 'start',
      'protocolVersion': '0.1.1',
      'runnerVersion': null,
      'pid': 42,
      'time': 0,
    });
    expect(events[1], {'type': 'allSuites', 'count': 1, 'time': 0});
    expect(events.last, {'type': 'done', 'success': false, 'time': 0});
    expect(events.map((e) => e['type']), isNot(contains('dartbrew.plan')));
    expect(
      events.where((e) => e['type'] == 'error').single['error'],
      startsWith('sockets is not supported on CTR.\n'),
    );
    expect(r.err, 'a print outside any test\n');
  });

  test('host load errors are reported like dart test and keep IDs unique', () {
    final out = StringBuffer();
    final session = TestSession(
      JsonRenderer(out, StringBuffer(), pid: 1),
      elapsed: () => Duration.zero,
    )..begin(2);
    session.loadError('test/bad_test.dart', "bad_test.dart:1:5: Error: ';'");
    expect(session.nextId, 2);
    session
      ..addOutput(
        // A device stream generated with firstId: 2.
        (RecordedStream(firstId: 2)..suite('test/a_test.dart')).lines.single,
      )
      ..finish();
    final events = [
      for (final line in const LineSplitter().convert(out.toString()))
        jsonDecode(line) as Map<String, Object?>,
    ];
    events.forEach(_expectProtocolEvent);
    final error = events.firstWhere((e) => e['type'] == 'error');
    expect(error['error'], startsWith('Failed to load "test/bad_test.dart":'));
    final compact = _render(
      [],
      before: (s) => s.loadError('test/bad_test.dart', 'Error: oops'),
    );
    expect(compact.out, contains('+0 -1: loading test/bad_test.dart [E]'));
  });

  test('no tests ran exits 79', () {
    final stream = RecordedStream();
    stream
      ..plan(stream.suite('test/a_test.dart'), [])
      ..done();
    final r = _render(stream.lines);
    expect(r.code, noTestsRanExitCode);
    expect(r.out, endsWith('No tests ran.\n'));
  });

  group('a stopped session', () {
    TestSession stopped(TestRenderer renderer) {
      final stream = RecordedStream();
      final suite = stream.suite('test/a_test.dart');
      stream.start(suite, 'one');
      return TestSession(renderer, elapsed: () => Duration.zero)
        ..begin(1)
        ..addOutput(stream.lines.join('\n'))
        ..stop();
    }

    test('ends the JSON report with an unsuccessful done event', () {
      final out = StringBuffer();
      stopped(JsonRenderer(out, StringBuffer(), pid: 42));
      final events = [
        for (final line in const LineSplitter().convert('$out'))
          jsonDecode(line) as Map<String, Object?>,
      ];
      events.forEach(_expectProtocolEvent);
      expect(events.last, {'type': 'done', 'success': false, 'time': 0});
    });

    test('adds nothing to the compact report', () {
      final out = StringBuffer();
      stopped(CompactRenderer(out));
      expect('$out', '00:00 +0: test/a_test.dart: one\n');
    });

    test('reports nothing more, and finishing it fails', () {
      final out = StringBuffer();
      final session = stopped(JsonRenderer(out, StringBuffer(), pid: 42));
      final reported = '$out';
      session
        ..addOutput('more output')
        ..stop();
      expect(session.finish(), 1);
      expect('$out', reported);
    });
  });

  test('prints and plain output appear in the compact report', () {
    final stream = RecordedStream();
    final suite = stream.suite('test/a_test.dart');
    final id = stream.start(suite, 'talks');
    stream
      ..printed(id, 'hello from the test')
      ..testDone(id, 'success')
      ..done();
    final r = _render(['boot noise', ...stream.lines]);
    expect(r.out, startsWith('boot noise\n'));
    expect(r.out, contains('hello from the test\n'));
    expect(r.code, 0);
  });
}
