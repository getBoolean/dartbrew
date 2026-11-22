import 'dart:io';

import 'package:release_tools/src/release_check.dart';
import 'package:release_tools/src/upstream.dart';

const _usage =
    'Reports which pins in toolchain/versions.json have newer upstream '
    'releases.\n\n'
    'Usage: check_upstream';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  final client = upstreamHttpClient();
  try {
    final report = await checkUpstream(
      Pins.parse(await (await pinTable()).readAsString()),
      httpFetchJson(client),
    );
    stdout.writeAll(report.lines, '\n');
    stdout.writeln();
  } on UpstreamUnavailable catch (error) {
    stderr.writeln('check_upstream: $error');
    exitCode = 1;
  } finally {
    client.close();
  }
}
