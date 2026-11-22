import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'host.dart';

/// The GN target that builds the host-side CTR precompiler.
const precompilerRootTarget = '//runtime/bin:gen_snapshot';

/// Compiler definitions that prove `gen_snapshot` targets the CTR ARM backend.
const requiredCompilerDefines = {
  'DART_TARGET_OS_CTR',
  'TARGET_ARCH_ARM',
  'DART_TARGET_ARMV6K',
};

/// The largest ninja job count accepted; output was byte-identical from `-j2`
/// through `-j16`, so the bound only rejects typos.
const maxPrecompilerJobs = 8;

/// Runs one named build stage, with the contract of [StageRunner.call]: the
/// stage's combined output lands in `<work>/<stage>.log`, and a non-zero exit
/// throws.
typedef RunStage =
    Future<void> Function(
      String executable,
      List<String> arguments,
      String stage, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// A precompiler build that cannot continue; [message] names what failed.
final class PrecompilerFailure implements Exception {
  final String message;

  const PrecompilerFailure(this.message);

  @override
  String toString() => message;
}

/// What to build the precompiler from and where to put it.
final class PrecompilerRequest {
  final Host host;

  /// This repository, which holds `toolchain/` and `release/`.
  final Directory repository;

  /// The patched Dart SDK checkout that `bootstrap.py` materialized.
  final Directory source;

  final Directory depotTools;

  /// Holds the stage logs, `commands.json` and the GN output directory.
  final Directory work;

  /// Must not exist; receives `gen_snapshot`, `ctr-kernel`, `host-dart` and
  /// `native-precompiler.json`.
  final Directory output;

  /// The pin table, `toolchain/versions.json`.
  final File manifest;

  /// The Python interpreter that runs `bootstrap.py`.
  final String python;

  final int jobs;

  const PrecompilerRequest({
    required this.host,
    required this.repository,
    required this.source,
    required this.depotTools,
    required this.work,
    required this.output,
    required this.manifest,
    required this.python,
    required this.jobs,
  });
}

/// The GN arguments of [host]'s native precompiler graph.
Map<String, Object> precompilerGnArguments(Host host) => {
  'target_os': 'ctr',
  'target_cpu': host.architecture.name,
  'current_os': _buildtoolsOs(host),
  'current_cpu': host.architecture.name,
  'dart_target_arch': 'arm',
  'dart_armv6k': true,
  'dart_use_compressed_pointers': false,
  'dart_use_crashpad': false,
  'dart_support_perfetto': false,
  'is_clang': true,
  'is_debug': false,
  'is_release': true,
  // The SDK's relative-sysroot helper assumes an in-source output folder.
  // Producer graphs are out of tree; select the actual Xcode SDK instead.
  if (host.os == HostOs.macos) 'mac_enable_relative_sdk_path': false,
};

/// The SDK's name for [host]'s operating system, in GN and `buildtools/`.
String _buildtoolsOs(Host host) => switch (host.os) {
  HostOs.windows => 'win',
  HostOs.macos => 'mac',
  HostOs.linux => 'linux',
};

/// The snapshot and git hashes in a generated `version.cc`, checked against
/// the patched checkout's [sourceHead].
///
/// Throws [PrecompilerFailure] when either hash is missing or ambiguous, or
/// the git hash is not [sourceHead]'s.
Map<String, String> generatedIdentity(String versionSource, String sourceHead) {
  final identity = {
    for (final (name, field, length) in const [
      ('snapshot_hash_', 'snapshot_hash', 32),
      ('git_short_hash_', 'git_short_hash', 10),
    ])
      field: () {
        final values = RegExp(
          'Version::$name\\s*=\\s*"([0-9a-f]+)";',
        ).allMatches(versionSource).map((match) => match[1]!).toList();
        if (values.length != 1 || values.single.length != length) {
          throw PrecompilerFailure('missing or ambiguous generated $field');
        }
        return values.single;
      }(),
  };
  if (identity['git_short_hash'] != sourceHead.substring(0, 10)) {
    throw const PrecompilerFailure(
      'generated SDK hash does not match patched source HEAD',
    );
  }
  return identity;
}

/// The sorted [requiredCompilerDefines], after checking that `gn desc
/// defines` output [definitions] contains all of them.
List<String> verifyCompilerDefines(String definitions) {
  final present = definitions.split(RegExp(r'\s+')).toSet();
  final missing = requiredCompilerDefines.difference(present).toList()..sort();
  if (missing.isNotEmpty) {
    throw PrecompilerFailure(
      'gen_snapshot missing CTR compiler definitions: $missing',
    );
  }
  return requiredCompilerDefines.toList()..sort();
}

/// The environment that puts [depotTools] first on `PATH` and keeps
/// depot_tools from updating itself, reporting metrics, fetching Google's
/// Windows toolchain or converting line endings.
Map<String, String> depotToolsEnvironment(
  String depotTools,
  Map<String, String> parent,
) {
  final pathKey = parent.keys.firstWhere(
    (key) => key.toUpperCase() == 'PATH',
    orElse: () => 'PATH',
  );
  final count = int.parse(parent['GIT_CONFIG_COUNT'] ?? '0');
  return {
    ...parent,
    pathKey: [
      depotTools,
      ?parent[pathKey],
    ].join(Platform.isWindows ? ';' : ':'),
    'DEPOT_TOOLS_UPDATE': '0',
    'DEPOT_TOOLS_METRICS': '0',
    'DEPOT_TOOLS_WIN_TOOLCHAIN': '0',
    'GIT_CONFIG_COUNT': '${count + 1}',
    'GIT_CONFIG_KEY_$count': 'core.autocrlf',
    'GIT_CONFIG_VALUE_$count': 'false',
  };
}

/// Adds the producer-only stable `qsort` and the CTR activation-frame
/// alignment to [source] while [build] runs, then restores [source].
///
/// [build] receives the overlay's receipt. Throws [PrecompilerFailure] before
/// changing anything when the helper already exists or the anchors differ
/// from the pinned SDK. When an overlaid file changed during [build], every
/// file is left as it is for inspection and [PrecompilerFailure] is thrown.
Future<T> withProducerOverlay<T>(
  Directory source,
  File stableSort,
  Future<T> Function(Map<String, Object?> receipt) build,
) async {
  final graph = File(p.join(source.path, 'runtime', 'bin', 'BUILD.gn'));
  final osSource = File(p.join(source.path, 'runtime', 'vm', 'os_macos.cc'));
  final helper = File(
    p.join(source.path, 'runtime', 'bin', 'ctr_stable_sort.c'),
  );
  if (helper.existsSync()) {
    throw const PrecompilerFailure(
      'producer helper already exists; preserve the checkout',
    );
  }
  // Latin-1 maps bytes to characters one to one, so edits keep every byte.
  final original = {
    graph: latin1.decode(graph.readAsBytesSync()),
    osSource: latin1.decode(osSource.readAsBytesSync()),
  };
  const graphAnchor = '      "gen_snapshot.cc",\n';
  const osAnchor = 'intptr_t OS::ActivationFrameAlignment() {\n';
  const osEnd =
      '#endif  // DART_HOST_OS_IOS\n}\n\nuintptr_t OS::CurrentRSS() {';
  int count(String text, String anchor) => anchor.allMatches(text).length;
  if (count(original[graph]!, graphAnchor) != 1 ||
      count(original[osSource]!, osAnchor) != 1 ||
      count(original[osSource]!, osEnd) != 1) {
    throw const PrecompilerFailure(
      'producer overlay source anchors differ from the pinned SDK',
    );
  }
  final changed = {
    graph: latin1.encode(
      original[graph]!.replaceFirst(
        graphAnchor,
        '$graphAnchor      "ctr_stable_sort.c",\n',
      ),
    ),
    osSource: latin1.encode(
      original[osSource]!
          .replaceFirst(
            osAnchor,
            '$osAnchor#if defined(DART_TARGET_OS_CTR)\n  return 8;\n#else\n',
          )
          .replaceFirst(
            osEnd,
            '#endif  // DART_HOST_OS_IOS\n#endif  // DART_TARGET_OS_CTR\n}\n\n'
            'uintptr_t OS::CurrentRSS() {',
          ),
    ),
    helper: stableSort.readAsBytesSync(),
  };
  final receipt = <String, Object?>{
    'kind': 'native-sort-and-target-alignment-v1',
    'files': {
      for (final MapEntry(key: file, value: content) in changed.entries)
        p.relative(file.path, from: source.path).replaceAll(r'\', '/'): {
          'base_sha256': switch (original[file]) {
            final text? => sha256.convert(latin1.encode(text)).toString(),
            null => null,
          },
          'compiler_sha256': sha256.convert(content).toString(),
        },
    },
  };
  try {
    for (final MapEntry(key: file, value: content) in changed.entries) {
      if (file == helper) file.createSync(exclusive: true);
      file.writeAsBytesSync(content);
    }
    return await build(receipt);
  } finally {
    final isIntact = changed.entries.every(
      (entry) =>
          entry.key.existsSync() &&
          _sameBytes(entry.key.readAsBytesSync(), entry.value),
    );
    if (!isIntact) {
      // Throwing from finally replaces any build error: the changed sources
      // are the more urgent problem.
      // ignore: control_flow_in_finally
      throw const PrecompilerFailure(
        'producer overlay files changed; preserved all sources for inspection',
      );
    }
    for (final MapEntry(key: file, value: text) in original.entries) {
      file.writeAsBytesSync(latin1.encode(text));
    }
    helper.deleteSync();
  }
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Builds `gen_snapshot`, `ctr-kernel` and the host Dart for
/// [PrecompilerRequest.host] into [PrecompilerRequest.output], and returns the
/// receipt it writes there as `native-precompiler.json`.
///
/// The checkout is verified with `bootstrap.py verify` before GN runs and
/// again after the build. Throws [PrecompilerFailure] or the [run] failure of
/// the stage that failed; the output directory is created only after the
/// precompiler built and answered `--version`.
Future<Map<String, Object?>> buildPrecompiler(
  PrecompilerRequest request, {
  required RunStage run,
}) async {
  final PrecompilerRequest(:host, :source, :work, :output) = request;
  if (request.jobs < 1 || request.jobs > maxPrecompilerJobs) {
    throw const PrecompilerFailure(
      'producer jobs must be between 1 and $maxPrecompilerJobs',
    );
  }
  if (output.existsSync()) {
    throw PrecompilerFailure(
      'output already exists: ${output.path}; choose an absent directory',
    );
  }
  final manifest =
      jsonDecode(await request.manifest.readAsString()) as Map<String, Object?>;
  final dependencies = manifest['dependencies'] as Map<String, Object?>;
  final environment = depotToolsEnvironment(
    request.depotTools.path,
    Platform.environment,
  );
  String stageOutput(String stage) =>
      File(p.join(work.path, '$stage.log')).readAsStringSync().trim();

  Future<Map<String, Object?>> verifyCheckout(String stage) async {
    await run(
      request.python,
      [
        p.join(request.repository.path, 'toolchain', 'bootstrap.py'),
        'verify',
        '--source',
        source.path,
        '--manifest',
        request.manifest.path,
      ],
      stage,
      environment: environment,
    );
    // The log holds stderr too; the source state is the one JSON line.
    final state = const LineSplitter()
        .convert(stageOutput(stage))
        .lastWhere(
          (line) => line.startsWith('{'),
          orElse: () => throw PrecompilerFailure(
            'bootstrap.py verify printed no source state; see $stage.log',
          ),
        );
    return jsonDecode(state) as Map<String, Object?>;
  }

  final sourceState = await verifyCheckout('verify-checkout');
  final icuState = dependencies.containsKey('icu')
      ? jsonDecode(
          File(
            p.join(
              source.path,
              'third_party',
              'icu',
              '.git',
              'ctr-source.json',
            ),
          ).readAsStringSync(),
        )
      : null;

  final gnPin = _gnPin(dependencies, host);
  final gn = p.join(source.path, 'buildtools', 'gn${host.executableSuffix}');
  if (!File(gn).existsSync()) {
    throw PrecompilerFailure(
      'GN is missing: $gn; run toolchain/bootstrap.py --fetch-gn',
    );
  }
  if (_fileHash(gn) != gnPin['binary_sha256']) {
    throw PrecompilerFailure(
      'GN hash mismatch: $gn; run toolchain/bootstrap.py --fetch-gn',
    );
  }

  final buildDirectory = Directory(p.join(work.path, 'native-build'));
  final gnArguments = precompilerGnArguments(host);
  final argumentsText = [
    for (final key in gnArguments.keys.toList()..sort())
      '$key = ${jsonEncode(gnArguments[key])}\n',
  ].join();
  buildDirectory.createSync(recursive: true);
  final argumentsFile = File(p.join(buildDirectory.path, 'args.gn'));
  if (argumentsFile.existsSync() &&
      argumentsFile.readAsStringSync() != argumentsText) {
    throw const PrecompilerFailure(
      'existing native build arguments differ; choose a fresh work directory',
    );
  }
  argumentsFile.writeAsStringSync(argumentsText);

  final ninja = p.join(
    source.path,
    'buildtools',
    'ninja',
    'ninja${host.executableSuffix}',
  );
  final clang = p.join(
    source.path,
    'buildtools',
    '${_buildtoolsOs(host)}-${host.architecture.name}',
    'clang',
    'bin',
    host.os == HostOs.windows ? 'clang-cl.exe' : 'clang',
  );
  await run(clang, ['--version'], 'clang-version', environment: environment);
  await run(ninja, ['--version'], 'ninja-version', environment: environment);

  final (overlay, defines) = await withProducerOverlay(
    source,
    File(p.join(request.repository.path, 'release', 'native_stable_sort.c')),
    (overlay) async {
      await run(
        gn,
        [
          'gen',
          buildDirectory.path,
          '--fail-on-unused-args',
          '--root-target=$precompilerRootTarget',
        ],
        'gn-gen',
        workingDirectory: source.path,
        environment: environment,
      );
      await run(
        gn,
        ['desc', buildDirectory.path, precompilerRootTarget, 'defines'],
        'gn-defines',
        workingDirectory: source.path,
        environment: environment,
      );
      final defines = verifyCompilerDefines(stageOutput('gn-defines'));
      await run(
        ninja,
        ['-C', buildDirectory.path, '-j', '${request.jobs}', 'gen_snapshot'],
        'ninja',
        workingDirectory: source.path,
        environment: environment,
      );
      return (overlay, defines);
    },
  );

  final versionSources = buildDirectory
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (file) =>
            file.path.replaceAll(r'\', '/').endsWith('/gen/runtime/version.cc'),
      )
      .toList();
  if (versionSources.length != 1) {
    throw PrecompilerFailure(
      'expected one generated version.cc, found ${versionSources.length}',
    );
  }
  final identity = generatedIdentity(
    versionSources.single.readAsStringSync(),
    sourceState['head'] as String,
  );
  final executableName = 'gen_snapshot${host.executableSuffix}';
  final executable = p.join(buildDirectory.path, executableName);
  await run(
    executable,
    ['--version'],
    'gen-snapshot-version',
    environment: environment,
  );
  await verifyCheckout('reverify-checkout');

  final hostSdk = p.join(source.path, 'tools', 'sdks', 'dart-sdk');
  final dart = p.join(hostSdk, 'bin', 'dart${host.executableSuffix}');
  final driver = p.join(
    request.repository.path,
    'toolchain',
    'native_kernel.dart',
  );
  output.createSync(recursive: true);
  File(executable).copySync(p.join(output.path, executableName));
  final kernelCompilerName = 'ctr-kernel${host.executableSuffix}';
  final kernelCompiler = p.join(output.path, kernelCompilerName);
  await run(
    dart,
    [
      'compile',
      'exe',
      '--packages=${p.join(source.path, '.dart_tool', 'package_config.json')}',
      driver,
      '-o',
      kernelCompiler,
    ],
    'ctr-kernel',
    workingDirectory: source.path,
    environment: environment,
  );
  final hostDart = Directory(p.join(output.path, 'host-dart'));
  _copyDirectory(Directory(hostSdk), hostDart);

  final receipt = <String, Object?>{
    'schema_version': 1,
    'component': 'native-ctr-gen-snapshot',
    'host': host.id,
    'target': 'ctr-armv6k',
    'source': sourceState,
    'icu': icuState,
    'manifest': manifest,
    'producer_overlay': overlay,
    'gn_args': gnArguments,
    'root_target': precompilerRootTarget,
    'compiler_defines': defines,
    'generated': identity,
    'gn': gnPin,
    'compiler': {
      'pin': dependencies['clang'],
      'sha256': _fileHash(clang),
      'version': stageOutput('clang-version'),
    },
    'ninja': {
      'pin': dependencies['ninja'],
      'sha256': _fileHash(ninja),
      'version': stageOutput('ninja-version'),
    },
    'executable': {
      'path': executableName,
      'sha256': _fileHash(executable),
      'version': stageOutput('gen-snapshot-version'),
    },
    'qualification':
        'native --version only; target snapshot execution requires SDK '
        'integration',
    'kernel_compiler': {
      'path': kernelCompilerName,
      'sha256': _fileHash(kernelCompiler),
      'driver_sha256': _fileHash(driver),
      'host_dart_sha256': _fileHash(dart),
    },
    'host_dart': _hostDartRecord(Directory(hostSdk)),
  };
  File(p.join(output.path, 'native-precompiler.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
  );
  return receipt;
}

/// [host]'s pinned GN package, with the table's shared revision.
Map<String, Object?> _gnPin(Map<String, Object?> dependencies, Host host) {
  final pins = dependencies['gn'] as Map<String, Object?>;
  final hosts = pins['hosts'] as Map<String, Object?>;
  final hostPin = hosts[host.id] as Map<String, Object?>?;
  if (hostPin == null) {
    throw PrecompilerFailure('no pinned GN for host ${host.id}');
  }
  return {'revision': pins['revision'], ...hostPin};
}

/// Every file under [sdk], by its `/`-separated relative path, with its hash
/// and whether it is executable.
Map<String, Object?> _hostDartRecord(Directory sdk) {
  final files = sdk.listSync(recursive: true).whereType<File>().toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  return {
    for (final file in files)
      p.relative(file.path, from: sdk.path).replaceAll(r'\', '/'): {
        'sha256': _fileHash(file.path),
        'executable': file.statSync().mode & 0x49 != 0,
      },
  };
}

void _copyDirectory(Directory from, Directory to) {
  for (final entity in from.listSync(recursive: true)) {
    final target = p.join(to.path, p.relative(entity.path, from: from.path));
    switch (entity) {
      case Directory():
        Directory(target).createSync(recursive: true);
      case File():
        Directory(p.dirname(target)).createSync(recursive: true);
        entity.copySync(target);
      case _:
        throw PrecompilerFailure('unexpected link in host SDK: ${entity.path}');
    }
  }
}

String _fileHash(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();
