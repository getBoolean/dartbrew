import 'dart:io';

import 'package:args/args.dart';
import 'package:release_tools/src/release_check.dart';

const _usage =
    'Refuses to publish SDK archives that were not qualified for this '
    'version.\n\n'
    'Usage: check_release --results <results.json> <archive.zip>...';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'results',
      help: 'The qualification results.json for the release version.',
    );
  final String? results;
  final List<String> archives;
  try {
    final options = parser.parse(arguments);
    results = options.option('results');
    archives = options.rest;
  } on ArgParserException catch (error) {
    stderr.writeln('${error.message}\n\n$_usage\n${parser.usage}');
    exitCode = 64;
    return;
  }
  if (results == null) {
    stderr.writeln('Missing --results.\n\n$_usage\n${parser.usage}');
    exitCode = 64;
    return;
  }
  try {
    final names = await checkRelease(
      results: File(results),
      archives: [for (final path in archives) File(path)],
    );
    stdout.writeln('qualified: ${names.join(', ')}');
  } on ReleaseRefused catch (refusal) {
    stderr.writeln(refusal);
    exitCode = 1;
  }
}
