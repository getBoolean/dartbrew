import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:release_tools/src/host.dart';
import 'package:release_tools/src/host_binary_audit.dart';
import 'package:test/test.dart';

/// Single-section PE32+ import directory with one descriptor and terminator.
Uint8List fixture(String dll) {
  final bytes = Uint8List(1024);
  final fields = ByteData.sublistView(bytes);
  void u32(int at, int value) => fields.setUint32(at, value, Endian.little);
  void u16(int at, int value) => fields.setUint16(at, value, Endian.little);
  u16(0, 0x5a4d);
  u32(0x3c, 64);
  u32(64, 0x4550);
  u16(68, 0x8664);
  u16(70, 1);
  u16(84, 240);
  const header = 88;
  u16(header, 0x20b);
  u32(header + 108, 16);
  u32(header + 120, 4096);
  u32(header + 124, 40);
  const section = header + 240;
  u32(section + 8, 512);
  u32(section + 12, 4096);
  u32(section + 16, 512);
  u32(section + 20, 512);
  u32(512 + 12, 4096 + 48);
  bytes.setAll(512 + 48, ascii.encode(dll));
  return bytes;
}

void main() {
  test(
    'macOS deployment target uses numeric load-command minima and ignores SDK versions',
    () {
      expect(
        macosDeploymentTarget('''
Load command 8
      cmd LC_BUILD_VERSION
 platform 1
    minos 12.0
      sdk 16.1
Load command 9
      cmd LC_VERSION_MIN_MACOSX
  version 12.10
      sdk 14.1
'''),
        '12.10',
      );
      expect(
        () => macosDeploymentTarget(
          'Load command 0\n cmd LC_BUILD_VERSION\n platform IOS\n minos 13.0',
        ),
        throwsFormatException,
      );
    },
  );
  test('PE import closure names the unresolved dependency', () async {
    final root = await Directory.systemTemp.createTemp('sdk-audit-');
    addTearDown(() => root.delete(recursive: true));
    final app = await File(
      p.join(root.path, 'app.exe'),
    ).writeAsBytes(fixture('missing.dll'));
    await expectLater(
      auditHostBinaries(root, Host.windowsX64, [app]),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('missing.dll'),
        ),
      ),
    );
  });
  test(
    'PE recursively follows packaged companions to their system imports',
    () async {
      final root = await Directory.systemTemp.createTemp('sdk-audit-');
      addTearDown(() => root.delete(recursive: true));
      final app = await File(
        p.join(root.path, 'app.exe'),
      ).writeAsBytes(fixture('companion.dll'));
      await File(
        p.join(root.path, 'companion.dll'),
      ).writeAsBytes(fixture('KERNEL32.DLL'));
      expect(
        (await auditHostBinaries(root, Host.windowsX64, [app])).keys,
        containsAll(['app.exe', 'companion.dll']),
      );
    },
  );
  test('ELF dependency policy records GLIBC 2.36 and rejects 2.38', () {
    const report = '(NEEDED) Shared library: [libc.so.6]\nName: GLIBC_2.36';
    expect(auditElfReport(report)['glibc_versions'], ['2.36']);
    expect(
      () => auditElfReport(report.replaceAll('2.36', '2.38')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('2.38'),
        ),
      ),
    );
  });
}
