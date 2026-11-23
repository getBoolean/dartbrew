import 'dart:convert';
import 'dart:io';

import 'package:dartbrew/src/sdk.dart' show fileDigest;
import 'package:path/path.dart' as p;

const _exports = {
  'CtrLibmPow',
  'CtrLibmAtan2',
  'CtrLibmSin',
  'CtrLibmCos',
  'CtrLibmTan',
  'CtrLibmAsin',
  'CtrLibmAcos',
  'CtrLibmAtan',
  'CtrLibmExp',
  'CtrLibmLog',
  'CtrLibmFloor',
  'CtrLibmCeil',
  'CtrLibmTrunc',
  'CtrLibmRound',
};

const _imports = {
  '__errno',
  '__getreent',
  '__muldc3',
  '__mulsc3',
  '__aeabi_d2f',
  '__aeabi_d2iz',
  '__aeabi_d2lz',
  '__aeabi_dadd',
  '__aeabi_dcmpeq',
  '__aeabi_dcmpge',
  '__aeabi_dcmpgt',
  '__aeabi_dcmple',
  '__aeabi_dcmplt',
  '__aeabi_dcmpun',
  '__aeabi_ddiv',
  '__aeabi_dmul',
  '__aeabi_dsub',
  '__aeabi_f2d',
  '__aeabi_f2iz',
  '__aeabi_f2lz',
  '__aeabi_fadd',
  '__aeabi_fcmpeq',
  '__aeabi_fcmpge',
  '__aeabi_fcmpgt',
  '__aeabi_fcmple',
  '__aeabi_fcmplt',
  '__aeabi_fcmpun',
  '__aeabi_fdiv',
  '__aeabi_fmul',
  '__aeabi_fsub',
  '__aeabi_i2d',
  '__aeabi_i2f',
  '__aeabi_l2d',
  '__aeabi_ui2d',
  '__aeabi_ui2f',
};

/// Builds the hard-float math bridge against the local base-PCS libm.
///
/// [output] is an existing private native-build staging directory. [run]
/// returns stdout after a successful exit and propagates failure/cancellation.
/// Only the audited object is published into [output].
Future<File> buildSoftMath({
  required String Function(String) tool,
  required List<String> cflags,
  required File source,
  required Directory output,
  required Future<String> Function(String executable, List<String> arguments)
  run,
}) async {
  if (!cflags.toSet().containsAll({
    '-marm',
    '-march=armv6k',
    '-mfloat-abi=hard',
  })) {
    throw const FormatException(
      'Software math requires the CTR hard-float profile.',
    );
  }
  final provider = File(
    (await run(tool('g++'), [
      '-marm',
      '-march=armv6k',
      '-mfloat-abi=soft',
      '-print-file-name=libm.a',
    ])).trim(),
  );
  if (!p.isAbsolute(provider.path) || !await provider.exists()) {
    throw FormatException(
      'Cannot locate the soft-float libm.a: ${provider.path}',
    );
  }
  final providerHash = await fileDigest(provider);
  final sourceHash = await fileDigest(source);
  final work = await output.absolute.createTemp('math-');
  File file(String name) => File(p.join(work.path, name));
  try {
    final symbols = _definedSymbols(
      await run(tool('nm'), [
        '-g',
        '--defined-only',
        '--format=posix',
        provider.path,
      ]),
    );
    if (!symbols.containsAll({'__ieee754_pow', 'sin', '__ieee754_log'})) {
      throw const FormatException(
        'Missing math symbols in the local soft-float libm.a',
      );
    }
    final names = symbols.toList()..sort();
    final mapping = file('rename.txt');
    final local = file('localize.txt');
    await mapping.writeAsString(names.map((n) => '$n ctr_soft_$n\n').join());
    await local.writeAsString(names.map((n) => 'ctr_soft_$n\n').join());
    final archive = file('private.a').path;
    final bridge = file('bridge.o').path;
    final combined = file('combined.o').path;
    final component = file('component.o');
    await run(tool('objcopy'), [
      '-D',
      '--redefine-syms=${mapping.path}',
      provider.path,
      archive,
    ]);
    await run(tool('g++'), [
      '-std=c++20',
      '-O2',
      '-fno-builtin',
      '-fno-exceptions',
      '-fno-rtti',
      '-ffunction-sections',
      '-fdata-sections',
      ...cflags,
      '-c',
      source.absolute.path,
      '-o',
      bridge,
    ]);
    // Only this relocatable link mixes base PCS and hard-float PCS. Every
    // base-PCS definition is made private before the final executable link.
    await run(tool('ld'), [
      '-r',
      '--no-warn-mismatch',
      '-o',
      combined,
      bridge,
      '--whole-archive',
      archive,
      '--no-whole-archive',
    ]);
    await run(tool('objcopy'), [
      '--localize-symbols=${local.path}',
      combined,
      component.path,
    ]);
    await _audit(component.path, (name, args) => run(tool(name), args));
    if (await fileDigest(provider) != providerHash ||
        await fileDigest(source) != sourceHash) {
      throw const FormatException(
        'Software math input changed during the native build.',
      );
    }
    return await component.rename(p.join(output.absolute.path, 'soft-math.o'));
  } finally {
    await work.delete(recursive: true);
  }
}

Future<void> _audit(
  String component,
  Future<String> Function(String name, List<String> arguments) run,
) async {
  final exports = _definedSymbols(
    await run('nm', ['-g', '--defined-only', '--format=posix', component]),
  );
  final missing = _exports.difference(exports);
  final extra = exports.difference(_exports);
  if (missing.isNotEmpty || extra.isNotEmpty) {
    throw FormatException(
      'Software math exports differ: missing $missing, unexpected $extra',
    );
  }
  final unresolved = await run('nm', ['-u', component]);
  final imports = {
    for (final line in const LineSplitter().convert(unresolved))
      if (line.trim().isNotEmpty) line.trim().split(RegExp(r'\s+')).last,
  };
  final unexpected = imports.difference(_imports);
  if (unexpected.isNotEmpty) {
    throw FormatException('Unexpected software math imports: $unexpected');
  }
  final header = await run('readelf', ['-h', component]);
  final attributes = await run('readelf', ['-A', component]);
  if (!header.contains('ELF32') ||
      !header.contains('little endian') ||
      !RegExp(r'Machine:\s+ARM\s*$', multiLine: true).hasMatch(header) ||
      !attributes.contains('Tag_ABI_VFP_args: VFP registers')) {
    throw const FormatException(
      'Software math object lacks the CTR hard-float ELF interface.',
    );
  }
  _checkInstructions(await run('objdump', ['-d', component]));
}

Set<String> _definedSymbols(String listing) => {
  for (final match in RegExp(
    r'^(\S+)[ \t]+\S[ \t]+[0-9a-fA-F]+\b',
    multiLine: true,
  ).allMatches(listing))
    match[1]!,
};

void _checkInstructions(String disassembly) {
  final instructions = RegExp(
    r'^[ \t]*[0-9a-f]+:[ \t]+(?:[0-9a-f]{8}|[0-9a-f]{4}(?: [0-9a-f]{4})?)[ \t]+(\S+)([^\r\n]*)',
    multiLine: true,
  ).allMatches(disassembly);
  if (instructions.isEmpty) {
    throw const FormatException(
      'No instructions in software math disassembly.',
    );
  }
  final highRegister = RegExp(r'\b(?:d(?:1[6-9]|2[0-9]|3[01])|q\d+)\b');
  const allowedVfp = ['vmov', 'vldr', 'vstr', 'vpush', 'vpop'];
  const unavailable = [
    'sdiv',
    'udiv',
    'movw',
    'movt',
    'dmb',
    'dsb',
    'isb',
    'ubfx',
    'sbfx',
    'bfi',
    'bfc',
    'rbit',
  ];
  for (final instruction in instructions) {
    final op = instruction[1]!;
    final operands = instruction[2]!;
    if (unavailable.any(op.startsWith) ||
        op.startsWith('v') &&
            (!allowedVfp.any(op.startsWith) ||
                highRegister.hasMatch(operands))) {
      throw FormatException(
        'Unsupported software math instruction: $op$operands',
      );
    }
  }
}
