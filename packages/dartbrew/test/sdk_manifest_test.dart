import 'dart:convert';

import 'package:dartbrew/sdk_manifest.dart';
import 'package:test/test.dart';

/// An `sdk.json` in the shape the current SDK bundler writes, trimmed to a
/// few files.
Map<String, Object?> _installedShape() => {
  'schema': 1,
  'version': '0.1.0-preview.4',
  'host': 'windows-x64',
  'tools': {
    'snapshot': 'bin/gen_snapshot.exe',
    'kernel': 'bin/ctr-kernel.exe',
    'as': 'bin/ctr-as.exe',
    'ld': 'bin/ctr-ld.exe',
    'dart': 'host-dart/bin/dart.exe',
  },
  'runtime': {
    'sdk_head': 'a8149c03bcb81c6bca9f044ff10a537bc8d5d675',
    'platform': 'lib/platform.dill',
    'modes': {
      for (final mode in ['aot', 'jit'])
        mode: {
          'compatibility': (mode == 'aot' ? 'e' : '9') * 64,
          'objects': ['lib/$mode/embedder.o', 'lib/$mode/main.o'],
          'archive': 'lib/$mode/runtime.a',
          'io_archive': 'lib/$mode/io.a',
        },
    },
    'link': {
      'layout': 'lib/shared/3dsx.ld',
      'math': 'lib/shared/soft-math.o',
      'startup': ['lib/shared/3dsx_crt0.o', 'lib/shared/crti.o'],
      'libraries': ['lib/shared/libctru.a', 'lib/shared/libm.a'],
      'grouped': ['lib/shared/libgcc.a', 'lib/shared/libc.a'],
      'end': ['lib/shared/crtend.o', 'lib/shared/crtn.o'],
    },
  },
  'snapshot_hash': 'c5e274828bf37a90359bd3b0753e3eb2',
  'files': {'bin/ctr-as.exe': '8' * 64, 'lib/aot/io.a': 'd' * 64},
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
    expect(manifest.tools[SdkTool.linker], 'bin/ctr-ld.exe');
    expect(manifest.runtime.jit.ioArchive, 'lib/jit/io.a');
    expect(manifest.runtime.aot.objects, [
      'lib/aot/embedder.o',
      'lib/aot/main.o',
    ]);
    expect(manifest.runtime.link.end.last, 'lib/shared/crtn.o');
    expect(manifest.files['lib/aot/io.a'], 'd' * 64);
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

  test('a manifest without io_archive names the key and the fix', () {
    final json = _installedShape();
    final aot = ((json['runtime']! as Map)['modes']! as Map)['aot']! as Map;
    aot.remove('io_archive');
    expect(
      () => SdkManifest.fromJson(json),
      _formatError(
        allOf(
          contains('missing `runtime.modes.aot.io_archive`'),
          contains('update dartbrew'),
        ),
      ),
    );
  });

  test('a mistyped key is named', () {
    final json = _installedShape();
    ((json['runtime']! as Map)['link']! as Map)['startup'] = 'crt0.o';
    expect(
      () => SdkManifest.fromJson(json),
      _formatError(
        contains('`runtime.link.startup` must be a list of strings'),
      ),
    );
  });
}
