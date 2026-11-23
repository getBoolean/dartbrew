import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartbrew/src/cache.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final cache = NativeCache(Directory(args[0]));
  final label = args[1];
  final wait = args.contains('hold');
  // Output lets the harness drive both ends of the lock without timing
  // assumptions about the time needed to launch a second Dart VM.
  final waiting = Timer(
    const Duration(milliseconds: 250),
    () => stdout.writeln('contended'),
  );
  final entry = await cache.getOrBuild('sample', (stage) async {
    waiting.cancel();
    File(p.join(stage.path, 'artifact')).writeAsStringSync(label);
    stdout.writeln('building');
    if (wait) await stdin.transform(utf8.decoder).first;
  });
  waiting.cancel();
  stdout.writeln(
    'read:${File(p.join(entry.path, 'artifact')).readAsStringSync()}',
  );
}
