/// The `sdk.json` manifest that describes a dartbrew SDK: its host, tools,
/// runtime, link inputs and sealed files.
library;

export 'src/targets/ctr/link_template.dart' show ctrLinkTemplate;

/// The message appended to every manifest error: a manifest this dartbrew
/// cannot read comes from an SDK that does not match it.
const _mismatchAdvice =
    'The SDK does not match this dartbrew; update dartbrew and use the SDK '
    'it ships with.';

/// A host tool the SDK ships, by its manifest key under `tools`.
enum SdkTool {
  snapshot('snapshot'),
  kernel('kernel'),
  dart('dart');

  /// The key that names this tool in the manifest.
  final String key;

  const SdkTool(this.key);

  /// The tool named [key] in the manifest.
  ///
  /// Throws an [ArgumentError] when no tool has that key.
  static SdkTool byKey(String key) => values.firstWhere(
    (tool) => tool.key == key,
    orElse: () => throw ArgumentError.value(key, 'key', 'Unknown SDK tool'),
  );
}

/// The CTR runtime inputs for one build mode.
final class RuntimeMode {
  /// The launcher compatibility token the program must carry.
  final String compatibility;

  const RuntimeMode({required this.compatibility});

  factory RuntimeMode._read(_JsonObject json) =>
      RuntimeMode(compatibility: json.string('compatibility'));

  Map<String, Object> _toJson() => {'compatibility': compatibility};
}

/// Installed or qualified devkitPro package releases.
final class DevkitProVersions {
  final String devkitARM;
  final String libctru;
  const DevkitProVersions({required this.devkitARM, required this.libctru});
  const DevkitProVersions.unknown()
    : devkitARM = 'unknown',
      libctru = 'unknown';

  @override
  String toString() => 'devkitARM $devkitARM, libctru $libctru';
}

/// The CTR runtime the SDK ships.
final class SdkRuntime {
  /// The Dart SDK commit the runtime was built from.
  final String sdkHead;

  /// The platform kernel the kernel compiler reads.
  final String platform;

  /// The runtime for AOT builds.
  final RuntimeMode aot;

  /// The runtime for JIT builds.
  final RuntimeMode jit;

  final String snapshotHash;
  final String compilePlan;
  final String nativeSrc;
  final List<String> linkTemplate;
  final DevkitProVersions devkitPro;

  const SdkRuntime({
    required this.sdkHead,
    required this.platform,
    required this.aot,
    required this.jit,
    required this.snapshotHash,
    required this.compilePlan,
    required this.nativeSrc,
    required this.linkTemplate,
    required this.devkitPro,
  });

  /// Reads runtime metadata from the runtime producer before host assembly.
  factory SdkRuntime.fromJson(Object? json) =>
      SdkRuntime._read(_JsonObject.root(json));

  factory SdkRuntime._read(_JsonObject json) {
    final modes = json.object('modes');
    return SdkRuntime(
      sdkHead: json.string('sdk_head'),
      platform: json.string('platform'),
      aot: RuntimeMode._read(modes.object('aot')),
      jit: RuntimeMode._read(modes.object('jit')),
      snapshotHash: json.string('snapshot_hash'),
      compilePlan: json.assetPath('compile_plan'),
      nativeSrc: json.assetPath('native_src'),
      linkTemplate: json.strings('link_template'),
      devkitPro: DevkitProVersions(
        devkitARM: json.object('devkitpro').string('devkitARM'),
        libctru: json.object('devkitpro').string('libctru'),
      ),
    );
  }

  Map<String, Object> _toJson() => {
    'sdk_head': sdkHead,
    'platform': platform,
    'modes': {'aot': aot._toJson(), 'jit': jit._toJson()},
    'snapshot_hash': snapshotHash,
    'compile_plan': compilePlan,
    'native_src': nativeSrc,
    'link_template': linkTemplate,
    'devkitpro': {
      'devkitARM': devkitPro.devkitARM,
      'libctru': devkitPro.libctru,
    },
  };
}

/// A dartbrew SDK's `sdk.json`.
///
/// Every path in the manifest is relative to the SDK root, uses `/`
/// separators, and names a sealed file in [files].
final class SdkManifest {
  /// The manifest format this dartbrew reads and writes.
  static const schema = 1;

  /// The host the SDK runs on, such as `windows-x64`.
  final String host;

  /// The path of each host tool.
  final Map<SdkTool, String> tools;

  /// The CTR runtime and its link inputs.
  final SdkRuntime runtime;

  /// The lowercase SHA-256 digest of every sealed file, by path.
  final Map<String, String> files;

  const SdkManifest({
    required this.host,
    required this.tools,
    required this.runtime,
    required this.files,
  });

  /// Reads a decoded `sdk.json`.
  ///
  /// Unknown keys are ignored. Throws a [FormatException] that names the
  /// offending key when the schema is not [schema], a required key is
  /// missing or has the wrong type, [files] is empty, or a file path or
  /// digest is malformed.
  factory SdkManifest.fromJson(Object? json) {
    final root = _JsonObject.root(json);
    final version = root.integer('schema');
    if (version != schema) {
      throw FormatException(
        'SDK manifest schema $version is not supported. $_mismatchAdvice',
      );
    }
    final tools = root.object('tools');
    final files = root.stringMap('files');
    if (files.isEmpty) throw const FormatException('SDK has no sealed assets.');
    for (final MapEntry(key: path, value: digest) in files.entries) {
      if (!isAssetPath(path)) {
        throw FormatException('Invalid SDK asset path: $path');
      }
      if (!_digestPattern.hasMatch(digest)) {
        throw FormatException('Invalid SDK asset digest for $path: $digest');
      }
    }
    return SdkManifest(
      host: root.string('host'),
      tools: {for (final tool in SdkTool.values) tool: tools.string(tool.key)},
      runtime: SdkRuntime._read(root.object('runtime')),
      files: files,
    );
  }

  /// The JSON object [SdkManifest.fromJson] reads back as an equal manifest.
  Map<String, Object> toJson() => {
    'schema': schema,
    'host': host,
    'tools': {
      for (final MapEntry(:key, :value) in tools.entries) key.key: value,
    },
    'runtime': runtime._toJson(),
    'files': files,
  };

  /// Whether [path] is a relative `/`-separated path with no empty or `..`
  /// segment, the only form a manifest path may take.
  static bool isAssetPath(String path) =>
      !path.startsWith('/') &&
      !path.contains(RegExp(r'[\\:\x00-\x1f]')) &&
      !path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..');

  static final _digestPattern = RegExp(r'^[a-f0-9]{64}$');
}

/// A JSON object read at a dotted key path, whose accessors throw a
/// [FormatException] naming the full key when it is missing or mistyped.
final class _JsonObject {
  final Map<String, Object?> _values;
  final String _path;

  _JsonObject._(this._values, this._path);

  factory _JsonObject.root(Object? json) => switch (json) {
    final Map<String, Object?> values => _JsonObject._(values, ''),
    _ => throw const FormatException(
      'SDK manifest is not a JSON object. $_mismatchAdvice',
    ),
  };

  String _key(String key) => _path.isEmpty ? key : '$_path.$key';

  Object _require(String key) =>
      _values[key] ??
      (throw FormatException(
        'SDK manifest is missing `${_key(key)}`. $_mismatchAdvice',
      ));

  Never _mistyped(String key, String expected) => throw FormatException(
    'SDK manifest key `${_key(key)}` must be $expected. $_mismatchAdvice',
  );

  int integer(String key) => switch (_require(key)) {
    final int value => value,
    _ => _mistyped(key, 'an integer'),
  };

  String string(String key) => switch (_require(key)) {
    final String value => value,
    _ => _mistyped(key, 'a string'),
  };

  String assetPath(String key) {
    final path = string(key);
    if (!SdkManifest.isAssetPath(path)) {
      throw FormatException('Invalid SDK asset path for ${_key(key)}: $path');
    }
    return path;
  }

  List<String> strings(String key) => switch (_require(key)) {
    final List<Object?> values when values.every((value) => value is String) =>
      List.unmodifiable(values.cast<String>()),
    _ => _mistyped(key, 'a list of strings'),
  };

  Map<String, String> stringMap(String key) => switch (_require(key)) {
    final Map<String, Object?> values
        when values.values.every((value) => value is String) =>
      Map.unmodifiable(values.cast<String, String>()),
    _ => _mistyped(key, 'an object of strings'),
  };

  _JsonObject object(String key) => switch (_require(key)) {
    final Map<String, Object?> values => _JsonObject._(values, _key(key)),
    _ => _mistyped(key, 'an object'),
  };
}
