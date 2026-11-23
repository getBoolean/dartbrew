import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../device/device.dart';
import '../device/transport.dart';
import '../errors.dart';
import '../paths.dart';
import '../process.dart';
import '../stage_runner.dart';
import '../targets/ctr/azahar.dart';
import '../targets/ctr/netloader.dart';
import '../targets/ctr/pipeline.dart';
import '../targets/ctr/test_entrypoint.dart';
import '../test_runner/reporter.dart';
import 'run.dart';

/// The exit code of a `test --reporter json` run the user interrupted:
/// 128 + SIGINT, as shells report a process stopped with Ctrl-C.
const interruptedExitCode = 130;

/// The `test` command, ready for `CommandRunner.addCommand`.
///
/// See [DeviceRunner] for [start], [transport], [listenAddress],
/// [deadlines], [settle], [azaharHost] and [input]. The report goes to
/// [out]; build progress, prompts and warnings go to [err].
///
/// With `--reporter json`, each event of [interrupts] (such as Ctrl-C)
/// ends the report with its `done` event and then calls [exitProcess] with
/// [interruptedExitCode]; null [interrupts] watches nothing. [exitProcess]
/// defaults to flushing standard output and exiting.
Command<int> testCommand({
  Map<String, String>? environment,
  ProcessStarter start = startProcess,
  DeviceTransport Function() transport = NetloaderClient.new,
  InternetAddress? listenAddress,
  RunDeadlines deadlines = const RunDeadlines(),
  Duration settle = const Duration(seconds: 1),
  AzaharHost? azaharHost,
  Stream<List<int>> Function()? input,
  Stream<Object?> Function()? interrupts,
  Future<void> Function(int exitCode) exitProcess = _exitProcess,
  StringSink? out,
  StringSink? err,
}) => _TestCommand(
  DeviceRunner(
    start: start,
    environment: environment,
    transport: transport,
    listenAddress: listenAddress,
    deadlines: deadlines,
    settle: settle,
    azaharHost: azaharHost,
    input: input,
  ),
  start,
  interrupts,
  exitProcess,
  out ?? stdout,
  err ?? stderr,
);

Future<void> _exitProcess(int exitCode) async {
  await stdout.flush();
  exit(exitCode);
}

class _TestCommand extends Command<int> {
  final DeviceRunner _runner;
  final ProcessStarter _start;
  final Stream<Object?> Function()? _interrupts;
  final Future<void> Function(int exitCode) _exitProcess;
  final StringSink _out;
  final StringSink _err;

  _TestCommand(
    this._runner,
    this._start,
    this._interrupts,
    this._exitProcess,
    this._out,
    this._err,
  ) {
    addDeviceRunOptions(argParser);
    argParser
      ..addMultiOption(
        'name',
        abbr: 'n',
        help:
            'Run only tests whose name matches this regular expression. '
            'If given more than once, a test must match all of them.',
        splitCommas: false,
      )
      ..addMultiOption(
        'plain-name',
        abbr: 'N',
        help:
            'Run only tests whose name contains this text. If given more '
            'than once, a test must contain all of them.',
        splitCommas: false,
      )
      ..addOption(
        'reporter',
        abbr: 'r',
        help: 'How results are shown.',
        allowed: ['compact', 'json'],
        allowedHelp: {
          'compact': 'A single line per test, with a summary.',
          'json': 'The machine-readable JSON reporter protocol of dart test.',
        },
        defaultsTo: 'compact',
      );
  }

  @override
  String get name => 'test';

  @override
  String get description => 'Run package:test tests on a device.';

  @override
  String get invocation => 'dartbrew test [arguments] [<paths>...]';

  @override
  Future<int> run() async {
    final args = argResults!;
    final settings = DeviceRunSettings.parse(args, usage);
    final names = args.multiOption('name');
    for (final name in names) {
      try {
        RegExp(name);
      } on FormatException catch (error) {
        throw UsageException(
          'Invalid --name pattern "$name": ${error.message}',
          usage,
        );
      }
    }
    final project = settings.project;
    final files = _selectTests(project, args.rest);
    if (files.isEmpty) {
      _err.writeln(
        args.rest.isEmpty
            ? 'No test files were found in ${p.join(project, 'test')}.'
            : 'No test files were found at the given paths.',
      );
      return noTestsRanExitCode;
    }

    if (_testEntrypointWarning(project) case final warning?) {
      _err.writeln(warning);
    }

    final json = args.option('reporter') == 'json';
    final session = TestSession(
      json ? JsonRenderer(_out, _err, pid: pid) : CompactRenderer(_out),
    )..begin(files.length);
    final interrupted = json
        ? _interrupts?.call().listen((_) async {
            session.stop();
            await _runner.interruptBuild();
            await _exitProcess(interruptedExitCode);
          })
        : null;
    try {
      return await _runTests(
        settings,
        session,
        files,
        names: names,
        plainNames: args.multiOption('plain-name'),
        reporterHandlesInterrupts: interrupted != null,
      );
    } finally {
      session.stop();
      await interrupted?.cancel();
    }
  }

  /// Builds and runs [files] on the device, reporting to [session], and
  /// returns the exit code. A file that fails to compile on its own is
  /// reported as a load error and the rest run without it.
  Future<int> _runTests(
    DeviceRunSettings settings,
    TestSession session,
    List<String> selected, {
    required List<String> names,
    required List<String> plainNames,
    required bool reporterHandlesInterrupts,
  }) async {
    final project = settings.project;
    var files = selected;
    DeviceRun run;
    var checked = false;
    while (true) {
      final entry = writeTestEntrypoint(
        project: project,
        testFiles: files,
        names: names,
        plainNames: plainNames,
        firstId: session.nextId,
      );
      try {
        run = await _runner(
          settings,
          entry: entry.path,
          fixture: _fixture(project, entry.path),
          onOutput: session.addOutput,
          err: _err,
          buildDirectory: 'test',
          reporterHandlesInterrupts: reporterHandlesInterrupts,
        );
        break;
      } on DartbrewException catch (error) {
        _err.writeln(error.message);
        return error.exitCode;
      } on StageFailure catch (error) {
        if (checked || error.stage != 'kernel') rethrow;
        checked = true;
        final failures = await _findLoadErrors(settings, files);
        if (failures.isEmpty) rethrow;
        failures.forEach(
          (file, message) =>
              session.loadError(_suitePath(project, file), message),
        );
        files = [
          for (final file in files)
            if (!failures.containsKey(file)) file,
        ];
        if (files.isEmpty) return session.finish();
      }
    }
    final result = run.result;
    final exited = result.verdict.exitCode;
    final code = session.finish(
      runExitCode: result.exit.code,
      runMessage:
          result.exit.message ??
          result.verdict.reason ??
          (exited == null ? null : 'exit code $exited'),
    );
    // A program that ended with exit(n), n != 0, makes the command exit n.
    return code != 0 && exited != null && exited != 0 ? result.exit.code : code;
  }

  /// The test files to run: `*_test.dart` under `test/` or under each
  /// directory in [paths], and each file in [paths] as given. Relative
  /// paths are resolved against [project]; every file must be inside it.
  List<String> _selectTests(String project, List<String> paths) {
    final selected = <String>{};
    void addDirectory(Directory directory) {
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('_test.dart')) {
          selected.add(p.normalize(entity.absolute.path));
        }
      }
    }

    if (paths.isEmpty) {
      final directory = Directory(p.join(project, 'test'));
      if (directory.existsSync()) addDirectory(directory);
    }
    for (final path in paths) {
      final full = p.normalize(p.absolute(project, path));
      if (!p.isWithin(project, full) && full != project) {
        throw UsageException(
          'Test paths must be inside the project directory: $path',
          usage,
        );
      }
      if (FileSystemEntity.isDirectorySync(full)) {
        addDirectory(Directory(full));
      } else if (FileSystemEntity.isFileSync(full)) {
        selected.add(full);
      } else {
        throw UsageException('No file or directory at $path.', usage);
      }
    }
    return selected.toList()..sort();
  }

  /// Compiles each of [files] to kernel on its own with the target's kernel
  /// tool, and returns the compiler output of each file that fails.
  ///
  /// This is the tool and platform the combined build used, so a file fails
  /// here exactly when it would fail there; host `dart compile kernel`
  /// would check against host libraries, and `dart analyze` reports a
  /// different set of errors.
  Future<Map<String, String>> _findLoadErrors(
    DeviceRunSettings settings,
    List<String> files,
  ) async {
    final sdk = _runner.sdk!;
    final work = Directory(
      p.join(settings.project, '.dart_tool', 'dartbrew', 'test', 'check'),
    );
    if (work.existsSync()) work.deleteSync(recursive: true);
    work.createSync(recursive: true);
    final packages = File(
      p.join(settings.project, '.dart_tool', 'package_config.json'),
    );
    final runner = StageRunner(sdk, work, start: _start);
    final failures = <String, String>{};
    for (var i = 0; i < files.length; i++) {
      final stage = 'check-$i';
      try {
        await runner(
          'kernel',
          kernelArguments(
            sdk,
            mode: settings.mode,
            packageConfig: packages,
            output: p.join(work.path, '$stage.dill'),
            entry: files[i],
          ),
          stage,
        );
      } on ProcessException {
        final log = File(p.join(work.path, '$stage.log'));
        failures[files[i]] = log.existsSync()
            ? log.readAsStringSync().trimRight()
            : 'The kernel compiler failed.';
      }
    }
    return failures;
  }

  /// A warning that [project]'s resolved `test_api` may not work with the
  /// test entrypoint, or null when it should.
  static String? _testEntrypointWarning(String project) {
    final testApi = resolvedTestApiVersion(project);
    if (testApi == null || isTestedTestApi(testApi)) return null;
    return 'Warning: this project resolves test_api $testApi, but dartbrew '
        'test is tested with test_api $testedTestApi. If the test build '
        'fails or results look wrong, use a test package version that '
        'resolves test_api $testedTestApi.';
  }

  static String _suitePath(String project, String file) =>
      posixRelative(file, from: project);

  /// The application identity token: the project's, marked as a test build
  /// so it does not overwrite the `run` application on the SD card.
  static String _fixture(String project, String entry) {
    const suffix = '-test';
    const maxBase = fixtureMaxLength - suffix.length;
    final base = fixtureFor(project, entry);
    return '${base.length > maxBase ? base.substring(0, maxBase) : base}'
        '$suffix';
  }
}
