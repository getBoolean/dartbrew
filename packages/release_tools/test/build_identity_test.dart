import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:release_tools/src/build_identity.dart';
import 'package:test/test.dart';

import 'support/sample_toolchain.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('build-identity-');
    addTearDown(() => directory.deleteSync(recursive: true));
  });

  /// Writes [profile] and [specs] into [into] and loads the profile.
  TargetProfile writeProfile({
    Map<String, Object?>? profile,
    String specs = 'composed specs',
    Directory? into,
  }) {
    final target = into ?? directory;
    File(p.join(target.path, 'ctr.specs')).writeAsStringSync(specs);
    final file = File(p.join(target.path, 'target-ctr.json'))
      ..writeAsStringSync(jsonEncode(profile ?? sampleProfile()));
    return TargetProfile.load(file);
  }

  String keyOf({
    Map<String, Object?>? manifest,
    TargetProfile? profile,
    SdkComponent component = SdkComponent.target,
    BuildMode mode = BuildMode.aot,
  }) => BuildIdentity.of(
    manifest: manifest ?? sampleManifest(),
    profile: profile ?? writeProfile(),
    component: component,
    mode: mode,
  ).cacheKey;

  group('cache key', () {
    test('is the same for the same inputs', () {
      expect(keyOf(), keyOf());
    });

    test('changes with the compiler prefix', () {
      final initial = keyOf();
      final profile = sampleProfile()
        ..['compiler_prefix'] = '/other/bin/arm-none-eabi-';
      expect(keyOf(profile: writeProfile(profile: profile)), isNot(initial));
    });

    test('changes with the cflags', () {
      final initial = keyOf();
      final profile = sampleProfile()
        ..['cflags'] = [
          ...(sampleProfile()['cflags']! as List<Object?>),
          '-DNEW_PROFILE=1',
        ];
      expect(keyOf(profile: writeProfile(profile: profile)), isNot(initial));
    });

    test('changes with the mode and the component', () {
      final initial = keyOf();
      expect(keyOf(mode: BuildMode.jit), isNot(initial));
      expect(keyOf(component: SdkComponent.precompiler), isNot(initial));
      expect(keyOf(component: SdkComponent.host), isNot(initial));
    });

    test('changes with any pin, such as a patch hash', () {
      final initial = keyOf();
      final manifest = sampleManifest()
        ..['patches'] = [
          {'path': 'patches/dart/0001-fixture.patch', 'sha256': 'b' * 64},
        ];
      expect(keyOf(manifest: manifest), isNot(initial));
    });

    test('changes with the specs file bytes', () {
      final initial = keyOf(profile: writeProfile(specs: 'first specs'));
      expect(
        keyOf(profile: writeProfile(specs: 'changed specs')),
        isNot(initial),
      );
    });

    test('is the same for identical inputs in another directory', () {
      final other = Directory(p.join(directory.path, 'second-location'))
        ..createSync();
      expect(keyOf(profile: writeProfile(into: other)), keyOf());
    });
  });

  group('GN configuration', () {
    BuildIdentity identityOf(SdkComponent component, BuildMode mode) =>
        BuildIdentity.of(
          manifest: sampleManifest(),
          profile: writeProfile(),
          component: component,
          mode: mode,
        );

    test('host builds for Linux x64 without the ARM profile', () {
      final host = identityOf(SdkComponent.host, BuildMode.jit);
      expect(host.gnArgs['target_os'], 'linux');
      expect(host.gnArgs['target_cpu'], 'x64');
      expect(host.gnArgs['is_clang'], true);
      expect(host.gnArgs, isNot(contains('arm_version')));
      expect(host.rootTarget, '//:create_sdk');
    });

    test('target builds for the profile ARM architecture with gcc', () {
      final target = identityOf(SdkComponent.target, BuildMode.aot);
      expect(target.gnArgs, {
        'target_os': 'ctr',
        'target_cpu': 'arm',
        'is_debug': false,
        'is_release': true,
        'is_clang': false,
        'dart_use_crashpad': false,
        'arm_version': 6,
        'arm_fpu': 'vfp',
        'arm_float_abi': 'hard',
        'arm_use_neon': false,
        'arm_use_integer_division': false,
        'dart_use_compressed_pointers': false,
        'dart_target_arch': 'arm',
        'dart_support_perfetto': false,
      });
    });

    test('each component and mode selects its root target', () {
      expect(
        identityOf(SdkComponent.precompiler, BuildMode.aot).rootTarget,
        '//build/ctr:precompiler',
      );
      expect(
        identityOf(SdkComponent.target, BuildMode.aot).rootTarget,
        '//build/ctr:aot_runtime',
      );
      expect(
        identityOf(SdkComponent.target, BuildMode.jit).rootTarget,
        '//build/ctr:jit_runtime',
      );
    });

    test('the precompiler targets CTR ARM', () {
      final precompiler = identityOf(SdkComponent.precompiler, BuildMode.aot);
      expect(precompiler.gnArgs['target_os'], 'ctr');
      expect(precompiler.gnArgs['dart_target_arch'], 'arm');
    });
  });

  test('a profile with two specs files is refused', () {
    final profile = sampleProfile()..['link_specs'] = ['a.specs', 'b.specs'];
    final file = File(p.join(directory.path, 'target-ctr.json'))
      ..writeAsStringSync(jsonEncode(profile));
    expect(() => TargetProfile.load(file), throwsFormatException);
  });
}
