import 'dart:io';

import 'package:dartbrew/sdk_manifest.dart';
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

/// A fake SDK with stub build tools and every [fakeRuntime] file sealed.
FakeSdk ctrBuildSdk() => fakeSdk(
  tools: {for (final tool in SdkTool.values) tool.key: 0},
  assets: {
    for (final name in [
      fakeRuntime.platform,
      for (final mode in [fakeRuntime.aot, fakeRuntime.jit]) ...[
        ...mode.objects,
        mode.archive,
        mode.ioArchive,
      ],
      fakeRuntime.link.layout,
      fakeRuntime.link.math,
      ...fakeRuntime.link.startup,
      ...fakeRuntime.link.libraries,
      ...fakeRuntime.link.grouped,
      ...fakeRuntime.link.end,
      'notices/LICENSE.txt',
    ])
      name: name,
  },
);
