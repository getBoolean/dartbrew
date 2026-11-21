import 'dart:io';

import 'package:path/path.dart' as p;

import 'elf_fixture.dart';
import 'fake_sdk.dart';

/// Wraps a stub process and writes the tool's output files once it exits,
/// so later stages and the 3DSX encoder find them.
class _Materializing implements Process {
  final Process _p;
  @override
  final Future<int> exitCode;
  _Materializing(this._p, this.exitCode);
  @override
  Stream<List<int>> get stdout => _p.stdout;
  @override
  Stream<List<int>> get stderr => _p.stderr;
  @override
  IOSink get stdin => _p.stdin;
  @override
  int get pid => _p.pid;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => _p.kill(signal);
}

/// A process starter for [ctrBuildSdk] stubs that also writes each tool's
/// output: the package config for `dart`, the kernel, the AOT assembly,
/// objects, and a linked ELF for `ld`.
Future<Process> startBuildStub(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  ProcessStartMode mode = ProcessStartMode.normal,
}) async {
  final process = await startStub(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  final tool = p.basenameWithoutExtension(executable);
  String after(String flag) => arguments[arguments.indexOf(flag) + 1];
  String prefixed(String prefix) => arguments
      .firstWhere((a) => a.startsWith(prefix))
      .substring(prefix.length);
  return _Materializing(
    process,
    process.exitCode.then((code) {
      switch (tool) {
        case 'dart':
          File(p.join(workingDirectory!, '.dart_tool/package_config.json'))
            ..createSync(recursive: true)
            ..writeAsStringSync('{}');
        case 'kernel':
          File(prefixed('--output=')).writeAsStringSync('kernel bytes');
        case 'snapshot':
          File(prefixed('--assembly=')).writeAsStringSync('aot assembly');
        case 'as':
          File(after('-o')).writeAsStringSync('object');
        case 'ld':
          File(after('-o')).writeAsBytesSync(linkedElfFixture());
      }
      return code;
    }),
  );
}

/// A fake SDK with stub build tools and a complete CTR `runtime` manifest.
FakeSdk ctrBuildSdk() => fakeSdk(
  tools: {'dart': 0, 'kernel': 0, 'snapshot': 0, 'as': 0, 'ld': 0},
  assets: {
    for (final name in [
      'runtime/platform.dill',
      'runtime/layout.ld',
      'runtime/crt0.o',
      'runtime/aot.o',
      'runtime/jit.o',
      'runtime/aot.a',
      'runtime/jit.a',
      'runtime/aot-io.a',
      'runtime/jit-io.a',
      'runtime/libm.a',
      'runtime/libctru.a',
      'runtime/libc.a',
      'runtime/crtend.o',
      'notices/LICENSE.txt',
    ])
      name: name,
  },
  runtime: {
    'platform': 'runtime/platform.dill',
    'sdk_head': 'head',
    'modes': {
      for (final mode in ['aot', 'jit'])
        mode: {
          'compatibility': (mode == 'aot' ? 'a' : 'b') * 64,
          'objects': ['runtime/$mode.o'],
          'archive': 'runtime/$mode.a',
          'io_archive': 'runtime/$mode-io.a',
        },
    },
    'link': {
      'layout': 'runtime/layout.ld',
      'startup': ['runtime/crt0.o'],
      'math': 'runtime/libm.a',
      'libraries': ['runtime/libctru.a'],
      'grouped': ['runtime/libc.a'],
      'end': ['runtime/crtend.o'],
    },
  },
);
