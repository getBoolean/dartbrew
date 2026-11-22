import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'host.dart';
import 'upstream.dart';

/// Where a release is qualified; every feature needs a result for each.
enum QualificationEnvironment {
  consoleAot('console_aot'),
  consoleJit('console_jit'),
  azaharAot('azahar_aot');

  /// The environment's key in a feature's `results`.
  final String key;

  const QualificationEnvironment(this.key);
}

/// The fields of `results.json`'s `devkitpro` object, each naming the
/// version the release was qualified with.
const devkitProVersionFields = ['devkitARM', 'libctru'];

/// The file name of the SDK archive for [host] at [version].
String sdkArchiveName(String version, Host host) =>
    'dartbrew-$version-${host.id}.zip';

/// A release that its qualification results do not cover; [problems] names
/// each archive, host record, devkitPro field or feature that failed.
final class ReleaseRefused implements Exception {
  final List<String> problems;

  const ReleaseRefused(this.problems);

  @override
  String toString() =>
      problems.map((problem) => 'refusing to publish: $problem').join('\n');
}

/// Checks that every archive in [archives] was qualified for [version] by
/// the `results.json` at [results], and returns the archives' file names.
///
/// [version] defaults to the version in `release/preview.json`. Throws
/// [ReleaseRefused] listing every problem found.
Future<List<String>> checkRelease({
  required File results,
  required List<File> archives,
  String? version,
}) async {
  final document = jsonDecode(await results.readAsString());
  final digests = [
    for (final archive in archives)
      (
        name: p.basename(archive.path),
        sha256: (await sha256.bind(archive.openRead()).first).toString(),
      ),
  ];
  final problems = releaseProblems(
    document as Map<String, Object?>,
    version: version ?? await previewVersion(),
    archives: digests,
  );
  if (problems.isNotEmpty) throw ReleaseRefused(problems);
  return [for (final archive in digests) archive.name];
}

/// The root of the repository this package is in.
Future<String> repositoryRoot() async {
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:release_tools/'),
  );
  return p.normalize(p.join(library!.toFilePath(), '..', '..', '..'));
}

/// The pin table, `toolchain/versions.json`.
Future<File> pinTable() async =>
    File(p.join(await repositoryRoot(), 'toolchain', 'versions.json'));

/// The version being released, from `release/preview.json`.
Future<String> previewVersion() async {
  final preview =
      jsonDecode(
            await File(
              p.join(await repositoryRoot(), 'release', 'preview.json'),
            ).readAsString(),
          )
          as Map<String, Object?>;
  return preview['version']! as String;
}

/// The upstream report for the pins in [versions], for printing after a
/// release check; never fails the release, so an unreadable upstream
/// becomes a line saying so.
Future<List<String>> upstreamReportLines(File versions, FetchJson fetch) async {
  try {
    final report = await checkUpstream(
      Pins.parse(await versions.readAsString()),
      fetch,
    );
    return report.lines;
  } on UpstreamUnavailable catch (error) {
    return ['upstream: check unavailable ($error)'];
  }
}

/// Every reason the qualification [results] do not cover [archives] at
/// [version]; empty when the release may be published.
List<String> releaseProblems(
  Map<String, Object?> results, {
  required String version,
  required List<({String name, String sha256})> archives,
}) {
  final problems = <String>[];
  if (results['version'] != version) {
    problems.add(
      'qualification results are for ${results['version']}, not $version',
    );
  }

  final devkitPro = results['devkitpro'];
  for (final field in devkitProVersionFields) {
    final recorded = devkitPro is Map<String, Object?>
        ? devkitPro[field]
        : null;
    if (recorded is! String || recorded.trim().isEmpty) {
      problems.add('qualification results have no devkitpro.$field version');
    }
  }

  final records = <String, Map<String, Object?>>{};
  for (final record in results['hosts'] as List<Object?>? ?? const []) {
    record as Map<String, Object?>;
    final id = record['host'];
    final host = id is String ? Host.byId(id) : null;
    if (host == null) {
      problems.add(
        'qualification results record unsupported host $id '
        '(supported: ${Host.values.map((host) => host.id).join(', ')})',
      );
      continue;
    }
    final archive = sdkArchiveName(version, host);
    if (record['sdk_archive'] != archive) {
      problems.add(
        'the ${host.id} record names ${record['sdk_archive']}, not $archive',
      );
    }
    records[archive] = record;
  }
  for (final host in Host.values) {
    if (!records.containsKey(sdkArchiveName(version, host))) {
      problems.add('qualification results have no record for host ${host.id}');
    }
  }

  if (archives.isEmpty) problems.add('no archives given');
  for (final (:name, :sha256) in archives) {
    final record = records[name];
    if (record == null) {
      problems.add('$name has no qualification record for $version');
    } else if (record['result'] != 'pass') {
      problems.add('$name did not pass qualification');
    } else if (record['sdk_sha256'] != sha256) {
      problems.add('$name differs from the qualified bytes');
    }
  }

  switch (results['features']) {
    case final List<Object?> features when features.isNotEmpty:
      for (final feature in features) {
        problems.addAll(_featureProblems(feature as Map<String, Object?>));
      }
    default:
      problems.add('qualification results have no features');
  }
  return problems;
}

List<String> _featureProblems(Map<String, Object?> feature) {
  final outcomes = feature['results'] as Map<String, Object?>? ?? const {};
  return [
    for (final environment in QualificationEnvironment.values)
      if (!_isQualified(outcomes[environment.key]))
        'feature ${feature['name']} did not pass on ${environment.key}: '
            '${jsonEncode(outcomes[environment.key])}',
  ];
}

bool _isQualified(Object? outcome) => switch (outcome) {
  'pass' => true,
  {'result': 'not_applicable', 'reason': final String reason} =>
    reason.trim().isNotEmpty,
  _ => false,
};
