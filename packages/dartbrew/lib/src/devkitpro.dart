import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../sdk_manifest.dart';
import 'errors.dart';
import 'process.dart';

const _installHint =
    'Install the CTR development tools from https://devkitpro.org/wiki/Getting_Started '
    'and set DEVKITPRO or DEVKITARM to the installation directory.';

/// The local devkitPro installation used to compile and link target code.
final class DevkitPro {
  final String root;
  final String armRoot;
  final DevkitProVersions versions;
  final ProcessStarter _start;
  const DevkitPro._(this.root, this.armRoot, this.versions, this._start);

  /// Resolves the user's SDK from environment settings or the platform default.
  static Future<DevkitPro> discover({
    Map<String, String>? environment,
    ProcessStarter start = startProcess,
  }) async {
    final env = environment ?? Platform.environment;
    String? setting(String key) => switch (env[key]) {
      null || '' => null,
      final value => value,
    };
    String? root = setting('DEVKITPRO');
    String? arm = setting('DEVKITARM');
    if (Platform.isWindows) {
      // The updater registers the native path and mounts it at /opt/devkitpro.
      final explicitRoot = root != null && !root.startsWith('/') ? root : null;
      final explicitArm = arm != null && !arm.startsWith('/') ? arm : null;
      final native =
          explicitRoot ??
          (explicitArm != null
              ? p.dirname(explicitArm)
              : await _windowsRoot(start));
      Future<String?> translate(String? path) async {
        if (path == null || !path.startsWith('/')) return path;
        final cygpath = p.join(native, 'msys2', 'usr', 'bin', 'cygpath.exe');
        final translated = await _query(start, cygpath, ['-aw', path]);
        if (translated != null && p.windows.isAbsolute(translated)) {
          return translated;
        }
        const mount = '/opt/devkitpro';
        if (path == mount) return native;
        if (path.startsWith('$mount/')) {
          return p.join(native, path.substring(mount.length + 1));
        }
        throw DartbrewException(
          78,
          'Cannot resolve MSYS path $path. $_installHint',
        );
      }

      root = await translate(root) ?? native;
      arm = await translate(arm);
    }
    root ??= arm == null ? '/opt/devkitpro' : p.dirname(arm);
    arm ??= p.join(root, 'devkitARM');
    final installedRoot = p.normalize(p.absolute(root));
    final installedArm = p.normalize(p.absolute(arm));
    if (!File(_toolPath(installedArm, 'gcc')).existsSync()) {
      throw DartbrewException(
        78,
        'Missing devkitARM compiler in $installedArm. $_installHint',
      );
    }
    final versions = await _packageVersions(installedRoot, start);
    final installedVersions =
        p.equals(installedArm, p.join(installedRoot, 'devkitARM'))
        ? versions
        : DevkitProVersions(devkitARM: 'unknown', libctru: versions.libctru);
    return DevkitPro._(installedRoot, installedArm, installedVersions, start);
  }

  static Future<String> _windowsRoot(ProcessStarter start) async {
    final registry = p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'System32',
      'reg.exe',
    );
    final result = await _query(start, registry, [
      'query',
      r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\devkitProUpdater',
      '/v',
      'InstallLocation',
      '/reg:32',
    ]);
    return RegExp(
          r'^\s*InstallLocation\s+REG_SZ\s+(.+?)\s*$',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(result ?? '')?.group(1) ??
        r'C:\devkitPro';
  }

  static String _toolPath(String arm, String name) => p.join(
    arm,
    'bin',
    'arm-none-eabi-$name${Platform.isWindows ? '.exe' : ''}',
  );

  /// Resolves a GNU tool such as gcc, g++, ld, nm or objcopy from this install.
  String tool(String name) {
    final path = _toolPath(armRoot, name);
    if (!File(path).existsSync()) {
      throw DartbrewException(78, 'Missing $path. $_installHint');
    }
    return path;
  }

  static Future<DevkitProVersions> _packageVersions(
    String root,
    ProcessStarter start,
  ) async {
    final commands = Platform.isWindows
        ? [p.join(root, 'msys2', 'usr', 'bin', 'pacman.exe')]
        : [p.join(root, 'pacman', 'bin', 'pacman'), 'dkp-pacman', 'pacman'];
    for (final command in commands) {
      final output = await _query(start, command, [
        // A system pacman may manage an unrelated, default installation.
        if (!Platform.isWindows && !p.equals(root, '/opt/devkitpro')) ...[
          '--dbpath',
          p.join(root, 'pacman', 'var', 'lib', 'pacman'),
        ],
        '-Q',
        'devkitARM',
        'libctru',
      ]);
      if (output == null) continue;
      final fields = {
        for (final m in RegExp(
          r'^(devkitARM|libctru)\s+(\S+)\s*$',
          multiLine: true,
        ).allMatches(output))
          m[1]!: m[2]!,
      };
      if (fields.isNotEmpty) {
        return DevkitProVersions(
          devkitARM: fields['devkitARM'] ?? 'unknown',
          libctru: fields['libctru'] ?? 'unknown',
        );
      }
    }
    return const DevkitProVersions.unknown();
  }

  /// Returns the installed target file for the CTR multilib and ABI.
  Future<String> targetFile(String basename, {bool softFloat = false}) async {
    final path = basename == 'libctru.a'
        ? p.join(root, 'libctru', 'lib', basename)
        : await _query(_start, tool('gcc'), [
            '-marm',
            '-march=armv6k',
            if (!softFloat) '-mfpu=vfp',
            '-mfloat-abi=${softFloat ? 'soft' : 'hard'}',
            '-mtp=soft',
            '-print-file-name=$basename',
          ]);
    if (path == null || !p.isAbsolute(path) || !File(path).existsSync()) {
      throw DartbrewException(
        78,
        'Missing target file $basename in $root. $_installHint',
      );
    }
    return p.normalize(path);
  }

  /// Describes the toolchains involved in a failed native stage.
  String mismatchAdvice(DevkitProVersions qualified) =>
      'Installed: $versions. Qualified: $qualified. Update dartbrew or devkitPro.';
}

Future<String?> _query(
  ProcessStarter start,
  String exe,
  List<String> args,
) async {
  try {
    final process = await start(exe, args);
    final stderrDone = process.stderr.drain<void>();
    final text = await utf8.decodeStream(process.stdout);
    await stderrDone;
    return await process.exitCode == 0 ? text.trim() : null;
  } on ProcessException {
    return null;
  }
}
