/// The ordered linker arguments written by the runtime producer. Tokens in
/// braces expand to files from the local toolchain, native build or app.
const ctrLinkTemplate = <String>[
  '--defsym=__sync_synchronize=__sync_synchronize_cp15dmb',
  '-X',
  '-T',
  '{3dsx.ld}',
  '-d',
  '--emit-relocs',
  '--use-blx',
  '--gc-sections',
  '-u',
  '__sync_synchronize_cp15dmb',
  '-Map={map}',
  '-o',
  '{elf}',
  '{3dsx_crt0.o}',
  '{crti.o}',
  '{crtbegin.o}',
  '{launcher}',
  '{program}',
  '{payload}',
  '{soft_math}',
  '{io}',
  '{runtime}',
  '{libctru.a}',
  '{libstdc++.a}',
  '{libm.a}',
  '--start-group',
  '{libgcc.a}',
  '{libc.a}',
  '{libsysbase.a}',
  '--end-group',
  '{crtend.o}',
  '{crtn.o}',
];

/// Expands a manifest template in order. Local toolchain files are queried
/// only when a role requires them. Each expanded path is one process argument.
Future<List<String>> ctrLinkArguments(
  List<String> template, {
  required Map<String, String> outputs,
  required List<String> launcher,
  required Future<String> Function(String) targetFile,
}) async {
  final arguments = <String>[];
  for (final token in template) {
    if (!ctrLinkTemplate.contains(token)) {
      throw FormatException('Unknown CTR linker argument: $token');
    }
    if (token == '{launcher}') {
      arguments.addAll(launcher);
    } else if (token == '-Map={map}') {
      arguments.add('-Map=${outputs['map']!}');
    } else if (token.startsWith('{')) {
      final role = token.substring(1, token.length - 1);
      arguments.add(outputs[role] ?? await targetFile(role));
    } else {
      arguments.add(token);
    }
  }
  return arguments;
}
