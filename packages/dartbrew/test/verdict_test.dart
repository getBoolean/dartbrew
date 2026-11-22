import 'dart:convert';
import 'dart:io';

import 'package:dartbrew/src/device/stream.dart';
import 'package:dartbrew/src/device/verdict.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

typedef Case = ({
  String name,
  Map<String, Object?> identity,
  List<String> lines,
  Observation? observation,
  Outcome outcome,
  String? reason,
  List<String> output,
  int? exitCode,
});

final vectors = _loadVectors();

List<Case> _loadVectors() {
  // Tests run with the package root as the working directory.
  final file = File(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'runtime',
      'ctr',
      'test',
      'verdict_vectors.json',
    ),
  );
  final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  Case parse(Map<String, Object?> c) {
    final expect = c['expect']! as Map<String, Object?>;
    final observation = c['observation'] as String?;
    return (
      name: c['name']! as String,
      identity: c['identity']! as Map<String, Object?>,
      lines: (c['lines']! as List<Object?>).cast<String>(),
      observation: observation == null
          ? null
          : Observation.values.byName(observation),
      outcome: Outcome.values.byName(expect['outcome']! as String),
      reason: expect['reason'] as String?,
      output: (expect['output']! as List<Object?>).cast<String>(),
      exitCode: expect['exit_code'] as int?,
    );
  }

  return [
    for (final c in json['cases']! as List<Object?>)
      parse(c! as Map<String, Object?>),
  ];
}

List<int> journalBytes(List<String> lines) => utf8.encode(lines.join('\n'));

Verdict verdictOf(
  Map<String, Object?> identity,
  List<List<int>> chunks, [
  Observation? observation,
]) {
  final parser = RuntimeLineParser();
  final accumulator = VerdictAccumulator(identity);
  for (final chunk in chunks) {
    parser.feed(chunk).forEach(accumulator.add);
  }
  parser.close().forEach(accumulator.add);
  return accumulator.finish(observation);
}

/// Feeds [lines] whole and returns the output texts offered for printing.
List<String> printedFrom(VerdictAccumulator accumulator, List<String> lines) {
  final parser = RuntimeLineParser();
  return [
    for (final l in parser.feed(utf8.encode('${lines.join('\n')}\n')))
      accumulator.add(l),
  ].whereType<String>().toList();
}

Map<String, Object?> record(Map<String, Object?> identity, String event) => {
  'event': event,
  'run_id': identity['run_id'],
};

String line(Map<String, Object?> record) =>
    '${RuntimeLineParser.prefix}${jsonEncode(record)}';

void main() {
  test('vectors are loaded', () => expect(vectors.length, greaterThan(30)));

  group('vectors', () {
    for (final c in vectors) {
      test(c.name, () {
        final verdict = verdictOf(c.identity, [
          journalBytes(c.lines),
        ], c.observation);
        expect(verdict.outcome, c.outcome);
        expect(verdict.reason, c.reason);
        expect(verdict.output, c.output);
        expect(verdict.exitCode, c.exitCode);
      });

      test('${c.name} (one byte at a time)', () {
        final verdict = verdictOf(c.identity, [
          for (final b in journalBytes(c.lines)) [b],
        ], c.observation);
        expect(verdict.outcome, c.outcome);
        expect(verdict.reason, c.reason);
        expect(verdict.output, c.output);
        expect(verdict.exitCode, c.exitCode);
      });
    }
  });

  test('truncation at every record boundary is incomplete', () {
    final c = vectors.first;
    expect(c.outcome, Outcome.pass);
    for (var count = 0; count < c.lines.length; count++) {
      final verdict = verdictOf(c.identity, [
        journalBytes(c.lines.take(count).toList()),
      ]);
      expect(verdict.outcome, Outcome.incomplete, reason: 'count $count');
    }
  });

  group('older runs', () {
    final identity = vectors.first.identity;
    final lines = vectors.first.lines;
    final older = {...identity, 'run_id': '0' * 32};

    test('before the current begin are ignored', () {
      final accumulator = VerdictAccumulator(identity);
      final printed = printedFrom(accumulator, [
        line({...older, 'event': 'begin'}),
        line({...record(older, 'output'), 'text': 'old'}),
        ...lines,
      ]);
      expect(printed, ['async stack\nline']);
      expect(accumulator.finish().outcome, Outcome.pass);
    });

    test('after the current begin make the verdict incomplete', () {
      final accumulator = VerdictAccumulator(identity);
      final printed = printedFrom(accumulator, [
        lines[0],
        line({...record(older, 'output'), 'text': 'old'}),
        lines[1],
      ]);
      expect(printed, isEmpty);
      final verdict = accumulator.finish();
      expect(verdict.outcome, Outcome.incomplete);
      expect(verdict.reason, 'interleaved run');
    });
  });

  group('parser', () {
    test('output text is offered as each record completes', () {
      final accumulator = VerdictAccumulator(vectors.first.identity);
      final parser = RuntimeLineParser();
      final bytes = utf8.encode('${vectors.first.lines.join('\n')}\n');
      final printed = <String>[];
      for (final b in bytes) {
        for (final l in parser.feed([b])) {
          final text = accumulator.add(l);
          if (text != null) printed.add(text);
        }
      }
      expect(printed, ['async stack\nline']);
    });

    test('multi-byte characters split across chunks decode', () {
      final bytes = utf8.encode('CTR_RUNTIME {"text":"hé\u{1F600}"}\n');
      final parser = RuntimeLineParser();
      final out = [
        for (var i = 0; i < bytes.length; i += 3)
          ...parser.feed(bytes.sublist(i, (i + 3).clamp(0, bytes.length))),
      ];
      expect((out.single as RuntimeRecord).fields['text'], 'hé\u{1F600}');
    });

    test('a final line without a line ending is emitted on close', () {
      final parser = RuntimeLineParser();
      expect(parser.feed(utf8.encode('CTR_RUNTIME {"a":1}')), isEmpty);
      expect(parser.close(), hasLength(1));
      expect(parser.close(), isEmpty);
    });
  });

  group('exit codes', () {
    const reportedPass = Verdict(Outcome.pass, null, []);
    const reportedFail = Verdict(Outcome.fail, null, []);
    const stopped = Verdict(Outcome.incomplete, null, []);
    const noTerminal = Verdict(
      Outcome.incomplete,
      'missing begin, cleanup or terminal',
      [],
      noTerminal: true,
    );
    const malformed = Verdict(
      Outcome.incomplete,
      'malformed current-run record',
      [],
    );

    test('pass exits 0 without a message', () {
      for (final end in StreamEnd.values) {
        final exit = exitFor(reportedPass, end);
        expect((exit.code, exit.message), (0, null));
      }
    });

    test('fail exits 255 without a message', () {
      for (final end in StreamEnd.values) {
        final exit = exitFor(reportedFail, end);
        expect((exit.code, exit.message), (255, null));
      }
    });

    test('fail with an exit code exits with that code', () {
      const exited = Verdict(Outcome.fail, null, [], exitCode: 3);
      expect(exitFor(exited, StreamEnd.closed).code, 3);
    });

    test('fail with exit code 0 still exits 255', () {
      const cleanupFailed = Verdict(Outcome.fail, null, [], exitCode: 0);
      expect(exitFor(cleanupFailed, StreamEnd.closed).code, 255);
    });

    test('exit codes a process cannot exit with become 255', () {
      for (final code in [256, -1, 1000]) {
        final verdict = Verdict(Outcome.fail, null, [], exitCode: code);
        expect(exitFor(verdict, StreamEnd.closed).code, 255);
      }
    });

    test('terminal incomplete says it stopped on the console', () {
      final exit = exitFor(stopped, StreamEnd.closed);
      expect((exit.code, exit.message), (1, 'stopped on console'));
    });

    test('no terminal depends on how the stream ended', () {
      expect(exitFor(noTerminal, StreamEnd.closed).message, 'lost connection');
      expect(
        exitFor(noTerminal, StreamEnd.idleTimeout).message,
        'lost connection',
      );
      expect(exitFor(noTerminal, StreamEnd.userTimeout).message, 'timed out');
      final connect = exitFor(noTerminal, StreamEnd.connectTimeout, port: 9);
      expect(connect.code, 1);
      expect(connect.message, contains('firewall'));
      expect(connect.message, contains('port 9'));
    });

    test('rule violations report their reason', () {
      final exit = exitFor(malformed, StreamEnd.closed);
      expect((exit.code, exit.message), (1, 'malformed current-run record'));
    });

    test('an empty journal is a lost connection', () {
      final verdict = VerdictAccumulator(vectors.first.identity).finish();
      expect(exitFor(verdict, StreamEnd.closed).message, 'lost connection');
    });
  });
}
