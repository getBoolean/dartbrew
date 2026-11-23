import 'dart:io';

import 'package:args/args.dart';
import 'package:release_tools/src/release_check.dart';
import 'package:release_tools/src/runtime_build.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'jobs',
      defaultsTo: '3',
      help: 'Maximum parallel compiles for the source-bundle proof.',
    )
    ..addOption(
      'source',
      mandatory: true,
      help: 'Verified patched SDK checkout.',
    )
    ..addOption(
      'build-root',
      mandatory: true,
      help: 'Parent of the built AOT and JIT target graphs.',
    )
    ..addOption(
      'gen-snapshot',
      mandatory: true,
      help: 'Linux CTR snapshot generator used to qualify the probe.',
    )
    ..addOption(
      'output',
      mandatory: true,
      help: 'New runtime component directory.',
    );
  try {
    final args = parser.parse(arguments);
    if (args.rest.isNotEmpty) {
      throw ArgParserException('Unexpected arguments: ${args.rest}');
    }
    final output = Directory(args.option('output')!).absolute;
    final jobs = int.tryParse(args.option('jobs')!);
    if (jobs == null || jobs < 1) {
      throw ArgParserException('--jobs must be positive');
    }
    await buildRuntime(
      repository: Directory(await repositoryRoot()),
      source: Directory(args.option('source')!).absolute,
      buildRoot: Directory(args.option('build-root')!).absolute,
      output: output,
      jobs: jobs,
      genSnapshot: File(args.option('gen-snapshot')!).absolute,
    );
    stdout.writeln('Built and verified runtime component at ${output.path}');
  } on ArgParserException catch (error) {
    stderr.writeln('${error.message}\n${parser.usage}');
    exitCode = 64;
  } on Exception catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
