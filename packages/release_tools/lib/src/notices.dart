import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes the SDK's license index from the native source component, toolchain
/// pins and the CLI's resolved production dependency graph.
Future<void> writeNotices({
  required Directory repository,
  required Directory sdk,
  required Map<String, Object?> pins,
  required Map<String, Object?> pubGraph,
  required Iterable<String> sourceNotices,
}) async {
  final out = Directory(p.join(sdk.path, 'notices'));
  await out.create();
  final licenses = Directory(p.join(repository.path, 'release', 'licenses'));
  final index = StringBuffer('# Bundled software\n\n');
  Future<void> copyLicense(File source, String name) async {
    await source.copy(p.join(out.path, name));
  }

  final packages = {
    for (final package
        in (pubGraph['packages']! as List<Object?>)
            .cast<Map<String, Object?>>())
      package['name']! as String: package,
  };
  final root = packages[pubGraph['root']]!;
  await copyLicense(
    File(p.join(repository.path, 'LICENSE')),
    'dartbrew.LICENSE',
  );
  index.writeln('- dartbrew ${root['version']} — [license](dartbrew.LICENSE)');
  final sdkPin = pins['dart']! as Map<String, Object?>;
  await copyLicense(
    File(p.join(sdk.path, 'host-dart', 'LICENSE')),
    'host-dart.LICENSE',
  );
  index.writeln(
    '- Dart SDK ${sdkPin['version']} (upstream ${sdkPin['revision']}) — [license](host-dart.LICENSE)',
  );
  final pending = (root['directDependencies']! as List<Object?>)
      .cast<String>()
      .toList();
  final included = <String>{};
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    if (!included.add(name)) continue;
    final record = packages[name]!;
    pending.addAll((record['dependencies']! as List<Object?>).cast<String>());
  }
  for (final name in included.toList()..sort()) {
    final license = '$name.LICENSE';
    await copyLicense(File(p.join(licenses.path, license)), license);
    final extra = '$name.LICENSE-other.md';
    final extraFile = File(p.join(licenses.path, extra));
    final line = StringBuffer(
      '- $name ${packages[name]!['version']} — [license]($license)',
    );
    if (await extraFile.exists()) {
      await copyLicense(extraFile, extra);
      line.write(', [additional notices]($extra)');
    }
    index.writeln(line);
  }
  // image's bundled additional notices reference the MPL's full text.
  if (included.contains('image')) {
    await copyLicense(
      File(p.join(licenses.path, 'MPL-2.0.txt')),
      'MPL-2.0.txt',
    );
  }
  for (final name in sourceNotices.toList()..sort()) {
    index.writeln('- Native source: [${p.posix.basename(name)}]($name)');
  }
  await File(p.join(out.path, 'README.md')).writeAsString(index.toString());
}
