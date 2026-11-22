import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A separately configured part of the patched Dart SDK build.
enum SdkComponent {
  /// The Linux x64 SDK the other components are built with.
  host,

  /// The Linux x64 `gen_snapshot` that compiles for CTR.
  precompiler,

  /// The ARM runtime archives linked into CTR apps.
  target,
}

/// Which runtime graph a component is built for.
enum BuildMode { aot, jit }

/// The composed linker specs file a [TargetProfile] links with.
final class LinkSpecs {
  /// The path as the profile names it, relative to the profile.
  final String path;

  /// The resolved location of the file.
  final String absolutePath;

  /// The SHA-256 of the file's bytes.
  final String sha256;

  const LinkSpecs(this.path, this.absolutePath, this.sha256);
}

/// The CTR target profile, `toolchain/target-ctr.json`.
final class TargetProfile {
  /// The whole profile document; every field is part of the build identity.
  final Map<String, Object?> document;
  final String compilerPrefix;
  final String libctru;
  final List<String> cflags;
  final LinkSpecs linkSpecs;

  TargetProfile._(
    this.document,
    this.compilerPrefix,
    this.libctru,
    this.cflags,
    this.linkSpecs,
  );

  /// Reads the profile at [file] and hashes its linker specs.
  ///
  /// Throws a [FormatException] unless the profile names exactly one composed
  /// specs file.
  static TargetProfile load(File file) {
    final document =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final specs = (document['link_specs']! as List<Object?>).cast<String>();
    if (specs.length != 1) {
      throw FormatException(
        '${file.path}: CTR GN configuration requires one composed specs file, '
        'found ${specs.length}',
      );
    }
    final specsFile = File(
      p.normalize(p.join(file.parent.absolute.path, specs.single)),
    );
    return TargetProfile._(
      document,
      document['compiler_prefix']! as String,
      document['libctru']! as String,
      (document['cflags']! as List<Object?>).cast<String>(),
      LinkSpecs(
        specs.single,
        specsFile.path,
        sha256.convert(specsFile.readAsBytesSync()).toString(),
      ),
    );
  }

  /// The GN arguments that select the profile's ARM architecture.
  Map<String, Object> get architectureGnArgs => {
    for (final key in const [
      'target_os',
      'target_cpu',
      'arm_version',
      'arm_fpu',
      'arm_float_abi',
      'arm_use_neon',
      'arm_use_integer_division',
    ])
      key: document[key]!,
  };
}

/// What a component build is configured from, and the cache key that names
/// its output directory.
///
/// The key is a SHA-256 over the whole pin table, the whole target profile,
/// the specs bytes, the component, the mode, the GN arguments and the root
/// target, so any change to them selects a new build directory. Paths outside
/// the profile are not part of it.
final class BuildIdentity {
  final SdkComponent component;
  final BuildMode mode;
  final Map<String, Object> gnArgs;

  /// The GN label of the component, such as `//build/ctr:aot_runtime`.
  final String rootTarget;
  final Map<String, Object?> inputs;
  final String cacheKey;

  BuildIdentity._(
    this.component,
    this.mode,
    this.gnArgs,
    this.rootTarget,
    this.inputs,
    this.cacheKey,
  );

  /// The identity of [component] in [mode] for the pin table [manifest] and
  /// [profile].
  factory BuildIdentity.of({
    required Map<String, Object?> manifest,
    required TargetProfile profile,
    required SdkComponent component,
    required BuildMode mode,
  }) {
    const hostGnArgs = <String, Object>{
      'target_os': 'linux',
      'target_cpu': 'x64',
      'is_debug': false,
      'is_release': true,
      'is_clang': true,
      'dart_use_crashpad': false,
    };
    final gnArgs = switch (component) {
      SdkComponent.host => hostGnArgs,
      SdkComponent.precompiler || SdkComponent.target => {
        ...hostGnArgs,
        ...profile.architectureGnArgs,
        'is_clang': false,
        'dart_use_compressed_pointers': false,
        'dart_target_arch': 'arm',
        'dart_support_perfetto': false,
      },
    };
    final rootTarget = switch ((component, mode)) {
      (SdkComponent.host, _) => '//:create_sdk',
      (SdkComponent.precompiler, _) => '//build/ctr:precompiler',
      (SdkComponent.target, BuildMode.aot) => '//build/ctr:aot_runtime',
      (SdkComponent.target, BuildMode.jit) => '//build/ctr:jit_runtime',
    };
    final inputs = <String, Object?>{
      'manifest': manifest,
      'profile': profile.document,
      'link_specs': {
        'path': profile.linkSpecs.path,
        'sha256': profile.linkSpecs.sha256,
      },
      'component': component.name,
      'mode': mode.name,
      'gn_args': gnArgs,
      'root_target': rootTarget,
    };
    return BuildIdentity._(
      component,
      mode,
      gnArgs,
      rootTarget,
      inputs,
      sha256.convert(utf8.encode(jsonEncode(_sortedKeys(inputs)))).toString(),
    );
  }

  /// The identity as `compatibility.json` records it.
  Map<String, Object?> toJson() =>
      _sortedKeys({
            'cache_key': cacheKey,
            'component': component.name,
            'mode': mode.name,
            'gn_args': gnArgs,
            'root_target': rootTarget,
            'inputs': inputs,
          })
          as Map<String, Object?>;
}

/// [value] with every map's keys in sorted order, so equal documents encode
/// to equal bytes.
Object? _sortedKeys(Object? value) => switch (value) {
  Map<String, Object?>() => {
    for (final key in value.keys.toList()..sort()) key: _sortedKeys(value[key]),
  },
  List<Object?>() => [for (final item in value) _sortedKeys(item)],
  _ => value,
};
