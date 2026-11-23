import 'dart:io';

import 'package:dartbrew/src/targets/ctr/soft_math.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _cflags = [
  '-marm',
  '-march=armv6k',
  '-mtune=mpcore',
  '-mfpu=vfp',
  '-mfloat-abi=hard',
  '-mtp=soft',
];

void main() {
  late Directory work;
  late File source;

  setUp(() {
    work = Directory.systemTemp.createTempSync('dartbrew soft math ');
    source = File(p.join(work.path, 'bridge.cc'))..createSync();
    addTearDown(() => work.deleteSync(recursive: true));
  });

  test(
    'names the missing soft-float library and leaves no build output',
    () async {
      await expectLater(
        buildSoftMath(
          tool: (name) => name,
          cflags: _cflags,
          source: source,
          output: work,
          run: (_, _) async => 'libm.a\n',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('libm.a'),
          ),
        ),
      );
      expect(work.listSync().map((f) => p.basename(f.path)), ['bridge.cc']);
    },
  );

  final integration = Platform.environment['CTR_SOFT_MATH_INTEGRATION'] == '1';
  group(
    'installed devkitARM',
    () {
      Future<File> build() {
        final bin = p.join(Platform.environment['DEVKITARM']!, 'bin');
        return buildSoftMath(
          tool: (name) => p.join(
            bin,
            'arm-none-eabi-$name${Platform.isWindows ? '.exe' : ''}',
          ),
          cflags: _cflags,
          source: source,
          output: work,
          run: (exe, args) async {
            final result = await Process.run(exe, args);
            if (result.exitCode != 0) {
              throw ProcessException(
                exe,
                args,
                result.stderr.toString(),
                result.exitCode,
              );
            }
            return result.stdout.toString();
          },
        );
      }

      setUp(() {
        File('../../toolchain/soft_math_bridge.cc').copySync(source.path);
      });

      test(
        'derives and audits a hard-float ARM object from local libm',
        () async {
          final object = await build();
          expect(await object.openRead(0, 4).first, [0x7f, 0x45, 0x4c, 0x46]);
          expect(
            work.listSync().map((f) => p.basename(f.path)),
            unorderedEquals(['bridge.cc', 'soft-math.o']),
          );
        },
      );

      for (final (caseName, code, rejected) in [
        (
          'unexpected export',
          'extern "C" void UnqualifiedExport() {}',
          'UnqualifiedExport',
        ),
        (
          'unexpected import',
          'extern "C" void UnqualifiedImport();\n'
              'static void __attribute__((used)) extra() { UnqualifiedImport(); }',
          'UnqualifiedImport',
        ),
        (
          'unsupported instruction',
          'static void __attribute__((used)) extra() { asm volatile("vadd.f64 d0,d0,d0"); }',
          'vadd.f64',
        ),
      ]) {
        test('rejects and names an $caseName', () async {
          await source.writeAsString('$code\n', mode: FileMode.append);
          await expectLater(
            build(),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains(rejected),
              ),
            ),
          );
          expect(work.listSync().map((f) => p.basename(f.path)), ['bridge.cc']);
        });
      }
    },
    skip: integration
        ? false
        : 'Set CTR_SOFT_MATH_INTEGRATION=1 and DEVKITARM for native compilation.',
  );
}
