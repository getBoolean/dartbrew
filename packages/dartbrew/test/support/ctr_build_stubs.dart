import 'dart:convert';
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
  final tool = p
      .basenameWithoutExtension(executable)
      .replaceFirst('arm-none-eabi-', '');
  if (arguments.length == 1 && arguments.single.startsWith('@')) {
    final words = File(arguments.single.substring(1))
        .readAsLinesSync()
        .map(
          (line) => line.substring(1, line.length - 1).replaceAll(r'\\', r'\'),
        )
        .toList();
    final output = tool == 'ar' ? words[1] : words[words.indexOf('-o') + 1];
    File(output).writeAsStringSync('native $tool output');
    return _QueryResult('');
  }
  if ((tool == 'gcc' || tool == 'g++') &&
      arguments.last.startsWith('-print-file-name=')) {
    final arm = p.dirname(p.dirname(executable));
    return _QueryResult(p.join(arm, 'lib', arguments.last.split('=').last));
  }
  if (tool.endsWith('pacman')) {
    return _QueryResult('devkitARM r68-1\nlibctru 2.7.1-1');
  }
  if (tool == 'nm') {
    if (arguments.first == '-u') return _QueryResult(' U __aeabi_dadd');
    final symbols = arguments.last.endsWith('.a')
        ? ['__ieee754_pow', 'sin', '__ieee754_log']
        : [
            'Pow',
            'Atan2',
            'Sin',
            'Cos',
            'Tan',
            'Asin',
            'Acos',
            'Atan',
            'Exp',
            'Log',
            'Floor',
            'Ceil',
            'Trunc',
            'Round',
          ].map((name) => 'CtrLibm$name');
    return _QueryResult(symbols.map((s) => '$s T 0').join('\n'));
  }
  if (tool == 'readelf') {
    return _QueryResult(
      arguments.first == '-A'
          ? 'Tag_ABI_VFP_args: VFP registers'
          : 'ELF32 little endian\nMachine: ARM',
    );
  }
  if (tool == 'objdump') return _QueryResult(' 0: e12fff1e bx lr');
  if (tool == 'objcopy' ||
      tool == 'g++' ||
      (tool == 'ld' && arguments.contains('-r'))) {
    final output = tool == 'objcopy'
        ? arguments.last
        : arguments[arguments.indexOf('-o') + 1];
    File(output).writeAsStringSync('soft math output');
    return _QueryResult('');
  }
  if (tool == 'as' || tool == 'ld') {
    final arm = p.dirname(p.dirname(executable));
    executable = p.join(p.dirname(p.dirname(arm)), 'tools', '$tool.dart');
  }
  final process = await startStub(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

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
FakeSdk ctrBuildSdk() {
  final units = [
    for (final group in ['runtime', 'io', 'launcher', 'check'])
      {
        'compiler': 'g++',
        'source': '$group.cc',
        'flags': <String>[],
        'group': group,
      },
  ];
  final sdk = fakeSdk(
    tools: {for (final tool in SdkTool.values) tool.key: 0, 'as': 0, 'ld': 0},
    assets: {
      for (final name in [
        fakeRuntime.platform,
        for (final source in ['runtime', 'io', 'launcher', 'check', 'math'])
          'native-src/$source.cc',
        'notices/LICENSE.txt',
      ])
        name: name,
      fakeRuntime.compilePlan: jsonEncode({
        'schema': 1,
        'cflags': ['-marm', '-march=armv6k', '-mfloat-abi=hard'],
        'soft_math_source': 'math.cc',
        'modes': {'aot': units, 'jit': units},
      }),
    },
  );
  final root = sdk.environment['DEVKITPRO']!;
  for (final relative in [
    for (final tool in [
      'gcc',
      'g++',
      'as',
      'ld',
      'ar',
      'nm',
      'objdump',
      'readelf',
      'objcopy',
    ])
      'devkitARM/bin/arm-none-eabi-$tool${Platform.isWindows ? '.exe' : ''}',
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
    ])
      'devkitARM/lib/$name',
    'libctru/lib/libctru.a',
  ]) {
    File(p.join(root, relative)).createSync(recursive: true);
  }
  return sdk;
}

class _QueryResult implements Process {
  final String result;
  _QueryResult(this.result);
  @override
  int get pid => throw UnsupportedError('No operating system process');
  @override
  IOSink get stdin => throw UnsupportedError('No input');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(result));
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode async => 0;
}
