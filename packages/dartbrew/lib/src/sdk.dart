import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../sdk_manifest.dart';

/// Adds the shared `--sdk` option to [parser].
void addSdkOption(ArgParser parser) {
  parser.addOption(
    'sdk',
    help: 'SDK directory; defaults to the directory containing dartbrew.',
  );
}

/// The SDK directory chosen by an option added with [addSdkOption].
String sdkDirectory(ArgResults results) =>
    results.option('sdk') ?? p.dirname(Platform.resolvedExecutable);

/// The SDK host name of this machine, such as `windows-x64`.
///
/// Throws an [UnsupportedError] on an architecture no SDK is built for.
String currentHost() {
  // Platform.version names the VM's native architecture even in AOT builds.
  final version = Platform.version;
  final architecture = version.contains('arm64')
      ? 'arm64'
      : version.contains('x64')
      ? 'x64'
      : throw UnsupportedError('Unsupported host architecture: $version');
  return '${Platform.operatingSystem}-$architecture';
}

/// The lowercase SHA-256 digest of [file]'s contents.
Future<String> fileDigest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// The sealed SDK that ships next to the `dartbrew` executable.
///
/// A sealed file is checked against its manifest digest the first time
/// [asset] or [tool] resolves it, so a command hashes only the files it
/// uses; [verifyAllAssets] checks every file.
final class NativeSdk {
  /// The SDK directory, with symbolic links resolved.
  final String root;

  /// The SDK's `sdk.json`.
  final SdkManifest manifest;

  /// Digest of the exact bytes from which [manifest] was parsed.
  final String manifestSha256;
  final bool _verifiesOnUse;
  final _verified = <String>{};

  NativeSdk._(
    this.root,
    this.manifest,
    this.manifestSha256,
    this._verifiesOnUse,
  );

  /// Loads the SDK at [directory] and checks its manifest and native host.
  ///
  /// With [quick], assets are never hashed and only the `dart` tool's
  /// presence is checked, so commands that forward to the host Dart start
  /// at once.
  ///
  /// Throws a [FormatException] when the manifest cannot be read (see
  /// [SdkManifest.fromJson]) or names another host, and a
  /// [FileSystemException] when `sdk.json` or, with [quick], the `dart` tool
  /// is missing.
  static Future<NativeSdk> load(String directory, {bool quick = false}) async {
    final root = Directory(directory).resolveSymbolicLinksSync();
    final bytes = await File(p.join(root, 'sdk.json')).readAsBytes();
    final manifest = SdkManifest.fromJson(jsonDecode(utf8.decode(bytes)));
    if (manifest.host != currentHost()) {
      throw FormatException(
        'SDK is for ${manifest.host}, but this machine is ${currentHost()}.',
      );
    }
    final sdk = NativeSdk._(
      root,
      manifest,
      sha256.convert(bytes).toString(),
      !quick,
    );
    if (quick) sdk.tool(SdkTool.dart.key);
    return sdk;
  }

  /// The resolved path of the sealed file [relative].
  ///
  /// Throws a [FormatException] when [relative] is not a sealed file, leaves
  /// the SDK through a symbolic link, or (unless loaded with `quick`) its
  /// contents do not match the manifest; a [FileSystemException] when it is
  /// missing.
  String asset(String relative) {
    final resolved = _resolve(relative);
    if (_verifiesOnUse) _verify(relative, resolved);
    return resolved;
  }

  /// The resolved path of the tool [name], a manifest key of [SdkTool];
  /// checked as by [asset].
  String tool(String name) => asset(manifest.tools[SdkTool.byKey(name)]!);

  /// Checks every sealed file against its manifest digest.
  ///
  /// Throws as [asset] does for the first file that fails.
  void verifyAllAssets() {
    for (final relative in manifest.files.keys) {
      _verify(relative, _resolve(relative));
    }
  }

  String _resolve(String relative) {
    if (!manifest.files.containsKey(relative)) {
      throw FormatException('Invalid SDK asset path: $relative');
    }
    final resolved = File(
      p.joinAll([root, ...relative.split('/')]),
    ).resolveSymbolicLinksSync();
    if (!p.isWithin(root, resolved)) {
      throw FormatException('SDK asset escapes its directory: $relative');
    }
    return resolved;
  }

  void _verify(String relative, String resolved) {
    if (_verified.contains(relative)) return;
    final digest = sha256.convert(File(resolved).readAsBytesSync()).toString();
    if (digest != manifest.files[relative]) {
      throw FormatException('SDK asset hash mismatch: $relative');
    }
    _verified.add(relative);
  }
}
