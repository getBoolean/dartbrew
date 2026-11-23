import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartbrew/src/devkitpro.dart';
import 'package:dartbrew/src/errors.dart';
import 'package:dartbrew/src/sdk.dart';
import 'package:dartbrew/src/targets/ctr/native_build.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/ctr_build_stubs.dart';
import 'support/fake_sdk.dart';

const _targetFlags = [
  '-marm',
  '-march=armv6k',
  '-mfpu=vfp',
  '-mfloat-abi=hard',
  '-mtp=soft',
];

FakeSdk _sources({bool longResponse = false}) {
  final units = [
    for (final group in ['runtime', 'io', 'launcher', 'check'])
      {
        'compiler': 'g++',
        'source': '$group.cc',
        'flags': [
          ..._targetFlags,
          '-I@src@/include with spaces',
          if (longResponse && group == 'check')
            for (var i = 0; i < 1600; i++) '-DDARTBREW_LONG_COMMAND_PROBE_$i=1',
        ],
        'group': group,
      },
  ];
  return fakeSdk(
    assets: {
      'compile-plan.json': jsonEncode({
        'schema': 1,
        'cflags': _targetFlags,
        'soft_math_source': 'math.cc',
        'modes': {'aot': units, 'jit': units},
      }),
      for (final group in ['runtime', 'io', 'launcher', 'check'])
        'native-src/$group.cc':
            '#include "values.h"\nstatic_assert(sizeof(int) == expected);\nint ${group}Value = 1;\n',
      'native-src/include with spaces/values.h':
          'constexpr int expected = 4;\n',
      'native-src/math.cc': File(
        '../../toolchain/soft_math_bridge.cc',
      ).readAsStringSync(),
    },
  );
}

/// A tool invocation blocked in startup; completion is driven by killing the
/// returned process. No OS process or file can outlive a failed test.
final class _Pending implements Process {
  final _exit = Completer<int>();
  final String output;
  _Pending([this.output = '']);
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_exit.isCompleted) return false;
    _exit.complete(1);
    return true;
  }

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(output));
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => throw UnsupportedError('No stdin');
  @override
  int get pid => throw UnsupportedError('No PID');
}

Future<DevkitPro> _tools(Directory root) async {
  for (final tool in ['gcc', 'g++', 'ar']) {
    final name = 'arm-none-eabi-$tool${Platform.isWindows ? '.exe' : ''}';
    File(
      p.join(root.path, 'devkitARM', 'bin', name),
    ).createSync(recursive: true);
  }
  return DevkitPro.discover(
    environment: {'DEVKITPRO': root.path},
    start:
        (
          exe,
          args, {
          workingDirectory,
          environment,
          mode = ProcessStartMode.normal,
        }) async {
          throw ProcessException(exe, args, 'missing pacman');
        },
  );
}

void main() {
  late Directory work;
  late Directory cache;
  setUp(() {
    work = Directory.systemTemp.createTempSync('native build test ');
    cache = Directory(p.join(work.path, 'cache'));
    addTearDown(() => work.deleteSync(recursive: true));
  });

  test(
    'local package updates invalidate the cache even without pacman',
    () async {
      final fixture = ctrBuildSdk();
      final sdk = await NativeSdk.load(fixture.root.path);
      Future<String> build({
        String? revision,
        Stream<Object?>? interrupts,
      }) async {
        final installation = await DevkitPro.discover(
          environment: fixture.environment,
          start:
              (
                exe,
                args, {
                workingDirectory,
                environment,
                mode = ProcessStartMode.normal,
              }) async {
                if (revision == null) {
                  throw ProcessException(exe, args, 'pacman unavailable');
                }
                return _Pending('devkitARM $revision\nlibctru 2.7.1-1')
                  .._exit.complete(0);
              },
        );
        return (await NativeBuild(
              sdk: sdk,
              devkitPro: installation,
              start: startBuildStub,
              cacheDirectory: cache,
            ).build(
              mode: 'aot',
              sdkManifestSha256: payloadDigest,
              interrupts: interrupts,
            ))
            .runtimeArchive;
      }

      final oldRelease = await build(revision: 'r68');
      await expectLater(
        build(revision: 'r68', interrupts: Stream<Object?>.value(null)),
        throwsA(
          isA<DartbrewException>().having(
            (e) => e.exitCode,
            'cancelled cache hit',
            130,
          ),
        ),
      );
      final newRelease = await build(revision: 'r69');
      expect(oldRelease, isNot(newRelease));
      final before = await build();
      final header = File(
        p.join(
          fixture.environment['DEVKITPRO']!,
          'libctru',
          'include',
          'types.h',
        ),
      );
      header.createSync(recursive: true);
      header.writeAsStringSync('updated header');
      final after = await build();
      expect(before, isNot(after));
      expect(await build(), after);
      expect(File(oldRelease).existsSync(), isTrue);
    },
  );

  test(
    'an offset assertion reports its unit, compiler message and both version sets',
    () async {
      final sdk = await NativeSdk.load(_sources().root.path);
      final install = await _tools(work);
      final build = NativeBuild(
        sdk: sdk,
        devkitPro: install,
        cacheDirectory: cache,
        start:
            (
              exe,
              args, {
              workingDirectory,
              environment,
              mode = ProcessStartMode.normal,
            }) async {
              final response = File(
                args.single.substring(1),
              ).readAsStringSync();
              if (response.contains('check.cc')) {
                throw ProcessException(
                  exe,
                  args,
                  'static assertion: Thread_entry_point',
                  1,
                );
              }
              final output = response.trimRight().split('\n').last;
              File(
                output.substring(1, output.length - 1).replaceAll(r'\\', r'\'),
              ).createSync();
              final child = _Pending().._exit.complete(0);
              return child;
            },
      );
      await expectLater(
        build.build(mode: 'aot', sdkManifestSha256: payloadDigest),
        throwsA(
          isA<DartbrewException>().having(
            (e) => e.message,
            'error',
            allOf(
              contains('check.cc'),
              contains('Thread_entry_point'),
              contains('Installed'),
              contains('Qualified'),
            ),
          ),
        ),
      );
      expect(cache.listSync().map((entry) => p.basename(entry.path)), [
        '.locks',
      ]);
    },
  );

  test(
    'cancelling during process startup reaps every late child and removes staging',
    () async {
      final sdk = await NativeSdk.load(_sources().root.path);
      final install = await _tools(work);
      final spawn = Completer<void>();
      final proceed = Completer<void>();
      final children = <_Pending>[];
      final interrupts = StreamController<Object?>(sync: true);
      final build = NativeBuild(
        sdk: sdk,
        devkitPro: install,
        cacheDirectory: cache,
        start:
            (
              exe,
              args, {
              workingDirectory,
              environment,
              mode = ProcessStartMode.normal,
            }) async {
              if (!spawn.isCompleted) spawn.complete();
              await proceed.future;
              final child = _Pending();
              children.add(child);
              return child;
            },
      );
      final result = expectLater(
        build.build(
          mode: 'aot',
          sdkManifestSha256: payloadDigest,
          interrupts: interrupts.stream,
        ),
        throwsA(
          isA<DartbrewException>().having((e) => e.exitCode, 'exit code', 130),
        ),
      );
      await spawn.future;
      await interrupts.close();
      proceed.complete();
      await result;
      expect(children, isNotEmpty);
      expect(
        await Future.wait(children.map((p) => p.exitCode)),
        everyElement(1),
      );
      expect(cache.listSync().map((entry) => p.basename(entry.path)), [
        '.locks',
      ]);
    },
  );

  test(
    'rejects a changed sealed header before launching any compiler',
    () async {
      final fixture = _sources();
      File(
        p.join(
          fixture.root.path,
          'native-src',
          'include with spaces',
          'values.h',
        ),
      ).writeAsStringSync('unsealed');
      final sdk = await NativeSdk.load(fixture.root.path);
      final build = NativeBuild(
        sdk: sdk,
        devkitPro: await _tools(work),
        cacheDirectory: cache,
        start:
            (
              exe,
              args, {
              workingDirectory,
              environment,
              mode = ProcessStartMode.normal,
            }) async => fail('started $exe'),
      );
      await expectLater(
        build.build(mode: 'aot', sdkManifestSha256: payloadDigest),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('values.h'),
          ),
        ),
      );
      expect(cache.listSync().map((entry) => p.basename(entry.path)), [
        '.locks',
      ]);
    },
  );

  final skipNative =
      Platform.environment['DARTBREW_NATIVE_BUILD_INTEGRATION'] == '1'
      ? false
      : 'Set DARTBREW_NATIVE_BUILD_INTEGRATION=1 for the installed devkitPro.';
  test(
    'an omitted transitive header fails the actual native build before publication',
    () async {
      final fixture = _sources()
        ..editManifest((doc) {
          final files = doc['files']! as Map<String, Object?>;
          files.remove('native-src/include with spaces/values.h');
        });
      final sdk = await NativeSdk.load(fixture.root.path);
      final build = NativeBuild(
        sdk: sdk,
        devkitPro: await DevkitPro.discover(),
        cacheDirectory: cache,
      );
      await expectLater(
        build.build(mode: 'aot', sdkManifestSha256: sdk.manifestSha256),
        throwsA(
          isA<DartbrewException>().having(
            (e) => e.message,
            'compiler diagnostic',
            contains('values.h'),
          ),
        ),
      );
      expect(cache.listSync().map((entry) => p.basename(entry.path)), [
        '.locks',
      ]);
    },
    skip: skipNative,
  );
  test(
    'installed compiler builds, archives and reuses a sealed source bundle',
    () async {
      final fixture = _sources(longResponse: true);
      final sdk = await NativeSdk.load(fixture.root.path);
      final install = await DevkitPro.discover();
      final build = NativeBuild(
        sdk: sdk,
        devkitPro: install,
        cacheDirectory: cache,
      );
      final artifacts = await build.build(
        mode: 'aot',
        sdkManifestSha256: payloadDigest,
      );
      for (final file in [artifacts.ioArchive, artifacts.runtimeArchive]) {
        expect(
          ascii.decode(File(file).readAsBytesSync().take(8).toList()),
          '!<arch>\n',
        );
      }
      for (final file in [
        artifacts.launcherObjects.single,
        artifacts.softMath,
      ]) {
        expect(File(file).readAsBytesSync().take(4), [0x7f, 0x45, 0x4c, 0x46]);
      }
      final hit = await NativeBuild(
        sdk: sdk,
        devkitPro: install,
        cacheDirectory: cache,
        start:
            (
              exe,
              args, {
              workingDirectory,
              environment,
              mode = ProcessStartMode.normal,
            }) async => fail('rebuilt'),
      ).build(mode: 'aot', sdkManifestSha256: payloadDigest);
      expect(hit.runtimeArchive, artifacts.runtimeArchive);
      final other = await build.build(mode: 'aot', sdkManifestSha256: '0' * 64);
      expect(other.runtimeArchive, isNot(artifacts.runtimeArchive));
      expect(File(artifacts.runtimeArchive).existsSync(), isTrue);
    },
    skip: skipNative,
  );
}
