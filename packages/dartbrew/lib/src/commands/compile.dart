import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../native_directory.dart';
import '../process.dart';
import '../sdk.dart';
import '../targets/ctr/package.dart';
import '../targets/ctr/pipeline.dart';
import 'target_option.dart';

/// The `compile` command, for registration in the runner.
Command<int> compileCommand({ProcessStarter start = startProcess}) =>
    CompileCommand(start: start);

/// Compiles a Dart program for a build target and stages it for a manual
/// SD-card run.
class CompileCommand extends Command<int> {
  @override
  String get name => 'compile';

  @override
  String get description => 'Compile a Dart program for a build target.';

  @override
  String get invocation => 'dartbrew compile [arguments] <entry.dart>';

  final ProcessStarter _start;
  final Map<String, String>? environment;
  final IOSink? _out;

  /// [out] receives the success message; it defaults to standard output.
  CompileCommand({
    ProcessStarter start = startProcess,
    IOSink? out,
    this.environment,
  }) : _start = start,
       _out = out {
    addTargetOption(argParser);
    argParser
      ..addOption(
        'mode',
        help: 'How the program is compiled.',
        allowed: [for (final mode in BuildMode.values) mode.name],
        allowedHelp: {
          'aot': 'Ahead-of-time snapshot linked into the application.',
          'jit': 'Kernel file run by the JIT VM; skips the snapshot stage.',
        },
        defaultsTo: BuildMode.aot.name,
      )
      ..addOption(
        'output',
        abbr: 'o',
        help: 'New directory to write the application into.',
        valueHelp: 'dir',
      )
      ..addOption(
        'project-directory',
        help: "The project's root; defaults to the entrypoint's directory.",
        valueHelp: 'dir',
      )
      ..addFlag(
        'offline',
        negatable: false,
        help: 'Resolve packages using only the local pub cache.',
      )
      ..addOption('fixture', hide: true);
    addSdkOption(argParser);
  }

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1 || args.option('output') == null) {
      throw UsageException(
        'compile requires one entrypoint and --output.',
        usage,
      );
    }
    final sdk = await NativeSdk.load(sdkDirectory(args));
    final entry = File(args.rest.single).resolveSymbolicLinksSync();
    final project = Directory(
      args.option('project-directory') ?? _owningProject(entry),
    ).resolveSymbolicLinksSync();
    if (!p.isWithin(project, entry)) {
      throw UsageException(
        'The entrypoint must be inside the project directory.',
        usage,
      );
    }
    final output = Directory(p.normalize(p.absolute(args.option('output')!)));
    if (FileSystemEntity.typeSync(output.path) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Output already exists; choose a new directory',
        output.path,
      );
    }
    if (p.equals(sdk.root, output.path) || p.isWithin(sdk.root, output.path)) {
      throw const FormatException('Compile output must be outside the SDK.');
    }
    final fixture = args.option('fixture') ?? fixtureFor(project, entry);
    if (!fixturePattern.hasMatch(fixture)) {
      throw const FormatException(
        'Fixture must contain 1-64 letters, digits, underscores or hyphens.',
      );
    }
    output.parent.createSync(recursive: true);
    createDirectoryExclusively(output.path);
    final work = Directory(p.join(output.path, 'work'))..createSync();
    final build = await buildCtrApplication(
      sdk: sdk,
      project: project,
      entry: entry,
      mode: BuildMode.values.byName(args.option('mode')!),
      fixture: fixture,
      work: work,
      application: File(p.join(output.path, 'application.3dsx')),
      offline: args.flag('offline'),
      start: _start,
      environment: environment,
    );
    packageCtrApplication(sdk, build, output);
    final out = _out ?? stdout;
    out.writeln('Built ${build.application.path}');
    out.writeln(
      'Copy the contents of ${p.join(output.path, 'SDROOT')} to the root of '
      'the SD card, then launch the app from Homebrew Launcher.',
    );
    return 0;
  }
}

/// The nearest directory at or above [entry]'s directory that holds a
/// `pubspec.yaml`, as `dart compile` resolves packages; the entry's own
/// directory when none does.
String _owningProject(String entry) {
  var directory = p.dirname(entry);
  while (true) {
    if (File(p.join(directory, 'pubspec.yaml')).existsSync()) return directory;
    final parent = p.dirname(directory);
    if (parent == directory) return p.dirname(entry);
    directory = parent;
  }
}
