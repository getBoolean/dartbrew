import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../sdk_manifest.dart';
import '../../cache.dart';
import '../../devkitpro.dart';
import '../../errors.dart';
import '../../process.dart';
import '../../sdk.dart';
import 'soft_math.dart';

/// Local files used to link one mode of the CTR runtime.
final class NativeArtifacts {
  final String runtimeArchive;
  final String ioArchive;
  final String softMath;
  final List<String> launcherObjects;

  NativeArtifacts._(Directory dir, List<_Unit> units)
    : runtimeArchive = p.join(dir.path, 'runtime.a'),
      ioArchive = p.join(dir.path, 'io.a'),
      softMath = p.join(dir.path, 'soft-math.o'),
      launcherObjects = [
        for (final (i, unit) in units.indexed)
          if (unit.group == _Group.launcher) p.join(dir.path, 'launcher-$i.o'),
      ];
}

enum _Group { runtime, io, launcher, check }

final class _Unit {
  final String compiler;
  final String source;
  final List<String> flags;
  final _Group group;

  _Unit(this.compiler, this.source, this.flags, this.group);

  factory _Unit.parse(Object? value) {
    if (value
        case {
          'compiler': final String compiler,
          'source': final String source,
          'flags': final List<Object?> flags,
          'group': final String group,
        }
        when (compiler == 'gcc' || compiler == 'g++') &&
            _Group.values.any((g) => g.name == group)) {
      return _Unit(
        compiler,
        _sourcePath(source),
        _flags(flags),
        _Group.values.byName(group),
      );
    }
    throw const FormatException('Malformed compile-plan translation unit.');
  }
}

String _sourcePath(String source) {
  if (!SdkManifest.isAssetPath(source)) {
    throw FormatException('Invalid native source path: $source');
  }
  return source;
}

List<String> _flags(List<Object?> values) {
  if (values.any((v) => v is! String || v.contains(RegExp(r'[\x00\r\n]')))) {
    throw const FormatException(
      'Expected compiler flags in compile-plan.json.',
    );
  }
  return values.cast<String>();
}

/// Builds the runtime from the SDK's sealed sources with the installed
/// toolchain and publishes the result to the user's cache.
final class NativeBuild {
  final Iterable<String> files;
  final String Function(String) asset;
  final String compilePlan;
  final String nativeSrc;
  final DevkitProVersions qualified;
  final DevkitPro devkitPro;
  final ProcessStarter start;
  final NativeCache _cache;
  final IOSink _progress;
  final int _maxJobs;

  NativeBuild({
    required NativeSdk sdk,
    required DevkitPro devkitPro,
    Directory? cacheDirectory,
    Map<String, String>? environment,
    ProcessStarter start = startProcess,
    IOSink? progress,
  }) : this.fromRuntime(
         files: sdk.manifest.files.keys,
         asset: sdk.asset,
         compilePlan: sdk.manifest.runtime.compilePlan,
         nativeSrc: sdk.manifest.runtime.nativeSrc,
         qualified: sdk.manifest.runtime.devkitPro,
         devkitPro: devkitPro,
         cacheDirectory: cacheDirectory,
         environment: environment,
         start: start,
         progress: progress,
       );

  /// Builds a producer runtime component before any host SDK exists.
  /// [asset] resolves a sealed member of [files] and verifies its digest.
  NativeBuild.fromRuntime({
    required this.files,
    required this.asset,
    required this.compilePlan,
    required this.nativeSrc,
    required this.qualified,
    required this.devkitPro,
    Directory? cacheDirectory,
    Map<String, String>? environment,
    this.start = startProcess,
    IOSink? progress,
    int? maxJobs,
  }) : _cache = cacheDirectory == null
           ? NativeCache.forUser(environment: environment)
           : NativeCache(cacheDirectory),
       _progress = progress ?? stderr,
       _maxJobs = maxJobs ?? Platform.numberOfProcessors {
    if (_maxJobs < 1) {
      throw ArgumentError.value(
        maxJobs,
        'maxJobs',
        'Expected at least one job',
      );
    }
  }

  /// Returns all link inputs. A signal or closure of [interrupts] cancels
  /// the build, waits for its children and discards the unpublished entry.
  Future<NativeArtifacts> build({
    required String mode,
    required String sdkManifestSha256,
    Stream<Object?>? interrupts,
    BuildProcesses? processes,
  }) => BuildProcesses.scoped(
    start,
    (processes) async {
      final Object? plan = jsonDecode(
        File(asset(compilePlan)).readAsStringSync(),
      );
      if (plan case {
        'schema': 1,
        'modes': final Map<String, Object?> modes,
        'cflags': final List<Object?> cflags,
        'soft_math_source': final String bridge,
      } when (mode == 'aot' || mode == 'jit') && modes[mode] is List<Object?>) {
        final units = (modes[mode]! as List<Object?>).map(_Unit.parse).toList();
        for (final group in _Group.values) {
          if (!units.any((unit) => unit.group == group)) {
            throw FormatException(
              'Compile plan for $mode has no ${group.name} units.',
            );
          }
        }
        final versions = devkitPro.versions;
        try {
          final key = sha256
              .convert(
                utf8.encode(
                  jsonEncode([
                    sdkManifestSha256,
                    devkitPro.root,
                    devkitPro.armRoot,
                    versions.devkitARM,
                    versions.libctru,
                    mode,
                    if (versions.devkitARM == 'unknown')
                      await _installationDigest(
                        Directory(devkitPro.armRoot),
                        processes,
                      ),
                    if (versions.libctru == 'unknown')
                      await _installationDigest(
                        Directory(p.join(devkitPro.root, 'libctru')),
                        processes,
                      ),
                  ]),
                ),
              )
              .toString();
          processes.check();
          final dir = await _cache.getOrBuild(key, (work) async {
            await _compile(
              work,
              units,
              _flags(cflags),
              _sourcePath(bridge),
              processes,
            );
          }, checkCancelled: processes.check);
          processes.check();
          return NativeArtifacts._(dir, units);
        } on DartbrewException catch (error) {
          if (error.exitCode == 130) rethrow;
          throw DartbrewException(error.exitCode, _failure(error.message));
        } on ProcessException catch (error) {
          throw DartbrewException(
            error.errorCode > 0 ? error.errorCode : 1,
            _failure(error.toString()),
          );
        } on FormatException catch (error) {
          throw FormatException(_failure(error.message));
        }
      }
      throw FormatException(
        'Unsupported or incomplete compile-plan.json for $mode.',
      );
    },
    parent: processes,
    interrupts: interrupts,
  );

  String _failure(String reason) =>
      '$reason\n${devkitPro.mismatchAdvice(qualified)}';

  // Without package revisions a reinstall can silently change headers,
  // GCC's internal tools or multi-lib files under the same path.
  Future<String> _installationDigest(
    Directory root,
    BuildProcesses processes,
  ) async {
    if (!root.existsSync()) return 'missing';
    final records = <String>[];
    await for (final file in root.list(recursive: true)) {
      processes.check();
      if (file is File) {
        records.add(
          jsonEncode([
            p.relative(file.path, from: root.path),
            await fileDigest(file),
          ]),
        );
      }
    }
    records.sort();
    return sha256.convert(utf8.encode(records.join('\n'))).toString();
  }

  Future<void> _compile(
    Directory work,
    List<_Unit> units,
    List<String> cflags,
    String bridge,
    BuildProcesses processes,
  ) async {
    final scratch = Directory(p.join(work.path, 'work'))..createSync();
    final sources = Directory(p.join(scratch.path, 'native-src'))..createSync();
    _progress.writeln('Verifying native sources');
    // Compile against the sealed set. Extra files in an installed SDK must
    // not shadow a header through the compiler's include search order.
    final prefix = '${_sourcePath(nativeSrc)}/';
    for (final name in files.where((name) => name.startsWith(prefix))) {
      processes.check();
      final relative = _sourcePath(name.substring(prefix.length));
      final copy = File(p.join(sources.path, relative));
      copy.parent.createSync(recursive: true);
      await File(asset(name)).copy(copy.path);
    }
    String expand(String flag) => flag
        .replaceAll('@src@', sources.path)
        .replaceAll('@devkitpro@', devkitPro.root);
    final outputs = [
      for (final (i, unit) in units.indexed)
        unit.group == _Group.launcher
            ? p.join(work.path, 'launcher-$i.o')
            : p.join(scratch.path, '$i.o'),
    ];
    Future<void> responseCommand(
      String tool,
      List<String> args,
      String name,
    ) async {
      final response = File(p.join(scratch.path, '$name.rsp'));
      await response.writeAsString(
        args
            .map(
              (arg) =>
                  '"${arg.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
            )
            .join('\n'),
      );
      await processes.run(devkitPro.tool(tool), ['@${response.path}']);
    }

    var next = 0;
    var finished = 0;
    var failed = false;
    final workerCount = math.min(units.length, _maxJobs);
    _progress.writeln(
      'Compiling ${units.length} native units ($workerCount jobs)',
    );
    Future<void> worker() async {
      while (!failed && next < units.length) {
        processes.check();
        final i = next++;
        final unit = units[i];
        try {
          await responseCommand(unit.compiler, [
            ...unit.flags.map(expand),
            '-c',
            p.join(sources.path, unit.source),
            '-o',
            outputs[i],
          ], '$i');
          if (!File(outputs[i]).existsSync()) {
            throw FileSystemException(
              'Compiler did not produce an object for ${unit.source}',
              outputs[i],
            );
          }
        } on ProcessException catch (error) {
          failed = true;
          throw ProcessException(
            error.executable,
            error.arguments,
            '${unit.source}: ${error.message}',
            error.errorCode,
          );
        } catch (_) {
          failed = true;
          rethrow;
        }
        finished++;
        if (finished % 32 == 0 || finished == units.length) {
          _progress.writeln('Compiled $finished/${units.length}');
        }
      }
    }

    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    _progress.writeln('Archiving runtime and dart:io');
    for (final group in [_Group.runtime, _Group.io]) {
      final archive = p.join(work.path, '${group.name}.a');
      await responseCommand('ar', [
        'rcs',
        archive,
        for (final (i, unit) in units.indexed)
          if (unit.group == group) outputs[i],
      ], group.name);
      if (!File(archive).existsSync()) {
        throw FileSystemException(
          'Archiver did not produce ${group.name}',
          archive,
        );
      }
    }
    _progress.writeln('Building and verifying soft-math');
    final softMath = await buildSoftMath(
      tool: devkitPro.tool,
      cflags: cflags.map(expand).toList(),
      source: File(p.join(sources.path, bridge)),
      output: scratch,
      run: processes.run,
    );
    await softMath.rename(p.join(work.path, 'soft-math.o'));
    await scratch.delete(recursive: true);
  }
}
