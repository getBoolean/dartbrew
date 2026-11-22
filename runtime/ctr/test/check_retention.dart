// Inspect generated AOT kernel; this does not execute or qualify an AOT image.
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

void main(List<String> args) {
  final component = Component();
  BinaryBuilder(File(args.single).readAsBytesSync()).readComponent(component);
  Library library(String uri) => component.libraries.singleWhere(
    (library) => library.importUri.toString() == uri,
  );
  final hooks = library('dart:_ctr');
  final names = hooks.procedures
      .map((procedure) => procedure.name.text)
      .toSet();
  for (final name in [
    '_installHooks',
    '_getPrintClosure',
    '_getUriBaseClosure',
    '_schedule',
    '_clock',
    '_print',
  ]) {
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
  print('Private hooks and native references retained in AOT kernel');
}
