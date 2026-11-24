import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:release_tools/src/release_check.dart';
import 'package:release_tools/src/upstream.dart';
import 'package:test/test.dart';

/// Responses recorded from the live sources on 2026-11-22: libctru v2.7.1
/// released, devkitARM r68, the 20260610 image pinned, Dart beta newer.
final fixtures = p.join('test', 'fixtures', 'upstream');

Object? recorded(String name) =>
    jsonDecode(File(p.join(fixtures, name)).readAsStringSync());

const pinnedDigest =
    'sha256:116afba8df8453961de2936ffab20dd441edf4d682856c1ec8b0e53d7ed0bbf5';

/// A [FetchJson] answering from recorded responses, with [edit] applied to
/// the response named by each source.
FetchJson recordedFetch({
  Object? Function(List<Object?>)? libctru,
  Object? Function(List<Object?>)? commits,
  Object? Function(List<Object?>)? tags,
}) => (url) async {
  Object? edited(String name, Object? Function(List<Object?>)? edit) {
    final response = recorded(name);
    return edit == null ? response : edit(response as List<Object?>);
  }

  return switch (url.host) {
    'storage.googleapis.com' => recorded('dart_beta_version.json'),
    'hub.docker.com' => {
      ...recorded('devkitarm_tags.json') as Map<String, Object?>,
      if (tags != null)
        'results': tags(
          (recorded('devkitarm_tags.json') as Map<String, Object?>)['results']
              as List<Object?>,
        ),
    },
    _ when url.path.endsWith('/libctru/releases') => edited(
      'libctru_releases.json',
      libctru,
    ),
    _ when url.path.endsWith('/buildscripts/commits') => edited(
      'buildscripts_commits.json',
      commits,
    ),
    _ => throw StateError('unexpected request to $url'),
  };
};

/// The recorded pin table, with LF line endings whatever the checkout uses.
final versionsText = File(
  p.join(fixtures, 'versions.json'),
).readAsStringSync().replaceAll('\r\n', '\n');

Future<UpstreamReport> report(FetchJson fetch) =>
    checkUpstream(Pins.parse(versionsText), fetch);

void main() {
  group('check_upstream', () {
    test('reports the recorded state: libctru behind, image current', () async {
      expect((await report(recordedFetch())).lines, [
        'upstream: 2 updates available',
        '  libctru 2.7.0 -> 2.7.1 (released 2026-11-01; '
            'not in a devkitpro/devkitarm image yet)',
        '  devkitARM r68 current',
        '  devkitpro/devkitarm image $pinnedDigest current (tag 20260610)',
        '  dart 3.14.0-315.3.beta -> 3.15.0-118.1.beta '
            '(beta channel, released 2026-11-04)',
      ]);
    });

    test('lists a newer libctru release against the pin', () async {
      final lines = (await report(
        recordedFetch(
          libctru: (releases) => [
            {
              'tag_name': 'v2.7.2',
              'name': 'libctru v2.7.2',
              'draft': false,
              'prerelease': false,
              'published_at': '2026-11-20T10:00:00Z',
            },
            ...releases,
          ],
        ),
      )).lines;
      expect(lines, contains(startsWith('  libctru 2.7.0 -> 2.7.2 ')));
    });

    test('names the image that contains a new devkitARM release', () async {
      const newDigest =
          'sha256:0000000000000000000000000000000000000000000000000000000000000069';
      final lines = (await report(
        recordedFetch(
          commits: (commits) => [
            {
              'sha': '69',
              'commit': {
                'message': 'devkitARM: release 69',
                'committer': {'date': '2026-12-01T18:00:00Z'},
              },
            },
            ...commits,
          ],
          tags: (tags) => [
            {
              'name': '20261201',
              'digest': newDigest,
              'last_updated': '2026-12-01T12:00:00Z',
            },
            ...tags,
          ],
        ),
      )).lines;
      expect(lines, [
        'upstream: 4 updates available',
        anything,
        '  devkitARM r68 -> r69 (released 2026-12-01; '
            'in image $newDigest (tag 20261201))',
        '  devkitpro/devkitarm image $pinnedDigest -> $newDigest '
            '(tag 20261201)',
        anything,
      ]);
    });

    test('an image pushed hours before the release commit contains it '
        '(r68: image 13:53Z, commit 16:01Z)', () async {
      final upstream = await report(recordedFetch());
      expect(upstream.imageContaining(upstream.devkitArm), (
        name: '20260610',
        digest: pinnedDigest,
      ));
    });

    test('names the source that cannot be read', () async {
      final failing = recordedFetch();
      await expectLater(
        report((url) async {
          if (url.host == 'hub.docker.com') {
            throw UpstreamUnavailable(url, 'HTTP 503');
          }
          return failing(url);
        }),
        throwsA(
          isA<UpstreamUnavailable>().having(
            (e) => e.url.host,
            'host',
            'hub.docker.com',
          ),
        ),
      );
    });
  });

  group('the live client', () {
    test('reports an HTTP error as unavailable', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen(
        (request) => request.response
          ..statusCode = HttpStatus.forbidden
          ..write('rate limited')
          ..close(),
      );
      final client = upstreamHttpClient();
      addTearDown(client.close);
      await expectLater(
        httpFetchJson(client)(Uri.parse('http://127.0.0.1:${server.port}/')),
        throwsA(
          isA<UpstreamUnavailable>().having(
            (e) => e.reason,
            'reason',
            'HTTP 403: rate limited',
          ),
        ),
      );
    });

    test('reports a refused connection as unavailable', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final client = upstreamHttpClient();
      addTearDown(client.close);
      await expectLater(
        httpFetchJson(client)(Uri.parse('http://127.0.0.1:$port/')),
        throwsA(isA<UpstreamUnavailable>()),
      );
    });
  });

  group('check_release upstream report', () {
    test('prints the updates it finds', () async {
      final lines = await upstreamReportLines(
        File(p.join(fixtures, 'versions.json')),
        recordedFetch(),
      );
      expect(lines.first, 'upstream: 2 updates available');
    });

    test('reports an unreachable upstream instead of failing', () async {
      final lines = await upstreamReportLines(
        File(p.join(fixtures, 'versions.json')),
        (url) async => throw UpstreamUnavailable(url, 'offline'),
      );
      expect(lines, [startsWith('upstream: check unavailable (cannot read ')]);
    });
  });

  group('update_upstream devkitpro', () {
    const newPin = ContainerPin(
      digest:
          'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      devkitArm: 'r69-1',
      libctru: '2.7.2-1',
      gcc: '16.2.0',
    );

    test('rewrites only the container entry', () {
      final rewritten = rewriteContainerPin(versionsText, newPin);
      const before = '  "container": {\n';
      const after = '\n  },\n  "formats"';
      final start = versionsText.indexOf(before) + before.length;
      final end = versionsText.indexOf(after);
      expect(rewritten.substring(0, start), versionsText.substring(0, start));
      expect(
        rewritten.substring(rewritten.indexOf(after)),
        versionsText.substring(end),
      );
      expect(
        rewritten.substring(start, rewritten.indexOf(after)),
        '    "image": "devkitpro/devkitarm@sha256:'
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",\n'
        '    "devkitARM": "r69-1",\n'
        '    "gcc": "16.2.0",\n'
        '    "libctru": "2.7.2-1"',
      );
    });

    test('reads the pin from the image versions output', () {
      final pin = parseImageVersions(
        newPin.digest,
        'devkitARM r69-1\nlibctru 2.7.2-1\n16.2.0\n',
      );
      expect(
        (pin.digest, pin.devkitArm, pin.libctru, pin.gcc),
        (newPin.digest, 'r69-1', '2.7.2-1', '16.2.0'),
      );
    });

    test('an unknown component exits with a usage error naming the valid '
        'components', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/update_upstream.dart',
        'devkitarm',
      ]);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('Components: devkitpro'));
    });
  });
}
