import 'dart:io';

import 'package:args/command_runner.dart';

import '../sdk.dart';

class DoctorCommand extends Command<int> {
  @override
  String get name => 'doctor';

  @override
  String get description => 'Verify the bundled tools and runtime assets.';

  DoctorCommand() {
    addSdkOption(argParser);
  }

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isNotEmpty) {
      throw UsageException('doctor takes no arguments.', usage);
    }
    final sdk = await NativeSdk.load(sdkDirectory(args));
    sdk.verifyAllAssets();
    stdout.writeln(
      'Verified native SDK for ${currentHost()}; '
      '${sdk.manifest.files.length} assets.',
    );
    return 0;
  }
}
