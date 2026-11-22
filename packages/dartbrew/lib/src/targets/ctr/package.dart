import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../sdk.dart';
import 'pipeline.dart';

/// A new random 32-hex-digit run ID.
String newRunId([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(
    16,
    (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// The `artifact.json` record for [build].
Map<String, Object?> artifactRecord(CtrBuild build) => {
  'schema': 1,
  'scope': 'compile-link-package-only',
  'fixture': build.fixture,
  'mode': build.mode.name,
  'compatibility': build.compatibility,
  'build_id': build.buildId,
  'artifact_sha256': build.artifactSha256,
  'payload_sha256': build.payloadSha256,
  'elf_sha256': build.elfSha256,
  'sdk_head': build.sdkHead,
  'sdk_manifest_sha256': build.sdkManifestSha256,
};

/// The run identity for [build], schema 1 unless [schema] says otherwise.
/// The native launcher reads these eight keys in this exact order from
/// `ctr-runtime-run.cfg`.
Map<String, Object> runIdentity(
  CtrBuild build,
  String runId, {
  String environment = 'hardware',
  int schema = 1,
}) => {
  'schema': schema,
  'run_id': runId,
  'fixture': build.fixture,
  'mode': build.mode.name,
  'compatibility': build.compatibility,
  'artifact_sha256': build.artifactSha256,
  'build_id': build.buildId,
  'environment': environment,
};

/// Writes [identity] as `run.json` in [directory].
void writeRunRecord(String directory, Map<String, Object> identity) => File(
  p.join(directory, 'run.json'),
).writeAsStringSync('${jsonEncode(identity)}\n');

/// The `ctr-runtime-run.cfg` text for [identity].
String runConfig(Map<String, Object> identity) =>
    identity.entries.map((e) => '${e.key}=${e.value}\n').join();

/// Packages [build] for a manual SD-card run in [output]: `artifact.json`,
/// `run.json`, and `SDROOT/` holding the app with the SDK's notices under
/// `3ds/<name>/` and the schema-1 `ctr-runtime-run.cfg`.
///
/// Returns the new run identity.
Map<String, Object> packageCtrApplication(
  NativeSdk sdk,
  CtrBuild build,
  Directory output,
) {
  File(
    p.join(output.path, 'artifact.json'),
  ).writeAsStringSync('${jsonEncode(artifactRecord(build))}\n');
  final runId = newRunId();
  final identity = runIdentity(build, runId);
  final name = 'ctr-dart-${build.mode.name}-${runId.substring(0, 8)}';
  final destination = File(
    p.join(output.path, 'SDROOT/3ds', name, '$name.3dsx'),
  );
  destination.parent.createSync(recursive: true);
  destination.writeAsBytesSync(build.artifact);
  for (final relative in sdk.manifest.files.keys) {
    if (!relative.startsWith('notices/')) continue;
    final notice = File(p.join(destination.parent.path, relative));
    notice.parent.createSync(recursive: true);
    File(sdk.asset(relative)).copySync(notice.path);
  }
  writeRunRecord(output.path, identity);
  File(
    p.join(output.path, 'SDROOT/ctr-runtime-run.cfg'),
  ).writeAsStringSync(runConfig(identity));
  return identity;
}
