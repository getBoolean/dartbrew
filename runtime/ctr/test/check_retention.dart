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
  final config = io.classes.singleWhere((c) => c.name == '_EmbedderConfig');
  if (!config.fields.any((field) => field.name.text == '_mayExit')) {
    throw StateError('Missing retained dart:io field _EmbedderConfig._mayExit');
  }
  print('Private hooks and native references retained in AOT kernel');
}
