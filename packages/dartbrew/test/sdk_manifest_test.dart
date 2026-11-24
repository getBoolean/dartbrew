import 'dart:convert';

import 'package:dartbrew/sdk_manifest.dart';
import 'package:test/test.dart';

/// An `sdk.json` in the shape the current SDK bundler writes, trimmed to a
/// few files.
Map<String, Object?> _installedShape() => {
  'schema': 2,
  'version': '0.1.0-preview.5',
  'host': 'windows-x64',
  'tools': {
    'snapshot': 'bin/gen_snapshot.exe',
    'kernel': 'bin/ctr-kernel.exe',
    'dart': 'host-dart/bin/dart.exe',
  },
  'runtime': {
    'sdk_head': 'a8149c03bcb81c6bca9f044ff10a537bc8d5d675',
    'platform': 'lib/platform.dill',
    'snapshot_hash': 'c5e274828bf37a90359bd3b0753e3eb2',
    'compile_plan': 'compile-plan.json',
    'native_src': 'native-src',
    'link_template': ['-o', '{elf}', '{runtime}'],
    'modes': {
      for (final mode in ['aot', 'jit'])
        mode: {'compatibility': (mode == 'aot' ? 'e' : '9') * 64},
    },
    'devkitpro': {'devkitARM': 'r68-1', 'libctru': '2.7.0-1'},
  },
  'snapshot_hash': 'c5e274828bf37a90359bd3b0753e3eb2',
  'files': {'bin/gen_snapshot.exe': '8' * 64, 'compile-plan.json': 'd' * 64},
  'corresponding_source': {'asset': 'source.zip', 'sha256': '0' * 64},
  'executable_paths': ['bin/gen_snapshot.exe'],
};

Matcher _formatError(Matcher message) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', message),
);

void main() {
  test('reads the installed SDK shape into typed fields', () {
    final manifest = SdkManifest.fromJson(_installedShape());
    expect(manifest.host, 'windows-x64');
    expect(manifest.tools[SdkTool.snapshot], 'bin/gen_snapshot.exe');
    expect(manifest.runtime.jit.compatibility, '9' * 64);
    expect(manifest.runtime.linkTemplate, ['-o', '{elf}', '{runtime}']);
    expect(manifest.runtime.devkitPro.libctru, '2.7.0-1');
    expect(manifest.files[manifest.runtime.compilePlan], 'd' * 64);
  });

  test('legacy prebuilt SDKs are rejected before reading runtime fields', () {
    expect(
      () => SdkManifest.fromJson({'schema': 1}),
      _formatError(
        allOf(
          contains('schema 1 is not supported'),
          contains('update dartbrew'),
        ),
      ),
    );
  });

  test('a manifest written and read back is equal', () {
    final json = _installedShape()
      ..remove('version')
      ..remove('snapshot_hash')
      ..remove('corresponding_source')
      ..remove('executable_paths');
    final written = jsonDecode(jsonEncode(SdkManifest.fromJson(json).toJson()));
    expect(written, json);
    expect(
      jsonEncode(SdkManifest.fromJson(written).toJson()),
      jsonEncode(written),
    );
  });

  test('a manifest without a compile plan names the key and the fix', () {
    final json = _installedShape();
    (json['runtime']! as Map).remove('compile_plan');
    expect(
      () => SdkManifest.fromJson(json),
      _formatError(
        allOf(
          contains('missing `runtime.compile_plan`'),
          contains('update dartbrew'),
        ),
      ),
    );
  });

  test('a mistyped key is named', () {
    final json = _installedShape();
    (json['runtime']! as Map)['link_template'] = 'ld';
    expect(
      () => SdkManifest.fromJson(json),
      _formatError(
        contains('`runtime.link_template` must be a list of strings'),
      ),
    );
  });
}
