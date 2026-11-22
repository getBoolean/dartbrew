import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../process.dart';
import '../../sdk.dart';
import '../../stage_runner.dart';
import 'native_elf.dart';
import 'smdh.dart';

/// How the Dart program is carried in the application.
enum BuildMode {
  /// An AOT snapshot linked into the binary.
  aot,

  /// A kernel file run by the JIT VM.
  jit,
}

/// The longest fixture identity token the launcher's fixed fields hold.
const fixtureMaxLength = 64;

/// Identity tokens must match this; the launcher stores them in fixed fields.
final fixturePattern = RegExp('^[A-Za-z0-9_-]{1,$fixtureMaxLength}\$');

/// The fixture identity token for [entry] in [project]: the pubspec `name`,
/// or the entry file's base name when there is no pubspec name, reduced to
/// [fixturePattern].
String fixtureFor(String project, String entry) {
  var token = (_pubspecName(project) ?? p.basenameWithoutExtension(entry))
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  if (token.length > fixtureMaxLength) {
    token = token.substring(0, fixtureMaxLength);
  }
  return token.isEmpty ? 'app' : token;
}

/// The string `name` of [project]'s `pubspec.yaml`, or null when it has
/// none. A pubspec that is not valid YAML also gives null; the build's
/// `packages` stage reports it.
String? _pubspecName(String project) {
  final pubspec = File(p.join(project, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return null;
  try {
    return switch (loadYaml(pubspec.readAsStringSync())) {
      {'name': final String name} => name,
      _ => null,
    };
  } on YamlException {
    return null;
  }
}

/// The kernel compiler arguments that compile [entry] to [output] for
/// [mode], resolving packages with [packageConfig] when it exists.
List<String> kernelArguments(
  NativeSdk sdk, {
  required BuildMode mode,
  required File packageConfig,
  required String output,
  required String entry,
}) => [
  if (mode == BuildMode.aot) '--aot',
  '--platform=${sdk.asset(sdk.manifest.runtime.platform)}',
  if (packageConfig.existsSync()) '--packages=${packageConfig.path}',
  '--output=$output',
  entry,
];

/// The result of [buildCtrApplication].
final class CtrBuild {
  /// The written `.3dsx` file and its bytes.
  final File application;
  final Uint8List artifact;
  final BuildMode mode;
  final String fixture;
  final String compatibility;
  final String buildId;
  final String artifactSha256;
  final String payloadSha256;
  final String elfSha256;
  final String sdkManifestSha256;

  /// The runtime's `sdk_head` value from the SDK manifest.
  final String sdkHead;

  const CtrBuild({
    required this.application,
    required this.artifact,
    required this.mode,
    required this.fixture,
    required this.compatibility,
    required this.buildId,
    required this.artifactSha256,
    required this.payloadSha256,
    required this.elfSha256,
    required this.sdkManifestSha256,
    required this.sdkHead,
  });
}

String programAssembly(
  String mode,
  String fixture,
  String compatibility,
  String buildId,
  int kernelSize,
) {
  final payload = mode == 'aot'
      ? '_kDartSnapshotData, _kDartSnapshotText, 0, 0'
      : '0, 0, ctr_kernel, $kernelSize';
  final values = {
    'ctr_fixture': fixture,
    'ctr_mode': mode,
    'ctr_compatibility': compatibility,
    'ctr_build_id': buildId,
  };
  return '''.section .rodata.ctr_program,"a",%progbits
.balign 4
.global ctr_program
.type ctr_program,%object
ctr_program:
.word $payload
.word ctr_fixture, ctr_mode, ctr_compatibility, ctr_build_id
.size ctr_program, 32
${values.entries.map((e) => '${e.key}:\n.asciz ${jsonEncode(e.value)}').join('\n')}
.section .note.GNU-stack,"",%progbits
''';
}

/// Compiles [entry] in [project] into the CTR binary [application].
///
/// Runs the `packages` (only when the project has a `pubspec.yaml`),
/// `kernel`, `snapshot` (AOT only), `assemble-payload`, `assemble-program`
/// and `link` stages with the SDK's tools. Intermediate files, per-stage logs
/// and `commands.json` go into [work], which must already exist. A failed
/// stage throws a [StageFailure] and [application] is not written.
///
/// The application carries the project's title, description and icon (see
/// [readAppMetadata]); these are read before any stage runs, and metadata
/// warnings go to [warnings] (standard error by default).
///
/// [fixture] must match [fixturePattern]; see [fixtureFor].
Future<CtrBuild> buildCtrApplication({
  required NativeSdk sdk,
  required String project,
  required String entry,
  required BuildMode mode,
  required String fixture,
  required Directory work,
  required File application,
  bool offline = false,
  ProcessStarter start = startProcess,
  StringSink? warnings,
}) async {
  final smdh = projectSmdh(
    project,
    fallbackTitle: p.basenameWithoutExtension(entry),
    warnings: warnings ?? stderr,
  );
  final run = StageRunner(sdk, work, start: start);
  final aot = mode == BuildMode.aot;

  final packageConfig = File(p.join(project, '.dart_tool/package_config.json'));
  if (File(p.join(project, 'pubspec.yaml')).existsSync()) {
    await run(
      'dart',
      ['pub', 'get', if (offline) '--offline'],
      'packages',
      cwd: project,
    );
  }
  final kernel = p.join(work.path, 'application.dill');
  await run(
    'kernel',
    kernelArguments(
      sdk,
      mode: mode,
      packageConfig: packageConfig,
      output: kernel,
      entry: entry,
    ),
    'kernel',
  );
  final assembly = File(p.join(work.path, 'payload.S'));
  if (aot) {
    await run('snapshot', [
      '--snapshot_kind=app-aot-assembly',
      '--assembly=${assembly.path}',
      kernel,
    ], 'snapshot');
  } else {
    assembly.writeAsStringSync(
      '.section .rodata\n.balign 16\n.global ctr_kernel\nctr_kernel:\n'
      '.incbin "application.dill"\n.section .note.GNU-stack,"",%progbits\n',
    );
  }
  final runtime = sdk.manifest.runtime;
  final profile = switch (mode) {
    BuildMode.aot => runtime.aot,
    BuildMode.jit => runtime.jit,
  };
  final compatibility = profile.compatibility;
  final payloadHash = await fileDigest(File(aot ? assembly.path : kernel));
  final sdkHash = await fileDigest(File(p.join(sdk.root, 'sdk.json')));
  final buildId = sha256
      .convert(
        utf8.encode(jsonEncode([sdkHash, mode.name, fixture, payloadHash])),
      )
      .toString();
  final program = File(p.join(work.path, 'program.S'))
    ..writeAsStringSync(
      programAssembly(
        mode.name,
        fixture,
        compatibility,
        buildId,
        File(kernel).lengthSync(),
      ),
    );
  for (final source in [assembly, program]) {
    await run('as', [
      '-march=armv6k',
      '-mfpu=vfp',
      '-mfloat-abi=hard',
      source.path,
      '-o',
      p.setExtension(source.path, '.o'),
    ], 'assemble-${p.basenameWithoutExtension(source.path)}');
  }
  final link = runtime.link;
  final elf = File(p.join(work.path, 'application.elf'));
  await run('ld', [
    '--defsym=__sync_synchronize=__sync_synchronize_cp15dmb',
    '-X',
    '-T',
    sdk.asset(link.layout),
    '-d',
    '--emit-relocs',
    '--use-blx',
    '--gc-sections',
    '-u',
    '__sync_synchronize_cp15dmb',
    '-Map=${p.join(work.path, 'link.map')}',
    '-o',
    elf.path,
    ...link.startup.map(sdk.asset),
    ...profile.objects.map(sdk.asset),
    p.join(work.path, 'program.o'),
    p.join(work.path, 'payload.o'),
    sdk.asset(link.math),
    // The SDK's dart:io layer for CTR: the launcher calls into it, and it
    // calls the VM in the runtime archive.
    sdk.asset(profile.ioArchive),
    sdk.asset(profile.archive),
    ...link.libraries.map(sdk.asset),
    '--start-group',
    ...link.grouped.map(sdk.asset),
    '--end-group',
    ...link.end.map(sdk.asset),
  ], 'link');
  final artifact = encode3dsx(elf.readAsBytesSync(), smdh: smdh);
  application.writeAsBytesSync(artifact);
  return CtrBuild(
    application: application,
    artifact: artifact,
    mode: mode,
    fixture: fixture,
    compatibility: compatibility,
    buildId: buildId,
    artifactSha256: sha256.convert(artifact).toString(),
    payloadSha256: payloadHash,
    elfSha256: await fileDigest(elf),
    sdkManifestSha256: sdkHash,
    sdkHead: runtime.sdkHead,
  );
}
