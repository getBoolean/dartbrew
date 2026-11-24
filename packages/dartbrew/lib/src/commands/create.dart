import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../process.dart';
import '../sdk.dart';
import '../targets/ctr/templates.dart';
import 'target_option.dart';

/// Dart reserved words, which a package name cannot be.
const _reservedWords = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

final _packageName = RegExp(r'^[a-z_][a-z0-9_]*$');

/// Whether [name] is a valid Dart package name.
bool isValidPackageName(String name) =>
    _packageName.hasMatch(name) && !_reservedWords.contains(name);

/// The `create` command, for registration in the runner.
///
/// [sdkDir] chooses the SDK directory and defaults to the directory
/// containing dartbrew.
Command<int> createCommand({
  ProcessStarter start = startProcess,
  String Function()? sdkDir,
}) => CreateCommand(start: start, sdkDir: sdkDir);

/// Creates a new console-app project.
class CreateCommand extends Command<int> {
  @override
  String get name => 'create';

  @override
  String get description => 'Create a new console-app project.';

  @override
  String get invocation => 'dartbrew create [arguments] <directory>';

  final ProcessStarter _start;
  final String Function()? _sdkDir;

  CreateCommand({
    ProcessStarter start = startProcess,
    String Function()? sdkDir,
  }) : _start = start,
       _sdkDir = sdkDir {
    addTargetOption(argParser);
    argParser
      ..addFlag(
        'pub',
        defaultsTo: true,
        help: 'Run "pub get" after creating the project.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Write into a directory that is not empty.',
      );
    addSdkOption(argParser);
  }

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      throw UsageException('create requires one directory.', usage);
    }
    final directory = Directory(p.normalize(p.absolute(args.rest.single)));
    final name = p.basename(directory.path);
    if (!isValidPackageName(name)) {
      throw UsageException(
        '"$name" is not a valid package name. Use lowercase letters, digits '
        'and underscores, not starting with a digit or a reserved word.',
        usage,
      );
    }
    if (directory.existsSync() &&
        directory.listSync().isNotEmpty &&
        !args.flag('force')) {
      throw FileSystemException(
        'Directory is not empty; use --force to write into it',
        directory.path,
      );
    }
    for (final MapEntry(key: path, value: contents) in ctrTemplate(
      name,
    ).entries) {
      final file = File(p.joinAll([directory.path, ...path.split('/')]));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(contents);
    }
    stdout.writeln('Created $name in ${directory.path}');
    if (!args.flag('pub')) return 0;
    final sdk = await NativeSdk.load(
      _sdkDir?.call() ?? sdkDirectory(args),
      quick: true,
    );
    final process = await _start(
      sdk.tool('dart'),
      ['pub', 'get'],
      workingDirectory: directory.path,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}
