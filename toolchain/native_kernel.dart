// Producer compiles this driver into the SDK's native ctr-kernel executable.
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:vm/kernel_front_end.dart'
    show createCompilerArgParser, runCompiler;

Future<void> main(List<String> arguments) async {
  final parser = createCompilerArgParser();
  final options = parser.parse(arguments);
  exitCode = await runCompiler(
    options,
    'ctr-kernel --platform <SDK platform> --output <kernel> <entrypoint>',
  );
  if (exitCode != 0) return;
  verifyRetainedHooks(File(options.option('output')!));
}

/// Verifies the private SDK entry points called from the CTR embedder.
void verifyRetainedHooks(File kernel) {
  final component = Component();
  BinaryBuilder(kernel.readAsBytesSync()).readComponent(component);
  Library library(String uri) => component.libraries.singleWhere(
    (library) => library.importUri.toString() == uri,
  );
  final hooks = library('dart:_ctr');
  final names = hooks.procedures
      .map((procedure) => procedure.name.text)
      .toSet();
  for (final name in ['_getPrintClosure', '_print']) {
    if (!names.contains(name)) throw StateError('Missing retained hook $name');
  }
  // dart:io members the launcher reaches through the SDK's SetupDartIoLibrary.
  final io = library('dart:io');
  if (!io.procedures.any((procedure) => procedure.name.text == '_setupHooks')) {
    throw StateError('Missing retained dart:io hook _setupHooks');
  }
  // Uri.base comes from dart:io's own closure (launcher embedder.cc).
  if (!io.procedures.any(
    (procedure) => procedure.name.text == '_getUriBaseClosure',
  )) {
    throw StateError('Missing retained dart:io hook _getUriBaseClosure');
  }
  // Platform.script (DartIoSettings.script_uri).
  final platform = io.classes.singleWhere((c) => c.name == '_Platform');
  if (!platform.procedures.any(
    (procedure) => procedure.name.text == '_nativeScript' && procedure.isSetter,
  )) {
    throw StateError('Missing retained dart:io setter _Platform._nativeScript');
  }
}
