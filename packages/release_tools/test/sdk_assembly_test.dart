import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:release_tools/src/host.dart';
import 'package:release_tools/src/sdk_assembly.dart';
import 'package:test/test.dart';

void main() {
  test(
    'runtime assets cannot disguise compiled ARM objects or archives',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'runtime-assets-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = File.fromUri(directory.uri.resolve('source.inc'));
      final arm = Uint8List(20)..setAll(0, [0x7f, 0x45, 0x4c, 0x46, 1, 1]);
      ByteData.sublistView(arm).setUint16(18, 40, Endian.little);
      for (final bytes in [
        arm,
        ascii.encode('!<arch>\n'),
        ascii.encode('!<thin>\n'),
      ]) {
        await input.writeAsBytes(bytes);
        await expectLater(checkSourceAsset(input), throwsFormatException);
      }
      await input.writeAsString('int main(void) { return 0; }');
      await checkSourceAsset(input);
    },
  );
  final head = '1' * 40;
  final snapshot = 'a' * 32;
  final precompiler = {
    'host': 'linux-x64',
    'source': {'head': head},
    'generated': {
      'git_short_hash': head.substring(0, 10),
      'snapshot_hash': snapshot,
    },
  };
  final runtime = {'sdk_head': head, 'snapshot_hash': snapshot};
  for (final key in ['host', 'sdk_head', 'snapshot_hash']) {
    test('assembly rejects mismatched $key', () {
      expect(
        () => checkComponentIdentity(Host.linuxX64, precompiler, {
          ...runtime,
          key: 'wrong',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(key),
          ),
        ),
      );
    });
  }
  test('cross-host codegen allows just the DWARF producer hostname', () {
    const version = 'Dart SDK version: 3.14 (stable) on "windows_arm"';
    final producer = 'Dart 3.14 (stable) on "windows_arm"\n';
    final listing =
        '.text\n.section .debug_info,""\n.string ${jsonEncode(producer)}\n';
    final expected = sha256
        .convert(utf8.encode(listing.replaceAll('windows_arm', 'linux_arm')))
        .toString();
    expect(
      checkCodegen(
        utf8.encode(listing),
        expected,
        Host.windowsX64,
        version,
      )['match'],
      'dwarf-producer-host-only',
    );
    expect(
      () => checkCodegen(
        utf8.encode('.byte 42\n$listing'),
        expected,
        Host.windowsX64,
        version,
      ),
      throwsFormatException,
    );
  });
}
