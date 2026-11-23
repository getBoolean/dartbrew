import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartbrew/src/commands/doctor.dart';
import 'package:dartbrew/src/sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ctr_build_stubs.dart';
import 'support/fake_sdk.dart';

Matcher _formatError(Object message) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', message),
);

void main() {
  test('a correctly sealed SDK loads', () async {
    final sdk = await NativeSdk.load(fakeSdk().root.path);
    expect(File(sdk.asset('bin/tool')).readAsStringSync(), payload);
  });

  group('SDK load rejects', () {
    final cases = <String, Directory Function()>{
      'a digest that is not lowercase SHA-256': () =>
          fakeSdk(files: {'bin/tool': payloadDigest.toUpperCase()}).root,
      'another native host': () => fakeSdk(host: 'plan9-x64').root,
      'an unknown schema': () =>
          (fakeSdk()..editManifest((json) => json['schema'] = 99)).root,
      'no sealed assets': () => fakeSdk(files: {}).root,
      'an absolute asset path': () =>
          fakeSdk(files: {'/bin/tool': payloadDigest}).root,
      'a backslash asset path': () =>
          fakeSdk(files: {r'bin\tool': payloadDigest}).root,
      'an empty path segment': () =>
          fakeSdk(files: {'bin//tool': payloadDigest}).root,
      'a parent-directory escape': () =>
          fakeSdk(files: {'../owner': '0' * 64}).root,
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        await expectLater(
          NativeSdk.load(entry.value().path),
          throwsFormatException,
        );
      });
    }
  });

  test('SDK load names a missing manifest key', () async {
    final sdk = fakeSdk()
      ..editManifest((json) => (json['tools']! as Map).remove('kernel'));
    await expectLater(
      NativeSdk.load(sdk.root.path),
      _formatError(
        allOf(contains('`tools.kernel`'), contains('update dartbrew')),
      ),
    );
  });

  group('asset verification on use', () {
    test('a modified asset loads but fails when resolved', () async {
      final root = fakeSdk(assets: {'lib/other': 'other'}).root;
      File(p.join(root.path, 'bin', 'tool')).writeAsStringSync('tampered');
      final sdk = await NativeSdk.load(root.path);
      expect(File(sdk.asset('lib/other')).readAsStringSync(), 'other');
      expect(
        () => sdk.asset('bin/tool'),
        _formatError('SDK asset hash mismatch: bin/tool'),
      );
    });

    test('verifyAllAssets names a modified asset', () async {
      final root = fakeSdk().root;
      File(p.join(root.path, 'bin', 'tool')).writeAsStringSync('tampered');
      final sdk = await NativeSdk.load(root.path);
      expect(
        sdk.verifyAllAssets,
        _formatError('SDK asset hash mismatch: bin/tool'),
      );
    });

    test('an asset symlink that leaves the SDK is rejected', () async {
      final outside = Directory.systemTemp.createTempSync('dartbrew-outside-');
      addTearDown(() => outside.deleteSync(recursive: true));
      final target = File(p.join(outside.path, 'tool'))
        ..writeAsStringSync(payload);
      final root = fakeSdk(files: {'bin/link': payloadDigest}).root;
      try {
        Link(p.join(root.path, 'bin', 'link')).createSync(target.path);
      } on FileSystemException {
        markTestSkipped('Host does not permit creating symbolic links.');
        return;
      }
      final sdk = await NativeSdk.load(root.path);
      expect(
        () => sdk.asset('bin/link'),
        _formatError('SDK asset escapes its directory: bin/link'),
      );
    });
  });

  test('doctor names a modified asset no build reads', () async {
    final sdk = ctrBuildSdk();
    File(p.join(sdk.root.path, 'bin', 'tool')).writeAsStringSync('tampered');
    final runner = CommandRunner<int>('dartbrew', '')
      ..addCommand(DoctorCommand());
    await expectLater(
      runner.run(['doctor', '--sdk', sdk.root.path]),
      _formatError('SDK asset hash mismatch: bin/tool'),
    );
  });

  group('quick verification', () {
    test('never hashes assets', () async {
      final root = fakeSdk(tools: {'dart': 0}).root;
      File(
        p.join(root.path, 'tools', 'dart.dart'),
      ).writeAsStringSync('changed');
      final sdk = await NativeSdk.load(root.path, quick: true);
      expect(sdk.tool('dart'), endsWith('dart.dart'));
    });

    test('rejects an SDK whose dart tool is missing', () async {
      final root = fakeSdk(tools: {'dart': 0}).root;
      File(p.join(root.path, 'tools', 'dart.dart')).deleteSync();
      await expectLater(
        NativeSdk.load(root.path, quick: true),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.path,
            'path',
            contains('dart.dart'),
          ),
        ),
      );
    });

    test('still rejects another native host', () async {
      await expectLater(
        NativeSdk.load(
          fakeSdk(host: 'plan9-x64', tools: {'dart': 0}).root.path,
          quick: true,
        ),
        throwsFormatException,
      );
    });
  });
}
