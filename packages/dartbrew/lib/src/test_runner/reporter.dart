import 'dart:convert';
import 'dart:math' as math;

import 'classify.dart';
import 'events.dart';

/// The JSON reporter protocol version the `--reporter json` output follows.
const jsonProtocolVersion = '0.1.1';

/// `dart test`'s exit code when no tests ran.
const noTestsRanExitCode = 79;

/// What the session knows about one test.
final class TestRecord {
  final int id;
  final String name;
  final int suiteId;
  bool done = false;
  bool hidden = false;
  bool skipped = false;
  String? result;

  /// Errors that arrived before the test finished, kept until it does so a
  /// compact report can print them with the final counts.
  final pendingErrors = <Map<String, Object?>>[];

  TestRecord(this.id, this.name, this.suiteId);
}

/// Renders a [TestSession] for the user.
abstract interface class TestRenderer {
  /// Called once before any event; [suiteCount] is the number of selected
  /// test files.
  void start(TestSession session, int suiteCount);

  /// A test event in the public JSON reporter protocol, already classified.
  void event(TestSession session, Map<String, Object?> event);

  /// Program output that is not a test event.
  void output(String text);

  /// A message from dartbrew itself, such as why a run stopped.
  void note(String text);

  /// Called once at the end, with the run's overall result.
  void done(TestSession session, int exitCode);

  /// Called once instead of [done] when the run ended without a result,
  /// such as when the app could not be sent, the build failed or the user
  /// interrupted the run.
  void stopped(TestSession session);
}

/// Collects the events of one `dartbrew test` run, classifies unsupported
/// API errors (KTD10), fills in tests a stopped run never finished, and
/// computes the exit code.
final class TestSession {
  final TestRenderer renderer;

  /// The time since the run started, used for event `time` fields and the
  /// compact report's clock.
  final Duration Function() elapsed;

  final suites = <int, String>{};
  final tests = <int, TestRecord>{};
  final _plans = <int, List<String>>{};
  var _nextId = 0;
  var _deviceDone = false;
  var _stoppedEarly = false;
  var _ended = false;
  String? _lastText;

  int passed = 0;
  int skipped = 0;
  int failed = 0;

  TestSession(this.renderer, {Duration Function()? elapsed})
    : elapsed = elapsed ?? _startClock();

  static Duration Function() _startClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  /// The first event ID not used yet; a generated entrypoint built after
  /// [loadError] calls starts numbering here.
  int get nextId => _nextId;

  /// Whether the device reported the end of its test run.
  bool get deviceDone => _deviceDone;

  void begin(int suiteCount) => renderer.start(this, suiteCount);

  /// Reports that the file at [path] failed to load with [message], the way
  /// `dart test` reports a load error.
  void loadError(String path, String message) {
    final suiteId = _nextId++;
    final testId = _nextId++;
    for (final event in <Map<String, Object?>>[
      {
        'type': 'suite',
        'suite': {'id': suiteId, 'platform': 'vm', 'path': path},
      },
      {
        'type': 'testStart',
        'test': _testFields(testId, 'loading $path', suiteId),
      },
      _errorEvent(testId, 'Failed to load "$path":\n$message'),
      _testDone(testId),
    ]) {
      _handle(event, classify: false);
    }
  }

  /// Consumes the text of one output record from the test program. Output
  /// that arrives after the session has ended is dropped.
  void addOutput(String text) {
    if (_ended) return;
    for (final item in parseTestOutput(text)) {
      switch (item) {
        case TestEvent(:final fields):
          _handle(fields);
        case TestText(:final text):
          _lastText = text;
          renderer.output(text);
      }
    }
  }

  /// Ends the session and returns the exit code: 0 when every test passed,
  /// 1 when any failed or the run stopped early, and [noTestsRanExitCode]
  /// when no tests ran. A session that was already stopped reports nothing
  /// more and returns 1.
  ///
  /// [runExitCode] and [runMessage] describe how the program itself ended.
  /// When the device never reported its end, the tests it did not finish
  /// are failed with the area named by the last output when one is
  /// attributable, and with [runMessage] otherwise.
  int finish({int runExitCode = 0, String? runMessage}) {
    if (_ended) return 1;
    if (!_deviceDone) {
      _failUnfinished(runMessage);
    } else if (runExitCode != 0) {
      _stoppedEarly = true;
      renderer.note(
        'The test program failed after its tests finished'
        '${runMessage == null ? '.' : ': $runMessage'}',
      );
    }
    final ok = failed == 0 && !_stoppedEarly;
    final code = !ok
        ? 1
        : passed + skipped == 0
        ? noTestsRanExitCode
        : 0;
    _ended = true;
    renderer.done(this, code);
    return code;
  }

  /// Ends a session whose run produced no result (see
  /// [TestRenderer.stopped]). Does nothing once the session has ended.
  void stop() {
    if (_ended) return;
    _ended = true;
    renderer.stopped(this);
  }

  void _failUnfinished(String? runMessage) {
    _stoppedEarly = true;
    final last = _lastText;
    final area =
        classifyUnsupported(last ?? '') ??
        (runMessage == null ? null : classifyUnsupported(runMessage));
    final reason = area != null
        ? '${area.message}.'
              '${last == null ? '' : ' The test program stopped after:\n$last'}'
        : 'The test program stopped before this test finished'
              '${runMessage == null ? '.' : ': $runMessage'}';
    final running = [
      for (final test in tests.values)
        if (!test.done) test,
    ];
    if (running.isEmpty && _plans.isEmpty) {
      renderer.note(
        'The test program stopped before reporting results'
        '${runMessage == null ? '.' : ': $runMessage'}',
      );
      return;
    }
    for (final test in running) {
      _handle(_errorEvent(test.id, reason), classify: false);
      _handle(_testDone(test.id), classify: false);
    }
    final stoppedIn = running.isEmpty ? null : running.first.name;
    for (final MapEntry(key: suiteId, value: names) in _plans.entries) {
      final started = <String, int>{};
      for (final test in tests.values) {
        if (test.suiteId == suiteId) {
          started[test.name] = (started[test.name] ?? 0) + 1;
        }
      }
      for (final name in names) {
        final count = started[name] ?? 0;
        if (count > 0) {
          started[name] = count - 1;
          continue;
        }
        final id = _nextId++;
        _handle({
          'type': 'testStart',
          'test': _testFields(id, name, suiteId),
        }, classify: false);
        _handle(
          _errorEvent(
            id,
            'Did not run: the test program stopped'
            '${stoppedIn == null ? '' : ' during "$stoppedIn"'}'
            '${runMessage == null ? '.' : ': $runMessage'}',
          ),
          classify: false,
        );
        _handle(_testDone(id), classify: false);
      }
    }
  }

  void _handle(Map<String, Object?> event, {bool classify = true}) {
    _noteIds(event);
    switch (event['type']) {
      case planEventType:
        final suiteId = event['suiteID'];
        final names = event['tests'];
        if (suiteId is int && names is List) {
          _plans[suiteId] = [for (final name in names) '$name'];
        }
        return;
      case 'done':
        _deviceDone = true;
        return;
      case 'suite':
        final suite = event['suite'];
        if (suite is Map && suite['id'] is int) {
          suites[suite['id'] as int] = '${suite['path']}';
        }
      case 'testStart':
        final test = event['test'];
        if (test is Map && test['id'] is int) {
          final id = test['id'] as int;
          tests[id] = TestRecord(
            id,
            '${test['name']}',
            test['suiteID'] is int ? test['suiteID'] as int : -1,
          );
        }
      case 'print':
        if (event['message'] case final String message) _lastText = message;
      case 'error':
        final error = '${event['error']}';
        _lastText = error;
        if (classify && event['isFailure'] != true) {
          final area = classifyUnsupported('$error\n${event['stackTrace']}');
          if (area != null) event['error'] = '${area.message}.\n$error';
        }
        final test = tests[event['testID']];
        if (test != null && !test.done) test.pendingErrors.add(event);
      case 'testDone':
        final test = tests[event['testID']];
        if (test == null || test.done) break;
        test
          ..done = true
          ..hidden = event['hidden'] == true
          ..skipped = event['skipped'] == true
          ..result = '${event['result']}';
        if (test.result != 'success') {
          failed++;
        } else if (test.skipped) {
          skipped++;
        } else if (!test.hidden) {
          passed++;
        }
    }
    renderer.event(this, event);
  }

  void _noteIds(Map<String, Object?> event) {
    for (final value in [
      (event['suite'] as Map?)?['id'],
      (event['group'] as Map?)?['id'],
      (event['test'] as Map?)?['id'],
      event['testID'],
    ]) {
      if (value is int) _nextId = math.max(_nextId, value + 1);
    }
  }

  static Map<String, Object?> _testFields(int id, String name, int suiteId) => {
    'id': id,
    'name': name,
    'suiteID': suiteId,
    'groupIDs': <int>[],
    'metadata': {'skip': false, 'skipReason': null},
    'line': null,
    'column': null,
    'url': null,
  };

  static Map<String, Object?> _errorEvent(int id, String message) => {
    'type': 'error',
    'testID': id,
    'error': message,
    'stackTrace': '',
    'isFailure': false,
  };

  static Map<String, Object?> _testDone(int id) => {
    'type': 'testDone',
    'testID': id,
    'result': 'error',
    'hidden': false,
    'skipped': false,
  };
}

/// A `dart test`-style compact report for output that is not a terminal:
/// one progress line per test, errors indented under their test, and a
/// summary line.
final class CompactRenderer implements TestRenderer {
  final StringSink out;

  CompactRenderer(this.out);

  @override
  void start(TestSession session, int suiteCount) {}

  @override
  void event(TestSession session, Map<String, Object?> event) {
    switch (event['type']) {
      case 'testStart':
        final test = session.tests[(event['test'] as Map)['id']];
        if (test != null) _line(session, _describe(session, test));
      case 'print':
        out.writeln(event['message']);
      case 'error':
        final test = session.tests[event['testID']];
        if (test != null && test.done) _error(session, test, event);
      case 'testDone':
        final test = session.tests[event['testID']];
        if (test == null) break;
        for (final error in test.pendingErrors) {
          _error(session, test, error);
        }
        test.pendingErrors.clear();
    }
  }

  @override
  void output(String text) => out.writeln(text);

  @override
  void note(String text) => out.writeln(text);

  @override
  void done(TestSession session, int exitCode) {
    final message = switch (exitCode) {
      noTestsRanExitCode => 'No tests ran.',
      0 when session.skipped > 0 && session.passed == 0 => 'All tests skipped.',
      0 when session.skipped > 0 => 'All other tests passed!',
      0 => 'All tests passed!',
      _ => 'Some tests failed.',
    };
    _line(session, message);
  }

  /// The command has already said why the run stopped.
  @override
  void stopped(TestSession session) {}

  void _error(
    TestSession session,
    TestRecord test,
    Map<String, Object?> error,
  ) {
    _line(session, '${_describe(session, test)} [E]');
    out.writeln(_indent('${error['error']}'));
    final stack = '${error['stackTrace']}'.trimRight();
    if (stack.isNotEmpty) out.writeln(_indent(stack));
  }

  String _describe(TestSession session, TestRecord test) {
    final path = session.suites[test.suiteId];
    if (path == null || test.name == 'loading $path') return test.name;
    return '$path: ${test.name}';
  }

  void _line(TestSession session, String message) {
    final time = session.elapsed();
    final clock =
        '${time.inMinutes.toString().padLeft(2, '0')}:'
        '${(time.inSeconds % 60).toString().padLeft(2, '0')}';
    final counts = StringBuffer('+${session.passed}');
    if (session.skipped > 0) counts.write(' ~${session.skipped}');
    if (session.failed > 0) counts.write(' -${session.failed}');
    out.writeln('$clock $counts: $message');
  }

  static String _indent(String text) =>
      const LineSplitter().convert(text).map((line) => '  $line').join('\n');
}

/// The public JSON reporter protocol: one event per line on [out], with the
/// host-added `start`, `allSuites` and `done` events. Every report ends
/// with `done`, which has `success: false` when the run stopped without a
/// result. Output that is not a test event goes to [err] so [out] stays
/// machine-readable.
final class JsonRenderer implements TestRenderer {
  final StringSink out;
  final StringSink err;

  /// The process ID reported in the `start` event.
  final int pid;

  /// The `runnerVersion` of the `start` event.
  final String? runnerVersion;

  JsonRenderer(this.out, this.err, {required this.pid, this.runnerVersion});

  @override
  void start(TestSession session, int suiteCount) {
    _emit(session, {
      'type': 'start',
      'protocolVersion': jsonProtocolVersion,
      'runnerVersion': runnerVersion,
      'pid': pid,
    });
    _emit(session, {'type': 'allSuites', 'count': suiteCount});
  }

  @override
  void event(TestSession session, Map<String, Object?> event) =>
      _emit(session, {...event});

  @override
  void output(String text) => err.writeln(text);

  @override
  void note(String text) => err.writeln(text);

  @override
  void done(TestSession session, int exitCode) =>
      _emit(session, {'type': 'done', 'success': exitCode == 0});

  @override
  void stopped(TestSession session) =>
      _emit(session, {'type': 'done', 'success': false});

  void _emit(TestSession session, Map<String, Object?> event) {
    event['time'] = session.elapsed().inMilliseconds;
    out.writeln(jsonEncode(event));
  }
}
