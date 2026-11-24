import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'host.dart';

const _windowsSystem = {
  'kernel32.dll',
  'kernelbase.dll',
  'user32.dll',
  'advapi32.dll',
  'shell32.dll',
  'ole32.dll',
  'oleaut32.dll',
  'ws2_32.dll',
  'bcrypt.dll',
  'crypt32.dll',
  'rpcrt4.dll',
  'ntdll.dll',
  'psapi.dll',
  'shlwapi.dll',
  'dbghelp.dll',
  'version.dll',
  'winmm.dll',
  'iphlpapi.dll',
  'userenv.dll',
  'normaliz.dll',
  'secur32.dll',
  'msvcrt.dll',
  'ucrtbase.dll',
  'winhttp.dll',
  'dnsapi.dll',
  'powrprof.dll',
  'synchronization.dll',
};
const _linuxSystem = {
  'libc.so.6',
  'libm.so.6',
  'libdl.so.2',
  'libpthread.so.0',
  'ld-linux-x86-64.so.2',
};

/// The normal and delay-loaded DLL names imported by a Windows x64 PE image.
Set<String> peImports(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  int u16(int at) => data.getUint16(at, Endian.little);
  int u32(int at) => data.getUint32(at, Endian.little);
  final pe = u32(0x3c);
  final optional = pe + 24;
  if (u16(0) != 0x5a4d ||
      u32(pe) != 0x4550 ||
      u16(pe + 4) != 0x8664 ||
      u16(optional) != 0x20b) {
    throw const FormatException('Expected an x64 PE32+ image');
  }
  final sectionTable = optional + u16(pe + 20);
  int offset(int rva) {
    for (var section = 0; section < u16(pe + 6); section++) {
      final at = sectionTable + 40 * section;
      final delta = rva - u32(at + 12);
      if (delta >= 0 && delta < u32(at + 16)) {
        final address = u32(at + 20) + delta;
        if (address < bytes.length) return address;
      }
    }
    throw FormatException('Unmapped PE address $rva');
  }

  final imports = <String>{};
  for (final (index, stride, nameOffset) in [(1, 20, 12), (13, 32, 4)]) {
    if (index >= u32(optional + 108)) continue;
    final entry = optional + 112 + 8 * index;
    if (entry + 8 > sectionTable) {
      throw const FormatException('Truncated PE directory');
    }
    final start = u32(entry);
    final size = u32(entry + 4);
    if (start == 0) continue;
    var terminated = false;
    for (var consumed = 0; consumed + stride <= size; consumed += stride) {
      final at = offset(start + consumed);
      if (bytes.sublist(at, at + stride).every((b) => b == 0)) {
        terminated = true;
        break;
      }
      if (index == 13 && u32(at) != 1) {
        throw const FormatException('Unsupported VA-based PE delay import');
      }
      final name = offset(u32(at + nameOffset));
      final end = bytes.indexOf(0, name);
      if (end < name) throw const FormatException('Unterminated PE DLL name');
      final dll = ascii.decode(bytes.sublist(name, end)).toLowerCase();
      if (!RegExp(r'^[\w.+-]+\.dll$').hasMatch(dll)) {
        throw FormatException('Invalid imported DLL name $dll');
      }
      imports.add(dll);
    }
    if (!terminated) {
      throw const FormatException('Unterminated PE import table');
    }
  }
  if (imports.isEmpty) throw const FormatException('Empty PE import table');
  return imports;
}

/// Checks ELF dependencies and the maximum supported glibc version (2.36).
Map<String, Object> auditElfReport(String report) {
  final names = RegExp(
    r'\(NEEDED\).*?\[([^\]]+)\]',
  ).allMatches(report).map((m) => m[1]!).toSet();
  final versions = RegExp(
    r'\bGLIBC_(\d+(?:\.\d+)+)',
  ).allMatches(report).map((m) => m[1]!).toSet();
  if (names.isEmpty || versions.isEmpty) {
    throw const FormatException('ELF is missing its dynamic runtime records');
  }
  for (final name in names) {
    if (!_linuxSystem.contains(name)) {
      throw FormatException('Unbundled host dependency: $name');
    }
  }
  for (final v in versions) {
    final parts = v.split('.').map(int.parse).toList();
    if (parts[0] > 2 ||
        (parts[0] == 2 &&
            (parts[1] > 36 ||
                (parts[1] == 36 && parts.skip(2).any((part) => part > 0))))) {
      throw FormatException('GLIBC_$v exceeds the 2.36 baseline');
    }
  }
  return {
    'dependencies': names.toList()..sort(),
    'glibc_versions': versions.toList()..sort(),
  };
}

/// Highest macOS deployment target in the `otool -l` records of an ARM64
/// image. A modern SDK version may appear alongside a lower deployment target.
String macosDeploymentTarget(String loadCommands) {
  final targets = <String>[];
  for (final command in loadCommands.split(
    RegExp(r'^Load command \d+', multiLine: true),
  )) {
    final modern = RegExp(
      r'^\s*cmd LC_BUILD_VERSION\s*$',
      multiLine: true,
    ).hasMatch(command);
    final legacy = RegExp(
      r'^\s*cmd LC_VERSION_MIN_MACOSX\s*$',
      multiLine: true,
    ).hasMatch(command);
    if (!modern && !legacy) continue;
    if (modern &&
        !RegExp(
          r'^\s*platform (?:1|macos)\s*$',
          caseSensitive: false,
          multiLine: true,
        ).hasMatch(command)) {
      throw const FormatException('Mach-O was built for another platform');
    }
    final field = modern ? 'minos' : 'version';
    final match = RegExp(
      '^\\s*$field (\\d+(?:\\.\\d+){0,2})\\s*\$',
      multiLine: true,
    ).firstMatch(command);
    if (match == null) throw FormatException('Missing Mach-O $field');
    targets.add(match[1]!);
  }
  if (targets.isEmpty) {
    throw const FormatException('Mach-O has no macOS deployment target');
  }
  return highestMacosVersion(targets);
}

/// Highest version in the numeric deployment targets of the shipped images.
String highestMacosVersion(Iterable<String> versions) {
  int number(String text) {
    final parts = text.split('.').map(int.parse).toList();
    return (parts[0] << 16) +
        (parts.elementAtOrNull(1) ?? 0) * 256 +
        (parts.elementAtOrNull(2) ?? 0);
  }

  return versions.reduce((a, b) => number(a) >= number(b) ? a : b);
}

/// Verifies CPU and import closure of the distributed native executables.
Future<Map<String, Object>> auditHostBinaries(
  Directory sdk,
  Host host,
  Iterable<File> executables,
) async {
  final result = <String, Object>{};
  final pending = executables.toList();
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    final name = p.posix.joinAll(
      p.split(p.relative(file.path, from: sdk.path)),
    );
    if (result.containsKey(name)) continue;
    if (host.os == HostOs.windows) {
      final deps = peImports(await file.readAsBytes());
      for (final dep in deps) {
        if (_windowsSystem.contains(dep) ||
            dep.startsWith('api-ms-win-') ||
            dep.startsWith('ext-ms-win-')) {
          continue;
        }
        final companion = File(p.join(file.parent.path, dep));
        if (!await companion.exists()) {
          throw FormatException('$name requires unbundled dependency $dep');
        }
        pending.add(companion);
      }
      result[name] = {'dependencies': deps.toList()..sort()};
      continue;
    }
    final input = await file.open();
    final Uint8List header;
    try {
      header = await input.read(20);
    } finally {
      await input.close();
    }
    final data = ByteData.sublistView(header);
    final isLinux = host.os == HostOs.linux;
    final universal =
        !isLinux && const {0xcafebabe, 0xcafebabf}.contains(data.getUint32(0));
    if (isLinux
        ? !(data.getUint32(0) == 0x7f454c46 &&
              header[4] == 2 &&
              header[5] == 1 &&
              data.getUint16(18, Endian.little) == 62)
        : !(universal ||
              (data.getUint32(0, Endian.little) == 0xfeedfacf &&
                  data.getUint32(4, Endian.little) == 0x0100000c))) {
      throw FormatException(
        '$name does not contain a native ${host.id} binary',
      );
    }
    final tool = isLinux ? 'readelf' : 'otool';
    if (universal) {
      final args = ['-verify_arch', 'arm64', file.path];
      final slice = await Process.run('lipo', args);
      if (slice.exitCode != 0) {
        throw FormatException('$name lacks an arm64 Mach-O slice');
      }
    }
    final args = [
      if (isLinux) ...['-d', '--version-info'] else ...['-arch', 'arm64', '-L'],
      file.path,
    ];
    final read = await Process.run(tool, args);
    if (read.exitCode != 0) {
      throw ProcessException(tool, args, '${read.stderr}', read.exitCode);
    }
    if (isLinux) {
      result[name] = auditElfReport(read.stdout as String);
    } else {
      final deps = const LineSplitter()
          .convert(read.stdout as String)
          .skip(1)
          .map((line) => line.trim().split(' (').first)
          .where((s) => s.isNotEmpty)
          .toList();
      final loadArgs = ['-arch', 'arm64', '-l', file.path];
      final load = await Process.run('otool', loadArgs);
      if (load.exitCode != 0) {
        throw ProcessException(
          'otool',
          loadArgs,
          '${load.stderr}',
          load.exitCode,
        );
      }
      final commands = load.stdout as String;
      final ownName = RegExp(
        r'\bcmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.+?) \(offset \d+\)',
      ).firstMatch(commands)?[1];
      if (ownName != null) deps.remove(ownName);
      if (deps.isEmpty &&
          (commands.contains('cmd LC_MAIN') ||
              (!universal && data.getUint32(12, Endian.little) == 2))) {
        throw FormatException('$name has no Mach-O dependencies');
      }
      for (final dep in deps) {
        if (!dep.startsWith('/usr/lib/') &&
            !dep.startsWith('/System/Library/')) {
          throw FormatException('$name requires unbundled dependency $dep');
        }
      }
      result[name] = {
        'dependencies': deps,
        'minimum_macos': macosDeploymentTarget(commands),
      };
    }
  }
  return result;
}
