import 'dart:io';

import 'package:args/command_runner.dart';

import 'commands/compile.dart';
import 'commands/create.dart';
import 'commands/devices.dart';
import 'commands/doctor.dart';
import 'commands/passthrough.dart';
import 'commands/run.dart';
import 'commands/test.dart';
import 'errors.dart';

/// The version injected at compile time with `-DDARTBREW_VERSION=<version>`.
const version = String.fromEnvironment(
  'DARTBREW_VERSION',
  defaultValue: 'development',
);

CommandRunner<int> createRunner() {
  final runner =
      CommandRunner<int>(
          'dartbrew',
          'A command-line utility for building, running and testing Dart '
              'programs on homebrew targets.',
        )
        ..addCommand(createCommand())
        ..addCommand(compileCommand())
        // The terminal's stdin becomes the app's stdin (R3). It is opened
        // only when an app connects.
        ..addCommand(runCommand(input: () => stdin))
        ..addCommand(
          testCommand(
            input: () => stdin,
            // Ctrl-C still ends the report with its done event.
            interrupts: ProcessSignal.sigint.watch,
          ),
        )
        ..addCommand(devicesCommand())
        ..addCommand(DoctorCommand());
  passthroughCommands().forEach(runner.addCommand);
  return runner;
}

/// Runs dartbrew and returns its exit code.
///
/// Usage errors exit 64, malformed input 65, file-system errors 78, a
/// [DartbrewException] with its own code, and a failed child process with
/// its own code (70 when it has none).
Future<int> runCli(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln(version);
    return 0;
  }
  final unsupported = unsupportedInvocationMessage(arguments);
  if (unsupported != null) {
    stderr.writeln(unsupported);
    return 64;
  }
  try {
    return await createRunner().run(forwardHelpArguments(arguments)) ?? 0;
  } on UsageException catch (error) {
    stderr.writeln('${error.message}\n${error.usage}');
    return 64;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    return 65;
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    return 78;
  } on DartbrewException catch (error) {
    stderr.writeln(error.message);
    return error.exitCode;
  } on ProcessException catch (error) {
    stderr.writeln(error.message);
    return error.errorCode > 0 ? error.errorCode : 70;
  }
}
