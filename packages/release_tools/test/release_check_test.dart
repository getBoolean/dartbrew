import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/release_check.dart';
import 'package:test/test.dart';

const version = '9.9.9-test';
const supportedHosts = ['windows-x64', 'linux-x64', 'macos-arm64'];
const azaharNoJit =
    'Azahar cannot run the JIT VM (needs Luma3DS custom SVC 0x80)';

String digestOf(String text) => sha256.convert(utf8.encode(text)).toString();

Map<String, Object?> feature(
  String name, [
  Map<String, Object?> results = const {},
]) => {
  'name': name,
  'covers': 'U6, R1',
  'results': {
    'console_aot': 'pass',
    'console_jit': 'pass',
    'azahar_aot': 'pass',
    ...results,
  },
};

Map<String, Object?> hostEntry(String host, {String? archive}) => {
  'host': host,
  'sdk_archive': archive ?? 'dartbrew-$version-$host.zip',
  'sdk_sha256': digestOf('qualified $host'),
  'result': 'pass',
};

/// A results document shaped like preview.5 that qualifies every archive
/// written by [Fixture.archive].
Map<String, Object?> qualifiedResults() => {
  'version': version,
  'devkitpro': {'devkitARM': 'r68-1', 'libctru': '2.7.0-1'},
  'hosts': [for (final host in supportedHosts) hostEntry(host)],
  'features': [feature('files')],
};

final class Fixture {
  final Directory root;
  Fixture._(this.root);

  factory Fixture() {
    final root = Directory.systemTemp.createTempSync('release-check-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    return Fixture._(root);
  }

  File results(Object? document) =>
      File(p.join(root.path, 'results.json'))
        ..writeAsStringSync(jsonEncode(document));

  /// Writes `dartbrew-<version>-<host>.zip` holding the bytes its
  /// [hostEntry] qualified, or [contents] instead.
  File archive(String host, {String? name, String? contents}) =>
      File(p.join(root.path, name ?? 'dartbrew-$version-$host.zip'))
        ..writeAsStringSync(contents ?? 'qualified $host');

  List<File> allArchives() => [
    for (final host in supportedHosts) archive(host),
  ];
}

Matcher refusedWith(List<Object> problems) => throwsA(
  isA<ReleaseRefused>().having((e) => e.problems, 'problems', problems),
);

Map<String, Object?> withHosts(
  Map<String, Object?> results,
  List<Map<String, Object?>> Function(List<Map<String, Object?>> hosts) edit,
) => {
  ...results,
  'hosts': edit([
    for (final host in results['hosts']! as List<Object?>)
      Map<String, Object?>.of(host! as Map<String, Object?>),
  ]),
};

void main() {
  late Fixture fixture;

  setUp(() => fixture = Fixture());

  Future<List<String>> check(Object? results, List<File> archives) =>
      checkRelease(
        results: fixture.results(results),
        archives: archives,
        version: version,
      );

  test('a release whose archives match passing host records passes', () async {
    final archives = fixture.allArchives();
    expect(await check(qualifiedResults(), archives), [
      for (final host in supportedHosts) 'dartbrew-$version-$host.zip',
    ]);
  });

  test(
    'a partial release reports missing archives and failed host records',
    () async {
      final results = withHosts(
        qualifiedResults(),
        (hosts) => [
          for (final host in hosts)
            {...host, if (host['host'] == 'macos-arm64') 'result': 'fail'},
        ],
      );
      await expectLater(
        check(results, [fixture.archive('linux-x64')]),
        refusedWith([
          'dartbrew-$version-macos-arm64.zip did not pass qualification',
          'missing archive dartbrew-$version-windows-x64.zip',
          'missing archive dartbrew-$version-macos-arm64.zip',
        ]),
      );
    },
  );

  test('duplicate archives and host records are refused', () async {
    final results = withHosts(
      qualifiedResults(),
      (hosts) => [...hosts, hosts.first],
    );
    final archives = fixture.allArchives();
    await expectLater(
      check(results, [...archives, archives.first]),
      refusedWith([
        'duplicate qualification record for host windows-x64',
        'duplicate archive dartbrew-$version-windows-x64.zip',
      ]),
    );
  });

  group('archives are refused', () {
    test('when the results are for another version', () async {
      await expectLater(
        check({
          ...qualifiedResults(),
          'version': '0.0.1',
        }, fixture.allArchives()),
        refusedWith([contains('for 0.0.1, not $version')]),
      );
    });

    test('when the bytes differ, naming the archive', () async {
      final archives = fixture.allArchives();
      fixture.archive('linux-x64', contents: 'rebuilt');
      await expectLater(
        check(qualifiedResults(), archives),
        refusedWith([
          'dartbrew-$version-linux-x64.zip differs from the qualified bytes',
        ]),
      );
    });

    test('when the host failed qualification', () async {
      final results = withHosts(
        qualifiedResults(),
        (hosts) => [
          for (final host in hosts)
            {...host, if (host['host'] == 'linux-x64') 'result': 'fail'},
        ],
      );
      await expectLater(
        check(results, fixture.allArchives()),
        refusedWith([
          'dartbrew-$version-linux-x64.zip did not pass qualification',
        ]),
      );
    });

    for (final (label, name) in [
      ('an older version', 'dartbrew-0.0.1-linux-x64.zip'),
      ('the pre-dartbrew name', 'ctr-dart-$version-linux-x64.zip'),
      ('an unsupported host', 'dartbrew-$version-macos-x64.zip'),
    ]) {
      test('when named for $label', () async {
        final archive = fixture.archive('linux-x64', name: name);
        await expectLater(
          check(qualifiedResults(), [...fixture.allArchives(), archive]),
          refusedWith(['$name has no qualification record for $version']),
        );
      });
    }

    test('when none are given', () async {
      await expectLater(
        check(qualifiedResults(), []),
        refusedWith([
          'no archives given',
          for (final host in supportedHosts)
            'missing archive dartbrew-$version-$host.zip',
        ]),
      );
    });
  });

  group('host records', () {
    test('missing a supported host are refused, naming the host', () async {
      final results = withHosts(
        qualifiedResults(),
        (hosts) => [
          for (final host in hosts)
            if (host['host'] != 'windows-x64') host,
        ],
      );
      await expectLater(
        check(results, fixture.allArchives()),
        refusedWith([
          'qualification results have no record for host windows-x64',
          'dartbrew-$version-windows-x64.zip has no qualification record for $version',
        ]),
      );
    });

    test('for macos-x64 are refused as an unsupported host', () async {
      final results = withHosts(
        qualifiedResults(),
        (hosts) => [...hosts, hostEntry('macos-x64')],
      );
      await expectLater(
        check(results, fixture.allArchives()),
        refusedWith([
          'qualification results record unsupported host macos-x64 '
              '(supported: windows-x64, linux-x64, macos-arm64)',
        ]),
      );
    });

    test('naming an archive other than the host\'s are refused', () async {
      const stale = 'dartbrew-0.0.1-linux-x64.zip';
      final results = withHosts(
        qualifiedResults(),
        (hosts) => [
          for (final host in hosts)
            {...host, if (host['host'] == 'linux-x64') 'sdk_archive': stale},
        ],
      );
      await expectLater(
        check(results, fixture.allArchives()),
        refusedWith([
          'the linux-x64 record names $stale, '
              'not dartbrew-$version-linux-x64.zip',
        ]),
      );
    });
  });

  group('qualified devkitPro versions', () {
    for (final field in ['devkitARM', 'libctru']) {
      test('missing $field are refused, naming the field', () async {
        final results = {
          ...qualifiedResults(),
          'devkitpro': {'devkitARM': 'r68-1', 'libctru': '2.7.0-1'}
            ..remove(field),
        };
        await expectLater(
          check(results, fixture.allArchives()),
          refusedWith([
            'qualification results have no devkitpro.$field version',
          ]),
        );
      });
    }

    test('missing entirely are refused, naming both fields', () async {
      final results = {...qualifiedResults()}..remove('devkitpro');
      await expectLater(
        check(results, fixture.allArchives()),
        refusedWith([
          'qualification results have no devkitpro.devkitARM version',
          'qualification results have no devkitpro.libctru version',
        ]),
      );
    });

    test('blank are refused', () async {
      final results = {
        ...qualifiedResults(),
        'devkitpro': {'devkitARM': ' ', 'libctru': '2.7.0-1'},
      };
      await expectLater(
        check(results, fixture.allArchives()),
        refusedWith([
          'qualification results have no devkitpro.devkitARM version',
        ]),
      );
    });
  });

  group('features', () {
    test('passing or not applicable with a reason are accepted', () async {
      final results = {
        ...qualifiedResults(),
        'features': [
          feature('files'),
          feature('runtime loader', {
            'azahar_aot': {
              'result': 'not_applicable',
              'reason': 'Azahar cannot run the runtime .so loader',
            },
          }),
          feature('jit-only', {
            'azahar_aot': {'result': 'not_applicable', 'reason': azaharNoJit},
          }),
        ],
      };
      expect(await check(results, fixture.allArchives()), hasLength(3));
    });

    final notApplicable = {'result': 'not_applicable'};
    for (final (label, features, problem) in <(String, Object?, String)>[
      (
        'failed console JIT',
        [
          feature('stdio', {'console_jit': 'fail'}),
        ],
        'feature stdio did not pass on console_jit: "fail"',
      ),
      (
        'failed console AOT',
        [
          feature('romfs', {'console_aot': 'fail'}),
        ],
        'feature romfs did not pass on console_aot: "fail"',
      ),
      (
        'missing environment',
        [
          {
            'name': 'exit',
            'covers': 'U8',
            'results': {'console_aot': 'pass', 'console_jit': 'pass'},
          },
        ],
        'feature exit did not pass on azahar_aot: null',
      ),
      (
        'not applicable without reason',
        [
          feature('runtime loader', {'azahar_aot': notApplicable}),
        ],
        'feature runtime loader did not pass on azahar_aot: '
            '{"result":"not_applicable"}',
      ),
      (
        'not applicable with blank reason',
        [
          feature('runtime loader', {
            'azahar_aot': {...notApplicable, 'reason': ' '},
          }),
        ],
        'feature runtime loader did not pass on azahar_aot: '
            '{"result":"not_applicable","reason":" "}',
      ),
      (
        'bare not applicable string',
        [
          feature('runtime loader', {'azahar_aot': 'not_applicable'}),
        ],
        'feature runtime loader did not pass on azahar_aot: "not_applicable"',
      ),
      (
        'second feature fails',
        [
          feature('files'),
          feature('platform', {'console_jit': 'fail'}),
        ],
        'feature platform did not pass on console_jit: "fail"',
      ),
      for (final environment in ['console_aot', 'console_jit', 'azahar_aot'])
        (
          'pending files on $environment',
          [
            feature('files', {
              environment: {...notApplicable, 'reason': 'pending'},
            }),
          ],
          'feature files did not pass on $environment: {"result":"not_applicable","reason":"pending"}',
        ),
      ('no features section', null, 'qualification results have no features'),
      ('empty features section', [], 'qualification results have no features'),
    ]) {
      test('are refused for $label', () async {
        final results = {...qualifiedResults(), 'features': features};
        await expectLater(
          check(results, fixture.allArchives()),
          refusedWith([problem]),
        );
      });
    }
  });

  test('the version defaults to release/preview.json', () async {
    final preview =
        jsonDecode(File('../../release/preview.json').readAsStringSync())
            as Map<String, Object?>;
    final current = preview['version']! as String;
    expect(current, isNot(version));
    await expectLater(
      checkRelease(
        results: fixture.results(qualifiedResults()),
        archives: [fixture.archive('linux-x64')],
      ),
      throwsA(
        isA<ReleaseRefused>().having(
          (e) => e.problems,
          'problems',
          contains('qualification results are for $version, not $current'),
        ),
      ),
    );
  });

  test('the committed preview.4 results are refused, naming every problem '
      'except the hashes of the supported hosts', () async {
    const preview4 = '0.1.0-preview.4';
    final committed =
        jsonDecode(
              File(
                '../../docs/qualification/$preview4/results.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final results = withHosts(
      committed,
      (hosts) => [
        for (final host in hosts)
          {...host, 'sdk_sha256': digestOf('qualified ${host['host']}')},
      ],
    );
    final archives = [
      for (final host in supportedHosts)
        fixture.archive(host, name: 'dartbrew-$preview4-$host.zip'),
    ];
    await expectLater(
      checkRelease(
        results: fixture.results(results),
        archives: archives,
        version: preview4,
      ),
      refusedWith([
        'qualification results have no devkitpro.devkitARM version',
        'qualification results have no devkitpro.libctru version',
        'qualification results record unsupported host macos-x64 '
            '(supported: windows-x64, linux-x64, macos-arm64)',
        'qualification results have no features',
      ]),
    );
  });

  group('the check_release executable', () {
    final preview =
        jsonDecode(File('../../release/preview.json').readAsStringSync())
            as Map<String, Object?>;
    final current = preview['version']! as String;

    Map<String, Object?> currentResults(List<Map<String, Object?>> features) =>
        {
          ...qualifiedResults(),
          'version': current,
          'hosts': [
            for (final host in supportedHosts)
              hostEntry(host, archive: 'dartbrew-$current-$host.zip'),
          ],
          'features': features,
        };

    Future<ProcessResult> runWith(List<String> arguments) => Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/check_release.dart', ...arguments],
    );

    Future<ProcessResult> run(File results, File archive) => runWith([
      '--results',
      results.path,
      archive.path,
      for (final host in supportedHosts.where((host) => host != 'linux-x64'))
        fixture.archive(host, name: 'dartbrew-$current-$host.zip').path,
    ]);

    test('prints the qualified archives and exits 0', () async {
      final archive = fixture.archive(
        'linux-x64',
        name: 'dartbrew-$current-linux-x64.zip',
      );
      final result = await run(
        fixture.results(currentResults([feature('files')])),
        archive,
      );
      expect(result.stderr, isEmpty);
      // Then the upstream report, or a line saying it is unavailable.
      expect(
        result.stdout,
        startsWith(
          'qualified: dartbrew-$current-linux-x64.zip, dartbrew-$current-windows-x64.zip, dartbrew-$current-macos-arm64.zip\nupstream: ',
        ),
      );
      expect(result.exitCode, 0);
    });

    test('prints each problem and exits 1 when refusing', () async {
      final archive = fixture.archive(
        'linux-x64',
        name: 'dartbrew-$current-linux-x64.zip',
        contents: 'rebuilt',
      );
      final result = await run(
        fixture.results(
          currentResults([
            feature('stdio', {'console_jit': 'fail'}),
          ]),
        ),
        archive,
      );
      expect(result.stdout, isEmpty);
      expect(
        result.stderr,
        'refusing to publish: dartbrew-$current-linux-x64.zip differs from '
        'the qualified bytes\n'
        'refusing to publish: feature stdio did not pass on console_jit: '
        '"fail"\n',
      );
      expect(result.exitCode, 1);
    });

    test('prints usage and exits 64 without --results', () async {
      final archive = fixture.archive('linux-x64');
      final result = await runWith([archive.path]);
      expect(result.stdout, isEmpty);
      expect(result.stderr, startsWith('Missing --results.'));
      expect(result.stderr, contains('Usage: check_release'));
      expect(result.exitCode, 64);
    });
  });
}
