import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../device/console_device.dart';
import '../device/device.dart';
import '../process.dart';
import '../sdk.dart';
import '../targets/ctr/azahar.dart';
import '../targets/ctr/netloader.dart';
import '../targets/ctr/package.dart';
import '../targets/ctr/pipeline.dart' show BuildMode, CtrBuild, fixtureFor;
import '../targets/target.dart';
import 'devices.dart';

/// The default TCP port the host listens on for the app's connection; the
/// port `3dslink -s` uses, so one firewall rule covers both.
const defaultHostPort = 17491;

/// The `run` command, ready for `CommandRunner.addCommand`.
///
/// See [DeviceRunner] for [start], [transportFor], [listenAddress],
/// [deadlines], [settle], [azaharHost] and [input]. Program output and the `--verdict` JSON go to
/// [out]; prompts and messages go to [err].
Command<int> runCommand({
  ProcessStarter start = startProcess,
  TransportForTarget transportFor = defaultTransportFor,
  InternetAddress? listenAddress,
  RunDeadlines deadlines = const RunDeadlines(),
  Duration settle = const Duration(seconds: 1),
  AzaharHost? azaharHost,
  Stream<List<int>> Function()? input,
  StringSink? out,
  StringSink? err,
}) => _RunCommand(
  DeviceRunner(
    start: start,
    transportFor: transportFor,
    listenAddress: listenAddress,
    deadlines: deadlines,
    settle: settle,
    azaharHost: azaharHost,
    input: input,
  ),
  out ?? stdout,
  err ?? stderr,
);

/// Adds the options shared by commands that build and run on a device
/// (`run`, `test`): target, mode (JIT on a console, AOT in Azahar), device,
/// wait, timeout,
/// host port, Azahar path, project directory, offline and SDK.
void addDeviceRunOptions(ArgParser parser) {
  addTargetOption(parser);
  parser
    ..addOption(
      'mode',
      help:
          'How the program is compiled. Defaults to jit on a console and '
          'aot in Azahar.',
      allowed: [BuildMode.jit.name, BuildMode.aot.name],
      allowedHelp: {
        'jit': 'Kernel file run by the JIT VM; builds faster.',
        'aot': 'Ahead-of-time snapshot linked into the application.',
      },
    )
    ..addOption(
      'device',
      abbr: 'd',
      help:
          'The device to run on: a console\'s IPv4 address, "console" to '
          'find one on the local network, or "azahar" for the Azahar '
          'emulator.',
      valueHelp: 'device',
      defaultsTo: 'console',
    )
    ..addOption(
      'wait',
      help: 'Seconds to wait for a console\'s netloader to answer.',
      defaultsTo: '30',
    )
    ..addOption(
      'timeout',
      help: 'Seconds the program may run before the run is stopped.',
      valueHelp: 's',
    )
    ..addOption(
      'host-port',
      help: 'TCP port this computer listens on for the program\'s output.',
      defaultsTo: '$defaultHostPort',
    )
    ..addOption(
      'azahar',
      help:
          'The Azahar executable for -d azahar; defaults to '
          'DARTBREW_AZAHAR, then azahar on PATH.',
      valueHelp: 'path',
    )
    ..addOption(
      'project-directory',
      help: "The project's root; defaults to the current directory.",
      valueHelp: 'dir',
    )
    ..addFlag(
      'offline',
      negatable: false,
      help: 'Resolve packages using only the local pub cache.',
    );
  addSdkOption(parser);
}

/// The validated options added by [addDeviceRunOptions].
final class DeviceRunSettings {
  final Target target;
  final BuildMode mode;

  /// The console to upload to, or null to discover one. Unused when
  /// [azahar] is set.
  final InternetAddress? address;

  /// Whether to run in Azahar (`-d azahar`) instead of on a console.
  final bool azahar;

  /// The `--azahar` executable path, if given.
  final String? azaharPath;
  final Duration wait;
  final Duration? timeout;
  final int hostPort;

  /// The resolved project root.
  final String project;
  final bool offline;
  final String sdkPath;

  const DeviceRunSettings({
    required this.target,
    required this.mode,
    required this.address,
    required this.wait,
    required this.timeout,
    required this.hostPort,
    required this.project,
    required this.offline,
    required this.sdkPath,
    this.azahar = false,
    this.azaharPath,
  });

  /// Reads and checks [args]; throws a [UsageException] with [usage] when an
  /// option is invalid.
  factory DeviceRunSettings.parse(ArgResults args, String usage) {
    Duration? seconds(String option, {bool allowZero = false}) {
      final text = args.option(option);
      if (text == null) return null;
      final value = num.tryParse(text);
      if (value == null ||
          !value.isFinite ||
          value < 0 ||
          (value == 0 && !allowZero)) {
        throw UsageException('--$option must be a number of seconds.', usage);
      }
      return Duration(milliseconds: (value * 1000).round());
    }

    final hostPort = int.tryParse(args.option('host-port')!);
    if (hostPort == null || hostPort < 1 || hostPort > 65535) {
      throw UsageException(
        '--host-port must be a port from 1 to 65535.',
        usage,
      );
    }
    final device = args.option('device')!;
    InternetAddress? address;
    if (device != 'console' && device != 'azahar') {
      address = InternetAddress.tryParse(device);
      if (address == null || address.type != InternetAddressType.IPv4) {
        throw UsageException(
          '-d must be "console", "azahar" or a console\'s IPv4 address.',
          usage,
        );
      }
    }
    final azahar = device == 'azahar';
    final mode = switch (args.option('mode')) {
      final named? => BuildMode.values.byName(named),
      null => azahar ? BuildMode.aot : BuildMode.jit,
    };
    if (azahar && mode == BuildMode.jit) {
      // The JIT VM publishes code with Luma3DS's custom cache SVC, which
      // Azahar's emulated kernel does not provide; the VM aborts at startup.
      throw UsageException(
        'JIT needs Luma3DS, which Azahar does not emulate. Use --mode aot '
        'in Azahar, or run JIT on a console.',
        usage,
      );
    }
    return DeviceRunSettings(
      target: selectedTarget(args),
      mode: mode,
      address: address,
      wait: seconds('wait', allowZero: true)!,
      timeout: seconds('timeout'),
      hostPort: hostPort,
      project: Directory(
        args.option('project-directory') ?? Directory.current.path,
      ).resolveSymbolicLinksSync(),
      offline: args.flag('offline'),
      sdkPath: sdkDirectory(args),
      azahar: azahar,
      azaharPath: args.option('azahar'),
    );
  }
}

/// Why a device run could not start or finish: no console, several
/// consoles, a busy host port, or a failed upload. [message] is for the user.
final class RunAbort implements Exception {
  final int exitCode;
  final String message;

  const RunAbort(this.exitCode, this.message);

  @override
  String toString() => message;
}

/// What [DeviceRunner.call] built and how the run went.
final class DeviceRun {
  final CtrBuild build;

  /// The directory holding the application and the `work/` build files.
  final Directory output;

  /// The schema-2 run identity the app was started with.
  final Map<String, Object> identity;
  final RunResult result;

  const DeviceRun(this.build, this.output, this.identity, this.result);
}

/// Builds an entrypoint, starts it on a device and streams its records.
final class DeviceRunner {
  final ProcessStarter start;

  /// Picks the network transport per target.
  final TransportForTarget transportFor;

  /// Where the host listener binds, or null for the default (see
  /// [listenAddressFor]).
  final InternetAddress? listenAddress;

  /// The connect and idle deadlines. Their `timeout` is replaced by
  /// [DeviceRunSettings.timeout].
  final RunDeadlines deadlines;

  /// How long discovery keeps listening after the first console answers.
  final Duration settle;

  /// The environment, operating system and working directory used to find
  /// Azahar and its SD card; the real host by default.
  final AzaharHost? azaharHost;

  /// Opens the program's stdin, such as the terminal's, to send to the app
  /// while it runs (see [runOnDevice]); null sends none. Dart's own `stdin`
  /// can be listened to once, so one runner serves one run with it.
  final Stream<List<int>> Function()? input;

  NativeSdk? _sdk;

  DeviceRunner({
    this.start = startProcess,
    this.transportFor = defaultTransportFor,
    this.listenAddress,
    this.deadlines = const RunDeadlines(),
    this.settle = const Duration(seconds: 1),
    this.azaharHost,
    this.input,
  });

  /// Where the host listener binds for a run with [settings]: [listenAddress]
  /// when given, else loopback for Azahar, which runs on this host, and all
  /// IPv4 interfaces for a console.
  InternetAddress listenAddressFor(DeviceRunSettings settings) =>
      listenAddress ??
      (settings.azahar
          ? InternetAddress.loopbackIPv4
          : InternetAddress.anyIPv4);

  /// The SDK the latest [call] verified, or null before any call has.
  NativeSdk? get sdk => _sdk;

  /// Verifies the SDK, builds [entry] (inside [DeviceRunSettings.project])
  /// into `.dart_tool/dartbrew/<buildDirectory>/<target>/<mode>/` of the
  /// project (emptied first), binds the host listener, chooses the device,
  /// then launches and streams the app, passing each output record's text to
  /// [onOutput]. Each command passes its own [buildDirectory] (`run`,
  /// `test`) so one command's build never deletes another's.
  ///
  /// The application is named `dartbrew-<fixture>-<mode>.3dsx` so repeated
  /// runs overwrite it on the SD card. [fixture] defaults to [fixtureFor].
  /// Prompts and build progress go to [err]. Throws a [RunAbort] when no
  /// single device can be used, Azahar or its SD card is not found, or the
  /// upload or Azahar launch fails; build failures throw as in
  /// [Target.build]. Azahar is closed when the run ends or fails.
  Future<DeviceRun> call(
    DeviceRunSettings settings, {
    required String entry,
    String? fixture,
    required void Function(String text) onOutput,
    required StringSink err,
    String buildDirectory = 'run',
  }) async {
    final target = settings.target;
    ({RunDevice device, String description})? emulator;
    if (settings.azahar) {
      try {
        emulator = target.emulator(
          host: azaharHost ?? AzaharHost.current(),
          path: settings.azaharPath,
          start: start,
        );
      } on AzaharNotFound catch (error) {
        throw RunAbort(1, error.message);
      }
    }
    final sdk = _sdk = await NativeSdk.load(settings.sdkPath);
    final project = settings.project;
    final mode = settings.mode;
    final name = fixture ?? fixtureFor(project, entry);
    final output = Directory(
      p.join(
        project,
        '.dart_tool',
        'dartbrew',
        buildDirectory,
        target.name,
        mode.name,
      ),
    );
    if (output.existsSync()) output.deleteSync(recursive: true);
    final work = Directory(p.join(output.path, 'work'))
      ..createSync(recursive: true);
    final build = await target.build(
      sdk: sdk,
      project: project,
      entry: entry,
      mode: mode,
      fixture: name,
      work: work,
      application: File(
        p.join(
          output.path,
          'dartbrew-$name-${mode.name}.${target.applicationExtension}',
        ),
      ),
      offline: settings.offline,
      start: start,
      warnings: err,
    );

    final ServerSocket listener;
    try {
      listener = await ServerSocket.bind(
        listenAddressFor(settings),
        settings.hostPort,
      );
    } on SocketException catch (error) {
      throw RunAbort(
        1,
        'Could not listen on TCP port ${settings.hostPort} '
        '(${error.osError?.message ?? error.message}). Close the program '
        'using it or choose another port with --host-port.',
      );
    }
    try {
      final RunDevice device;
      final appName = p.basename(build.application.path);
      if (emulator != null) {
        device = emulator.device;
        err.writeln('Starting $appName in ${emulator.description}.');
      } else {
        final transport = transportFor(target);
        final console = ConsoleDevice(
          transport,
          settings.address ??
              await discoverConsole(
                transport,
                wait: settings.wait,
                settle: settle,
                prompt: err,
              ),
        );
        device = console;
        err.writeln('Sending $appName to ${console.address.address}.');
      }
      final identity = runIdentity(
        build,
        newRunId(),
        environment: device.environment,
        schema: 2,
      );
      try {
        final result = await runOnDevice(
          device: device,
          app: build.application,
          identity: identity,
          listener: listener,
          deadlines: RunDeadlines(
            connect: deadlines.connect,
            idle: deadlines.idle,
            timeout: settings.timeout,
          ),
          onOutput: onOutput,
          input: input,
        );
        return DeviceRun(build, output, identity, result);
      } finally {
        await device.dispose();
      }
    } on ConsoleSelectionException catch (error) {
      throw RunAbort(error.exitCode, error.message);
    } on NetloaderException catch (error) {
      throw RunAbort(1, error.message);
    } on ProcessException catch (error) {
      throw RunAbort(
        1,
        'Could not start Azahar at ${error.executable}: ${error.message}',
      );
    } finally {
      await listener.close();
    }
  }
}

class _RunCommand extends Command<int> {
  final DeviceRunner _runner;
  final StringSink _out;
  final StringSink _err;

  _RunCommand(this._runner, this._out, this._err) {
    addDeviceRunOptions(argParser);
    argParser.addFlag(
      'verdict',
      negatable: false,
      help:
          'Print the run\'s verdict as JSON and write run.json next to the '
          'build.',
    );
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Run a Dart program on a device.';

  @override
  String get invocation => 'dartbrew run [arguments] [<entry.dart>]';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length > 1) {
      throw UsageException('run takes at most one entrypoint.', usage);
    }
    final settings = DeviceRunSettings.parse(args, usage);
    final path = args.rest.isEmpty
        ? p.join(settings.project, 'bin', 'main.dart')
        : args.rest.single;
    if (!File(path).existsSync()) {
      throw UsageException('No entrypoint at $path.', usage);
    }
    final entry = File(path).resolveSymbolicLinksSync();
    if (!p.isWithin(settings.project, entry)) {
      throw UsageException(
        'The entrypoint must be inside the project directory.',
        usage,
      );
    }

    final DeviceRun run;
    try {
      run = await _runner(
        settings,
        entry: entry,
        onOutput: _out.writeln,
        err: _err,
      );
    } on RunAbort catch (error) {
      _err.writeln(error.message);
      return error.exitCode;
    }
    final result = run.result;
    if (result.exit.message case final message?) _err.writeln(message);
    if (args.flag('verdict')) {
      writeRunRecord(run.output.path, run.identity);
      _out.writeln(
        jsonEncode({
          'outcome': result.verdict.outcome.name,
          'reason': result.verdict.reason,
          'run_id': run.identity['run_id'],
          'artifact_sha256': run.identity['artifact_sha256'],
          'exit_code': ?result.verdict.exitCode,
        }),
      );
    }
    return result.exit.code;
  }
}
