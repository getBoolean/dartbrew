import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartbrew/native_build.dart';
import 'package:path/path.dart' as p;

import 'build_identity.dart';
import 'compile_plan.dart';
import 'precompiler.dart';
import 'sdk_build.dart';
import 'stage_runner.dart';

/// Collects the source and header closure from both configured target graphs.
/// The returned document is the runtime record; probe data is producer-only.
Future<Map<String, Object?>> buildRuntime({
  required Directory repository,
  required Directory source,
  required Directory buildRoot,
  required Directory output,
  required File genSnapshot,
  int jobs = 3,
}) async {
  if (FileSystemEntity.typeSync(output.path) != FileSystemEntityType.notFound) {
    throw FileSystemException('Output already exists', output.path);
  }
  if (jobs < 1) throw ArgumentError.value(jobs, 'jobs', 'must be positive');
  final manifestFile = File(
    p.join(repository.path, 'toolchain', 'versions.json'),
  );
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
  final profile = TargetProfile.load(
    File(p.join(repository.path, 'toolchain', 'target-ctr.json')),
  );
  final install = await DevkitPro.discover(
    environment: {
      'DEVKITPRO': p.dirname(profile.libctru),
      'DEVKITARM': p.dirname(p.dirname(profile.compilerPrefix)),
    },
  );
  final versions = (
    gcc: (await _output(install.tool('gcc'), ['-dumpfullversion'])).trim(),
    devkitArm: install.versions.devkitARM,
    libctru: install.versions.libctru,
  );
  final mismatches = toolchainMismatches(
    pinned: pinnedToolchain(manifest),
    installed: versions,
  );
  if (mismatches.isNotEmpty) throw SdkBuildFailure(mismatches.join('; '));
  final sourcePath = source.resolveSymbolicLinksSync();
  Future<String> verifiedHead() async {
    final verified = await _output('python3', [
      p.join(repository.path, 'toolchain/bootstrap.py'),
      'verify',
      '--source',
      sourcePath,
      '--manifest',
      manifestFile.absolute.path,
    ]);
    return (jsonDecode(
              const LineSplitter()
                  .convert(verified)
                  .lastWhere((l) => l.startsWith('{')),
            )
            as Map<String, Object?>)['head']!
        as String;
  }

  final head = await verifiedHead();
  output.parent.createSync(recursive: true);
  final work = await output.parent.createTemp('runtime-build-');
  final bundle = Directory(p.join(work.path, 'component'))..createSync();
  final run = StageRunner(work);
  final units = <String, List<Map<String, Object>>>{};
  final modes = <String, Map<String, String>>{};
  final files = <String, File>{};
  final licenses = <String>{};
  final tools = p.join(repository.path, 'toolchain');
  final dart = p.join(sourcePath, 'tools/sdks/dart-sdk/bin/dart');
  final snapshotHashes = <String>{};
  try {
    for (final mode in BuildMode.values) {
      final identity = BuildIdentity.of(
        manifest: manifest,
        profile: profile,
        component: SdkComponent.target,
        mode: mode,
      );
      final build = p.join(
        buildRoot.path,
        'target-${mode.name}-${identity.cacheKey.substring(0, 16)}',
      );
      final existing = File(p.join(build, 'compatibility.json'));
      if (!existing.existsSync() ||
          jsonEncode(jsonDecode(existing.readAsStringSync())) !=
              jsonEncode(identity.toJson())) {
        throw SdkBuildFailure(
          'Build current ${mode.name} target with build_sdk before producing the runtime: $build',
        );
      }
      final version = generatedIdentity(
        File(p.join(build, 'gen/runtime/version.cc')).readAsStringSync(),
        head,
      );
      snapshotHashes.add(version['snapshot_hash']!);
      modes[mode.name] = {'compatibility': identity.cacheKey};
      final captured = await captureCompilePlan(
        sourcePath: sourcePath,
        build: build,
        mode: mode,
        profile: profile,
        repository: repository,
        run: _output,
      );
      units[mode.name] = captured.units;
      files.addAll(captured.files);
    }
    if (snapshotHashes.length != 1) {
      throw const FormatException(
        'Runtime snapshot hashes differ between modes',
      );
    }
    final shipped = <String, String>{};
    Future<void> copy(File file, String relative) async {
      final dest = File(p.join(bundle.path, relative));
      await dest.parent.create(recursive: true);
      await file.copy(dest.path);
      shipped[relative] = await _digest(dest);
    }

    for (final name in files.keys.toList()..sort()) {
      await copy(files[name]!, 'native-src/$name');
      final segments = p.split(name);
      if (segments.length > 3 &&
          segments[0] == 'sdk' &&
          segments[1] == 'third_party') {
        licenses.add(segments[2]);
      }
    }
    for (final name in licenses.toList()..sort()) {
      await copy(
        File(p.join(sourcePath, 'third_party', name, 'LICENSE')),
        'source-notices/$name.LICENSE',
      );
    }
    await copy(
      File(p.join(sourcePath, 'LICENSE')),
      'source-notices/dart.LICENSE',
    );
    await copy(
      File(p.join(repository.path, 'LICENSE')),
      'source-notices/dartbrew.LICENSE',
    );
    final compilePlan = File(p.join(bundle.path, 'compile-plan.json'));
    compilePlan.writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'cflags': profile.cflags,
        'soft_math_source': 'toolchain/soft_math_bridge.cc',
        'modes': units,
      }),
    );
    shipped['compile-plan.json'] = await _digest(compilePlan);
    // The front end writes a host-specific dependency sidecar beside its output.
    final platform = File(p.join(work.path, 'platform.dill'));
    final packages =
        '--packages=${p.join(sourcePath, '.dart_tool/package_config.json')}';
    await run.call(dart, [
      p.join(sourcePath, 'pkg/front_end/tool/compile_platform.dart'),
      '--target=vm',
      '--sdk=${p.join(sourcePath, 'sdk')}',
      '-Ddart.vm.product=false',
      '-Ddart.isVM=true',
      'dart:core,dart:io,dart:_ctr',
      p.join(sourcePath, 'sdk/lib/_internal/ctr/platform.json'),
      p.join(
        sourcePath,
        'tools/sdks/dart-sdk/lib/_internal/vm_platform_strong.dill',
      ),
      platform.path,
      p.join(work.path, 'outline.dill'),
    ], 'platform');
    await run.call(dart, [
      packages,
      p.join(repository.path, 'runtime/ctr/test/check_retention.dart'),
      platform.path,
    ], 'retention');
    await copy(platform, 'platform.dill');
    final record = {
      'schema': 1,
      'sdk_head': head,
      'snapshot_hash': snapshotHashes.single,
      'platform': 'platform.dill',
      'devkitpro': {
        'devkitARM': versions.devkitArm,
        'libctru': versions.libctru,
      },
      'compile_plan': 'compile-plan.json',
      'native_src': 'native-src',
      'modes': modes,
      'link_template': ctrLinkTemplate,
      'files': shipped,
    };
    File(
      p.join(bundle.path, 'runtime.json'),
    ).writeAsStringSync(jsonEncode(record));
    final probe = File(p.join(work.path, 'probe.dill'));
    final assembly = File(p.join(work.path, 'reference.S'));
    await run.call(dart, [
      packages,
      p.join(tools, 'native_kernel.dart'),
      '--aot',
      '--platform=${platform.path}',
      '--output=${probe.path}',
      p.join(repository.path, 'test/programs/hello.dart'),
    ], 'probe-kernel');
    await run.call(genSnapshot.path, [
      '--snapshot_kind=app-aot-assembly',
      '--assembly=${assembly.path}',
      probe.path,
    ], 'probe-snapshot');
    final proof = await _proveBundle(
      work: work,
      repository: repository,
      bundle: bundle,
      shipped: shipped,
      modes: modes,
      install: install,
      run: run,
      assembly: assembly,
      jobs: jobs,
      cflags: profile.cflags,
    );
    await probe.copy(p.join(bundle.path, 'probe.dill'));
    File(p.join(bundle.path, 'probe.json')).writeAsStringSync(
      jsonEncode({
        'kernel': 'probe.dill',
        'kernel_sha256': await _digest(probe),
        'assembly_sha256': await _digest(assembly),
        'reference_precompiler_sha256': await _digest(genSnapshot),
        'native_build': proof,
      }),
    );
    if (await verifiedHead() != head) {
      throw const FormatException(
        'Source identity changed while producing runtime',
      );
    }
    await bundle.rename(output.path);
    await work.delete(recursive: true);
    return record;
  } catch (_) {
    stderr.writeln('Failed runtime build retained at ${work.path}');
    rethrow;
  }
}

Future<Map<String, Object>> _proveBundle({
  required Directory work,
  required Directory repository,
  required Directory bundle,
  required Map<String, String> shipped,
  required Map<String, Map<String, String>> modes,
  required DevkitPro install,
  required StageRunner run,
  required File assembly,
  required int jobs,
  required List<String> cflags,
}) async {
  final manifestHash = await _digest(File(p.join(bundle.path, 'runtime.json')));
  final native = NativeBuild.fromRuntime(
    files: shipped.keys,
    nativeSrc: 'native-src',
    compilePlan: 'compile-plan.json',
    cacheDirectory: Directory(p.join(work.path, 'proof-cache')),
    devkitPro: install,
    qualified: install.versions,
    maxJobs: jobs,
    asset: (name) {
      final expected = shipped[name];
      if (expected == null) {
        throw FormatException('Unsealed runtime member: $name');
      }
      final file = File(p.join(bundle.path, name));
      if (!p.isWithin(bundle.path, file.resolveSymbolicLinksSync()) ||
          sha256.convert(file.readAsBytesSync()).toString() != expected) {
        throw FormatException('Runtime source digest or path mismatch: $name');
      }
      return file.path;
    },
  );
  final stub = File(p.join(work.path, 'main.cc'))
    ..writeAsStringSync('int main() { return 0; }\n');
  final mainObject = p.setExtension(stub.path, '.o');
  await run.call(install.tool('g++'), [
    ...cflags,
    '-c',
    stub.path,
    '-o',
    mainObject,
  ], 'compile-link-probe');
  final proof = <String, Object>{};
  for (final mode in BuildMode.values) {
    final built = await native.build(
      mode: mode.name,
      sdkManifestSha256: manifestHash,
    );
    await run.call('make', [
      '-C',
      p.join(repository.path, 'runtime/ctr'),
      'barrier-check',
      'RUNTIME=${built.runtimeArchive}',
      'OBJDUMP=${install.tool("objdump")}',
    ], 'barriers-${mode.name}');
    // Force unreferenced I/O objects into the link to expose missing OS symbols.
    final ioLink = await ctrLinkArguments(
      ctrLinkTemplate
          .where(
            (arg) => !const {
              '--gc-sections',
              '{program}',
              '{payload}',
            }.contains(arg),
          )
          .toList(),
      outputs: {
        'soft_math': built.softMath,
        'runtime': built.runtimeArchive,
        'io': built.ioArchive,
        'elf': p.join(work.path, 'io-${mode.name}.elf'),
        'map': p.join(work.path, 'io-${mode.name}.map'),
      },
      launcher: [mainObject],
      targetFile: install.targetFile,
    );
    await run.call(install.tool('ld'), [
      for (final arg in ioLink)
        if (arg == built.ioArchive) ...[
          '--whole-archive',
          arg,
          '--no-whole-archive',
        ] else
          arg,
    ], 'verify-io-${mode.name}');
    final modeProof = <String, Object>{
      'barrier_check': 'pass',
      'runtime_archive_sha256': await _digest(File(built.runtimeArchive)),
      'io_archive_sha256': await _digest(File(built.ioArchive)),
      'whole_io_link_sha256': await _digest(
        File(p.join(work.path, 'io-${mode.name}.elf')),
      ),
    };
    proof[mode.name] = modeProof;
    if (mode == BuildMode.jit) continue;
    final program = File(p.join(work.path, 'program.S'))
      ..writeAsStringSync(
        programAssembly(
          'aot',
          'hello',
          modes['aot']!['compatibility']!,
          manifestHash,
          0,
        ),
      );
    for (final src in [assembly, program]) {
      await run.call(install.tool('as'), [
        '-march=armv6k',
        '-mfpu=vfp',
        '-mfloat-abi=hard',
        src.path,
        '-o',
        p.setExtension(src.path, '.o'),
      ], 'assemble-${p.basenameWithoutExtension(src.path)}');
    }
    final args = await ctrLinkArguments(
      ctrLinkTemplate,
      outputs: {
        'program': p.setExtension(program.path, '.o'),
        'payload': p.setExtension(assembly.path, '.o'),
        'soft_math': built.softMath,
        'io': built.ioArchive,
        'runtime': built.runtimeArchive,
        'elf': p.join(work.path, 'hello.elf'),
        'map': p.join(work.path, 'hello.map'),
      },
      launcher: built.launcherObjects,
      targetFile: install.targetFile,
    );
    await run.call(install.tool('ld'), args, 'link-hello');
    modeProof['hello_elf_sha256'] = await _digest(
      File(p.join(work.path, 'hello.elf')),
    );
  }
  return proof;
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<String> _output(
  String executable,
  List<String> arguments, {
  String? cwd,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: cwd,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }
  return result.stdout as String;
}
