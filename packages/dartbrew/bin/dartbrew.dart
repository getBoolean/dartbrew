import 'dart:io';

import 'package:dartbrew/src/cli.dart';
import 'package:dartbrew/src/build_worker.dart';

Future<void> main(List<String> arguments) async {
  if (await serveBuildWorker(arguments)) return;
  exitCode = await runCli(arguments);
}
