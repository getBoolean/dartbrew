import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/host.dart';
import 'package:release_tools/src/precompiler.dart';
import 'package:release_tools/src/release_check.dart';
import 'package:release_tools/src/stage_runner.dart';

const _usage =
    'Builds gen_snapshot, ctr-kernel and the host Dart for this host from a '
    'checkout prepared by toolchain/bootstrap.py --sync-deps --fetch-gn.\n\n'
    'Usage: build_precompiler --work-dir <dir> --output-dir <absent dir>';

Future<void> main(List<String> arguments) async {
  final repository = await repositoryRoot();
  final parser = ArgParser()
    ..addOption('work-dir', help: 'Holds stage logs and the GN output.')
    ..addOption('output-dir', help: 'Receives the precompiler; must not exist.')
    ..addOption(
      'source',
      help: 'The patched Dart SDK checkout.',
      defaultsTo: p.join(repository, 'third_party', 'dart-sdk'),
    )
    ..addOption(
      'manifest',
      help: 'The pin table.',
      defaultsTo: p.join(repository, 'toolchain', 'versions.json'),
    )
    ..addOption(
      'depot-tools',
      defaultsTo: p.join(repository, 'third_party', 'depot_tools'),
    )
    ..addOption(
      'python',
      help: 'The Python that runs bootstrap.py.',
      defaultsTo: 'python3',
    )
    ..addOption(
      'jobs',
      help: 'Ninja jobs (1-$maxPrecompilerJobs).',
      defaultsTo: '2',
    );
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on ArgParserException catch (error) {
    _usageError(error.message, parser);
    return;
  }
  final work = options.option('work-dir');
  final output = options.option('output-dir');
  final jobs = int.tryParse(options.option('jobs')!);
  if (work == null || output == null || jobs == null) {
    _usageError(
      '--work-dir, --output-dir and a numeric --jobs are required.',
      parser,
    );
    return;
  }
  final host = _currentHost();
  if (host == null) {
    stderr.writeln('unsupported host: ${Abi.current()}');
    exitCode = 1;
    return;
  }
  final workDirectory = Directory(p.absolute(work))
    ..createSync(recursive: true);
  try {
    final receipt = await buildPrecompiler(
      PrecompilerRequest(
        host: host,
        repository: Directory(repository),
        source: Directory(p.absolute(options.option('source')!)),
        depotTools: Directory(p.absolute(options.option('depot-tools')!)),
        work: workDirectory,
        output: Directory(p.absolute(output)),
        manifest: File(p.absolute(options.option('manifest')!)),
        python: options.option('python')!,
        jobs: jobs,
      ),
      run: StageRunner(workDirectory).call,
    );
    stdout.writeln(jsonEncode(receipt['generated']));
  } on PrecompilerFailure catch (failure) {
    stderr.writeln(failure);
    exitCode = 1;
  } on ProcessException catch (failure) {
    stderr.writeln(failure.message);
    exitCode = 1;
  } on FileSystemException catch (failure) {
    stderr.writeln(failure);
    exitCode = 1;
  }
}

/// The release host this process runs on, or null when dartbrew is not
/// released for it.
Host? _currentHost() => switch (Abi.current()) {
  Abi.windowsX64 => Host.windowsX64,
  Abi.linuxX64 => Host.linuxX64,
  Abi.macosArm64 => Host.macosArm64,
  _ => null,
};

void _usageError(String message, ArgParser parser) {
  stderr.writeln('$message\n\n$_usage\n${parser.usage}');
  exitCode = 64;
}
