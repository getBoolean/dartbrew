import 'dart:io';

import 'package:dartbrew/src/devkitpro.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ctr_build_stubs.dart';

void main() {
  test(
    'DEVKITARM alone selects compiler and libctru from the same install',
    () async {
      final sdk = ctrBuildSdk();
      final root = sdk.environment['DEVKITPRO']!;
      final arm = p.join(root, 'devkitARM');
      final install = await DevkitPro.discover(
        environment: {'DEVKITARM': arm},
        start: startBuildStub,
      );
      expect(p.equals(install.root, root), isTrue);
      expect(p.equals(install.armRoot, arm), isTrue);
      expect(p.isWithin(arm, install.tool('gcc')), isTrue);
      for (final name in [
        '3dsx.ld',
        '3dsx_crt0.o',
        'crti.o',
        'crtbegin.o',
        'crtend.o',
        'crtn.o',
        'libstdc++.a',
        'libm.a',
        'libgcc.a',
        'libc.a',
        'libsysbase.a',
      ]) {
        expect(
          p.equals(await install.targetFile(name), p.join(arm, 'lib', name)),
          isTrue,
          reason: name,
        );
      }
      expect(
        p.equals(
          await install.targetFile('libctru.a'),
          p.join(root, 'libctru', 'lib', 'libctru.a'),
        ),
        isTrue,
      );
      expect(install.versions.devkitARM, 'r68-1');
      expect(install.versions.libctru, '2.7.1-1');
    },
  );

  test(
    'the updater mount on Windows resolves outside the default drive path',
    () async {
      final sdk = ctrBuildSdk();
      final root = sdk.environment['DEVKITPRO']!;
      final echo = File(p.join(sdk.root.path, 'echo.dart'))
        ..writeAsStringSync(
          'void main(List<String> args) => print(args.single);',
        );
      final install = await DevkitPro.discover(
        environment: {
          'DEVKITPRO': '/opt/devkitpro',
          'DEVKITARM': '/opt/devkitpro/devkitARM',
        },
        start:
            (
              exe,
              args, {
              workingDirectory,
              environment,
              mode = ProcessStartMode.normal,
            }) async {
              final output = switch (p.basename(exe).toLowerCase()) {
                'reg.exe' => '    InstallLocation    REG_SZ    $root',
                'cygpath.exe' =>
                  args.last.endsWith('devkitARM')
                      ? p.join(root, 'devkitARM')
                      : root,
                'pacman.exe' => 'devkitARM r68-1\nlibctru 2.7.1-1',
                _ => throw StateError('Unexpected tool $exe'),
              };
              expect(p.isAbsolute(exe), isTrue);
              return Process.start(Platform.resolvedExecutable, [
                echo.path,
                output,
              ]);
            },
      );
      expect(p.equals(install.root, root), isTrue);
      expect(install.versions.devkitARM, 'r68-1');
    },
    skip: !Platform.isWindows,
  );

  test(
    'package queries for a nondefault Unix root read its own database',
    () async {
      final sdk = ctrBuildSdk();
      final root = sdk.environment['DEVKITPRO']!;
      final install = await DevkitPro.discover(
        environment: sdk.environment,
        start:
            (
              exe,
              args, {
              workingDirectory,
              environment,
              mode = ProcessStartMode.normal,
            }) async {
              if (!args.contains('--dbpath') ||
                  !args.contains(
                    p.join(root, 'pacman', 'var', 'lib', 'pacman'),
                  )) {
                fail(
                  'A global package database cannot identify this installation',
                );
              }
              return startBuildStub(exe, args);
            },
      );
      expect(install.versions.devkitARM, 'r68-1');
    },
    skip: Platform.isWindows,
  );

  test('unavailable package manager leaves package releases unknown', () async {
    final install = await DevkitPro.discover(
      environment: ctrBuildSdk().environment,
      start:
          (
            exe,
            args, {
            workingDirectory,
            environment,
            mode = ProcessStartMode.normal,
          }) async {
            throw ProcessException(exe, args, 'Package manager absent');
          },
    );
    expect(install.versions.devkitARM, 'unknown');
    expect(install.versions.libctru, 'unknown');
  });

  test(
    'an explicit missing install names the variables and installation guide',
    () async {
      final missing = p.join(
        Directory.systemTemp.path,
        'absent-devkitpro-test',
        'no-sdk',
      );
      await expectLater(
        DevkitPro.discover(environment: {'DEVKITPRO': missing}),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('DEVKITPRO') &&
                e.toString().contains('DEVKITARM') &&
                e.toString().contains('devkitpro.org'),
          ),
        ),
      );
    },
  );
}
