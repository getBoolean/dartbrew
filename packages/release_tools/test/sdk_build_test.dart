import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/build_identity.dart';
import 'package:release_tools/src/sdk_build.dart';
import 'package:test/test.dart';

import 'support/sample_toolchain.dart';

const pinned = (gcc: '16.1.0', devkitArm: 'r68-1', libctru: '2.7.0-1');

void main() {
  late Directory directory;
  late List<String> stages;
  late SdkBuildRequest request;

  Future<void> recordStage(
    String executable,
    List<String> arguments,
    String stage, {
    String? workingDirectory,
  }) async => stages.add(stage);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('sdk-build-');
    addTearDown(() => directory.deleteSync(recursive: true));
    stages = [];
    final source = p.join(directory.path, 'sdk');
    final gn = File(p.join(source, 'buildtools', 'gn'))
      ..createSync(recursive: true)
      ..writeAsStringSync('pinned gn');
    final manifest = sampleManifest()
      ..['dependencies'] = {
        'gn': {
          'hosts': {
            'linux-x64': {
              'binary_sha256': sha256.convert(gn.readAsBytesSync()).toString(),
            },
          },
        },
      };
    File(p.join(directory.path, 'ctr.specs')).writeAsStringSync('specs');
    final profileFile = File(p.join(directory.path, 'target-ctr.json'))
      ..writeAsStringSync(jsonEncode(sampleProfile()));
    final profile = TargetProfile.load(profileFile);
    request = SdkBuildRequest(
      source: source,
      manifestFile: File(p.join(directory.path, 'versions.json')),
      manifest: manifest,
      profile: profile,
      identity: BuildIdentity.of(
        manifest: manifest,
        profile: profile,
        component: SdkComponent.target,
        mode: BuildMode.aot,
      ),
      bootstrapScript: File('bootstrap.py'),
      outputRoot: p.join(directory.path, 'out'),
      scope: SdkBuildScope.build,
    );
  });

  test(
    'args.gn carries exactly the four CTR arguments from the profile',
    () async {
      final output = await buildSdk(
        request,
        runStage: recordStage,
        queryToolchain: (_) async => pinned,
      );
      final lines = File(p.join(output.path, 'args.gn')).readAsLinesSync();
      expect(lines.where((line) => line.startsWith('ctr_')), [
        'ctr_compiler_prefix = "/opt/devkitpro/devkitARM/bin/arm-none-eabi-"',
        'ctr_libctru = "/opt/devkitpro/libctru"',
        'ctr_cflags = ["-marm","-march=armv6k","-mfpu=vfp","-mfloat-abi=hard"]',
        'ctr_specs_file = ${jsonEncode(p.join(directory.path, 'ctr.specs'))}',
      ]);
      expect(lines, contains('target_os = "ctr"'));
      expect(lines, contains('arm_version = 6'));
      expect(stages, ['verify', 'gn', 'ninja']);
    },
  );

  test('a devkitARM that differs from the pin fails before GN runs', () async {
    final failure = buildSdk(
      request,
      runStage: recordStage,
      queryToolchain: (_) async =>
          (gcc: pinned.gcc, devkitArm: 'r69-1', libctru: pinned.libctru),
    );
    await expectLater(
      failure,
      throwsA(
        isA<SdkBuildFailure>().having(
          (failure) => failure.message,
          'message',
          allOf(contains('r69-1'), contains('r68-1')),
        ),
      ),
    );
    expect(stages, ['verify']);
    expect(
      File(p.join(request.outputDirectory.path, 'args.gn')).existsSync(),
      isFalse,
    );
  });
}
