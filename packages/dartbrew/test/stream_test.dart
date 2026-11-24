import 'dart:convert';

import 'package:dartbrew/src/device/run_identity.dart';
import 'package:dartbrew/src/device/stream.dart';
import 'package:dartbrew/src/device/verdict.dart';
import 'package:dartbrew/src/targets/ctr/pipeline.dart' show BuildMode;
import 'package:test/test.dart';

const runId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const otherRunId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

const compatibility =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const artifactSha256 =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const buildId =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

const identity = RunIdentity(
  schema: 2,
  runId: runId,
  fixture: 'hello',
  mode: BuildMode.jit,
  compatibility: compatibility,
  artifactSha256: artifactSha256,
  buildId: buildId,
  environment: RunEnvironment.host,
);

/// The launcher's `begin` record for [identity].
const begin = <String, Object?>{
  'event': 'begin',
  'schema': 2,
  'run_id': runId,
  'fixture': 'hello',
  'mode': 'jit',
  'compatibility': compatibility,
  'artifact_sha256': artifactSha256,
  'build_id': buildId,
  'environment': 'host',
};

String line(Map<String, Object?> record) =>
    '${RuntimeLineParser.prefix}${jsonEncode(record)}';

String output(String text, {String run = runId, bool continues = false}) =>
    line({
      'event': 'output',
      'run_id': run,
      'text': text,
      if (continues) 'continues': true,
    });

List<RuntimeLine> parse(List<String> lines) {
  final parser = RuntimeLineParser();
  return [
    ...parser.feed(utf8.encode(lines.map((l) => '$l\n').join())),
    ...parser.close(),
  ];
}

List<Object?> texts(List<RuntimeLine> lines) => [
  for (final l in lines)
    if (l is RuntimeRecord) l.fields['text'] else l,
];

void main() {
  group('continuation records', () {
    test('a 200 KiB line split into records is one output, and passes', () {
      const pieceLength = 8 * 1024;
      final text = List.generate(200 * 1024, (i) => 'abcdefgh'[i % 8]).join();
      final pieces = [
        for (var i = 0; i < text.length; i += pieceLength)
          text.substring(i, (i + pieceLength).clamp(0, text.length)),
      ];
      final lines = [
        line(begin),
        for (var i = 0; i < pieces.length; i++)
          output(pieces[i], continues: i < pieces.length - 1),
        line({
          'event': 'assert',
          'run_id': runId,
          'name': 'cleanup',
          'status': 'pass',
        }),
        line({
          'event': 'terminal',
          'run_id': runId,
          'outcome': 'pass',
          'assertions': 1,
        }),
      ];
      expect(pieces, hasLength(25));

      final accumulator = VerdictAccumulator(identity);
      final printed = parse(lines).map(accumulator.add).nonNulls.toList();
      final verdict = accumulator.finish();

      expect(printed, [text]);
      expect(verdict.outcome, Outcome.pass);
      expect(verdict.output, [text]);
    });

    test('a continued record of a stopped run is dropped', () {
      final records = parse([
        output('stopped mid-', run: otherRunId, continues: true),
        line(begin),
      ]);

      expect(records, hasLength(1));
      expect((records.single as RuntimeRecord).fields['event'], 'begin');
    });

    test('a continued record followed by a non-output record is dropped', () {
      expect(texts(parse([output('one', continues: true), output('two')])), [
        'onetwo',
      ]);
      final records = parse([
        output('lost', continues: true),
        line({'event': 'assert', 'run_id': runId}),
        output('kept'),
      ]);
      expect(texts(records), [null, 'kept']);
      expect((records.first as RuntimeRecord).fields['event'], 'assert');
    });

    test('a keepalive between a record and its continuation is ignored', () {
      expect(
        texts(parse([output('one', continues: true), '', output('two')])),
        ['onetwo'],
      );
    });

    test('a continued record still open at the end is dropped', () {
      expect(parse([output('partial', continues: true)]), isEmpty);
    });

    test('a malformed line ends an open continuation', () {
      final records = parse([
        output('lost', continues: true),
        '${RuntimeLineParser.prefix}not json',
        output('kept'),
      ]);
      expect(records.first, isA<MalformedRecord>());
      expect(texts(records.skip(1).toList()), ['kept']);
    });
  });
}
