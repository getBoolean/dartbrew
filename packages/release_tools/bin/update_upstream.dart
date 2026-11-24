import 'dart:io';

import 'package:args/args.dart';
import 'package:release_tools/src/release_check.dart';
import 'package:release_tools/src/upstream.dart';

/// The pins this tool can bump.
const _components = ['devkitpro'];

final _usage =
    'Bumps one pin in toolchain/versions.json to its newest upstream.\n\n'
    'Usage: update_upstream [--versions <versions.json>] <component>\n'
    'Components: ${_components.join(', ')}';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('versions', help: 'The pin table to rewrite.');
  final String? versionsPath;
  final String component;
  try {
    final options = parser.parse(arguments);
    versionsPath = options.option('versions');
    if (options.rest case [final name] when _components.contains(name)) {
      component = name;
    } else {
      throw ArgParserException(
        'Expected one component, got: ${options.rest.join(' ')}',
      );
    }
  } on ArgParserException catch (error) {
    stderr.writeln('${error.message}\n\n$_usage\n${parser.usage}');
    exitCode = 64;
    return;
  }
  final versions = versionsPath == null ? await pinTable() : File(versionsPath);
  switch (component) {
    case 'devkitpro':
      await _updateDevkitPro(versions);
  }
}

/// Pins the newest dated devkitARM image and the versions it contains.
Future<void> _updateDevkitPro(File versions) async {
  final text = await versions.readAsString();
  final pinned = Pins.parse(text).container;
  final client = upstreamHttpClient();
  final ImageTag newest;
  try {
    newest = (await datedImageTags(httpFetchJson(client))).first;
  } on UpstreamUnavailable catch (error) {
    stderr.writeln('update_upstream: $error');
    exitCode = 1;
    return;
  } finally {
    client.close();
  }
  if (newest.digest == pinned.digest) {
    stdout.writeln(
      'devkitpro: ${pinned.image} is current (tag ${newest.name})',
    );
    return;
  }
  final pin = await readImageVersions(newest.digest);
  await versions.writeAsString(rewriteContainerPin(text, pin));
  stdout.writeln(
    'devkitpro: ${pinned.image} -> ${pin.image} (tag ${newest.name})\n'
    '  devkitARM ${pinned.devkitArm} -> ${pin.devkitArm}\n'
    '  libctru ${pinned.libctru} -> ${pin.libctru}\n'
    '  gcc ${pinned.gcc} -> ${pin.gcc}\n'
    'Rebuild and qualify as docs/releasing.md describes.',
  );
}
