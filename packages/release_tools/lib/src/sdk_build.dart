import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'build_identity.dart';
import 'host.dart';

/// The interpreter `toolchain/bootstrap.py` runs with in the container.
const _python = 'python3';

/// Runs one named build stage, as `StageRunner.call` does.
typedef RunStage =
    Future<void> Function(
      String executable,
      List<String> arguments,
      String stage, {
      String? workingDirectory,
    });

/// The devkitARM and libctru versions a toolchain contains.
typedef ToolchainVersions = ({String gcc, String devkitArm, String libctru});

/// Reports the versions installed for [profile]'s compiler.
typedef QueryToolchain =
    Future<ToolchainVersions> Function(TargetProfile profile);

/// A build that cannot run in this checkout or container; [message] names
/// what differs and what to do.
final class SdkBuildFailure implements Exception {
  final String message;

  const SdkBuildFailure(this.message);

  @override
  String toString() => message;
}

/// How far [buildSdk] goes.
enum SdkBuildScope {
  /// Write `args.gn` and generate the Ninja files.
  configure,

  /// Configure, then build the targets with Ninja.
  build,
}

/// One component build of the patched SDK checkout at [source].
final class SdkBuildRequest {
  final String source;
  final File manifestFile;
  final Map<String, Object?> manifest;
  final TargetProfile profile;
  final BuildIdentity identity;

  /// `toolchain/bootstrap.py`, whose `verify` checks [source] against the pins.
  final File bootstrapScript;
  final String outputRoot;
  final SdkBuildScope scope;

  /// Ninja targets; empty builds the identity's root target.
  final List<String> targets;
  final int jobs;

  /// Also run upstream GN include ownership checks.
  final bool checkIncludes;

  const SdkBuildRequest({
    required this.source,
    required this.manifestFile,
    required this.manifest,
    required this.profile,
    required this.identity,
    required this.bootstrapScript,
    required this.outputRoot,
    required this.scope,
    this.targets = const [],
    this.jobs = 2,
    this.checkIncludes = false,
  });

  /// `<outputRoot>/<component>-<mode>-<first 16 of the cache key>`.
  Directory get outputDirectory => Directory(
    p.join(
      outputRoot,
      '${identity.component.name}-${identity.mode.name}-'
      '${identity.cacheKey.substring(0, 16)}',
    ),
  );
}

/// Verifies the checkout and container toolchain, writes `args.gn` and
/// `compatibility.json`, and runs GN (and Ninja for [SdkBuildScope.build])
/// through [runStage]. Returns the output directory.
///
/// Throws an [SdkBuildFailure] before GN runs when the container's
/// toolchain differs from the pin table or GN is not the pinned binary.
Future<Directory> buildSdk(
  SdkBuildRequest request, {
  required RunStage runStage,
  required QueryToolchain queryToolchain,
}) async {
  final output = request.outputDirectory..createSync(recursive: true);
  await runStage(_python, [
    request.bootstrapScript.path,
    'verify',
    '--manifest',
    request.manifestFile.path,
    '--source',
    request.source,
  ], 'verify');
  final mismatches = toolchainMismatches(
    pinned: pinnedToolchain(request.manifest),
    installed: await queryToolchain(request.profile),
  );
  if (mismatches.isNotEmpty) {
    throw SdkBuildFailure(
      'container toolchain differs from toolchain/versions.json: '
      '${mismatches.join('; ')}; use the pinned devkitpro/devkitarm image',
    );
  }
  final gn = File(p.join(request.source, 'buildtools', 'gn'));
  _checkPinnedGn(gn, request.manifest);

  File(
    p.join(output.path, 'args.gn'),
  ).writeAsStringSync(gnArgsFile(request.identity, request.profile));
  File(p.join(output.path, 'compatibility.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(request.identity.toJson())}\n',
  );
  final rootTarget = request.identity.rootTarget;
  await runStage(
    gn.path,
    [
      'gen',
      output.path,
      if (request.checkIncludes) '--check',
      '--fail-on-unused-args',
      '--root-target=$rootTarget',
    ],
    'gn',
    workingDirectory: request.source,
  );
  if (request.scope == SdkBuildScope.configure) return output;
  final targets = request.targets.isNotEmpty
      ? request.targets
      : [rootTarget.replaceFirst('//', '').replaceFirst(RegExp('^:'), '')];
  await runStage(
    p.join(request.source, 'buildtools', 'ninja', 'ninja'),
    ['-j', '${request.jobs}', '-C', output.path, ...targets],
    'ninja',
    workingDirectory: request.source,
  );
  return output;
}

/// The `args.gn` for [identity]: its GN arguments in key order, then, for
/// CTR components, the profile's compiler prefix, libctru, cflags and specs.
String gnArgsFile(BuildIdentity identity, TargetProfile profile) {
  final arguments = <String, Object>{
    for (final key in identity.gnArgs.keys.toList()..sort())
      key: identity.gnArgs[key]!,
    if (identity.component != SdkComponent.host) ...{
      'ctr_compiler_prefix': profile.compilerPrefix,
      'ctr_libctru': profile.libctru,
      'ctr_cflags': profile.cflags,
      'ctr_specs_file': profile.linkSpecs.absolutePath,
    },
  };
  return [
    for (final MapEntry(:key, :value) in arguments.entries)
      '$key = ${jsonEncode(value)}\n',
  ].join();
}

/// The toolchain versions the `container` entry of [manifest] pins.
ToolchainVersions pinnedToolchain(Map<String, Object?> manifest) {
  final container = manifest['container']! as Map<String, Object?>;
  return (
    gcc: container['gcc']! as String,
    devkitArm: container['devkitARM']! as String,
    libctru: container['libctru']! as String,
  );
}

/// Every way [installed] differs from [pinned], naming both versions; empty
/// when they match.
List<String> toolchainMismatches({
  required ToolchainVersions pinned,
  required ToolchainVersions installed,
}) => [
  for (final (name, expected, actual) in [
    ('gcc', pinned.gcc, installed.gcc),
    ('devkitARM', pinned.devkitArm, installed.devkitArm),
    ('libctru', pinned.libctru, installed.libctru),
  ])
    if (expected != actual) '$name is $actual, pinned $expected',
];

/// Asks [profile]'s gcc for its version and `dkp-pacman` for the installed
/// devkitARM and libctru packages.
Future<ToolchainVersions> queryInstalledToolchain(TargetProfile profile) async {
  final gcc = await _output('${profile.compilerPrefix}gcc', [
    '-dumpfullversion',
  ]);
  final packages = {
    for (final line in LineSplitter.split(await _output('dkp-pacman', ['-Q'])))
      if (line.split(' ') case [final name, final version]) name: version,
  };
  return (
    gcc: gcc,
    devkitArm: packages['devkitARM'] ?? 'not installed',
    libctru: packages['libctru'] ?? 'not installed',
  );
}

Future<String> _output(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw SdkBuildFailure(
      '$executable ${arguments.join(' ')} failed (${result.exitCode}): '
      '${result.stderr}',
    );
  }
  return (result.stdout as String).trim();
}

void _checkPinnedGn(File gn, Map<String, Object?> manifest) {
  if (!gn.existsSync()) {
    throw SdkBuildFailure(
      'pinned GN unavailable: ${gn.path}; bootstrap with --sync-deps first',
    );
  }
  final gnPins =
      (manifest['dependencies']! as Map<String, Object?>)['gn']!
          as Map<String, Object?>;
  final pin =
      (gnPins['hosts']! as Map<String, Object?>)[Host.linuxX64.id]!
          as Map<String, Object?>;
  if (sha256.convert(gn.readAsBytesSync()).toString() != pin['binary_sha256']) {
    throw SdkBuildFailure(
      'GN hash mismatch: ${gn.path}; restore the pinned dependency',
    );
  }
}
