import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:release_tools/src/host.dart';
import 'package:release_tools/src/release_check.dart';
import 'package:release_tools/src/sdk_assembly.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'precompiler',
      mandatory: true,
      help: 'Directory containing native-precompiler.json.',
    )
    ..addOption(
      'runtime',
      mandatory: true,
      help: 'Directory containing runtime.json and the reference probe.',
    )
    ..addOption(
      'output-dir',
      mandatory: true,
      help: 'A fresh directory for the SDK, archive and verification logs.',
    );
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(parser.usage);
    return;
  }
  try {
    final options = parser.parse(args);
    if (options.rest.isNotEmpty) {
      throw ArgParserException(
        'Unexpected arguments: ${options.rest.join(' ')}',
      );
    }
    final host = switch (Abi.current()) {
      Abi.windowsX64 => Host.windowsX64,
      Abi.linuxX64 => Host.linuxX64,
      Abi.macosArm64 => Host.macosArm64,
      final abi => throw UnsupportedError('Unsupported release host $abi'),
    };
    final receipt = await assembleSdk(
      host: host,
      version: await previewVersion(),
      repository: Directory(await repositoryRoot()),
      precompiler: Directory(options.option('precompiler')!).absolute,
      runtime: Directory(options.option('runtime')!).absolute,
      output: Directory(options.option('output-dir')!).absolute,
    );
    stdout.writeln(jsonEncode(receipt));
  } on ArgParserException catch (error) {
    stderr.writeln('${error.message}\n${parser.usage}');
    exitCode = 64;
  } on Exception catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
