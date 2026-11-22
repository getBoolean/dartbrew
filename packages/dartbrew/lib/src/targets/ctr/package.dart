import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../device/run_identity.dart';
import '../../sdk.dart';
import 'pipeline.dart';

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

/// Packages [build] for a manual SD-card run in [output]: `artifact.json`,
/// `run.json`, and `SDROOT/` holding the app with the SDK's notices under
/// `3ds/<name>/` and the schema-1 `ctr-runtime-run.cfg`.
void packageCtrApplication(NativeSdk sdk, CtrBuild build, Directory output) {
  File(
    p.join(output.path, 'artifact.json'),
  ).writeAsStringSync('${jsonEncode(artifactRecord(build))}\n');
  final identity = RunIdentity.ofBuild(
    build,
    schema: 1,
    environment: RunEnvironment.hardware,
  );
  final name = 'ctr-dart-${build.mode.name}-${identity.runId.substring(0, 8)}';
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
  identity.writeRunRecord(output.path);
  File(
    p.join(output.path, 'SDROOT/ctr-runtime-run.cfg'),
  ).writeAsStringSync(identity.runConfig());
}
