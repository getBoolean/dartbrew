import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'build_identity.dart';

/// Archive members in the order the producer linker sees them.
List<String> archiveObjects(String query) {
  final members = <String>[];
  for (final line in const LineSplitter().convert(query)) {
    if (line == '  outputs:') break;
    if (!line.startsWith('    ')) continue;
    final name = line.trim();
    if (name.startsWith('|')) continue;
    if (!name.endsWith('.o')) {
      throw FormatException('Unexpected archive input $name');
    }
    members.add(name);
  }
  if (members.isEmpty) throw const FormatException('Archive has no objects');
  return members;
}

/// Inputs of [objects] with complete and valid Ninja compiler dependency data.
Set<String> ninjaDependencies(String log, Set<String> objects) {
  final remaining = {...objects};
  final paths = <String>{};
  final header = RegExp(r'^(.+): #deps (\d+), deps mtime \d+ \((\w+)\)$');
  var requiredLines = 0;
  for (final line in const LineSplitter().convert(log)) {
    if (line.startsWith('    ') && requiredLines > 0) {
      paths.add(line.substring(4));
      requiredLines--;
    } else if (line.isNotEmpty && !line.startsWith('    ')) {
      if (requiredLines != 0) {
        throw FormatException('Incomplete dependencies before $line');
      }
      final match = header.firstMatch(line);
      if (match == null || !remaining.remove(match[1])) continue;
      requiredLines = int.parse(match[2]!);
      if (match[3] != 'VALID' || requiredLines == 0) {
        throw FormatException(
          'Rebuild the target to refresh dependencies for ${match[1]}',
        );
      }
    }
  }
  if (remaining.isNotEmpty || requiredLines != 0) {
    throw FormatException(
      'Incomplete Ninja dependencies: ${remaining.take(4).join(', ')}',
    );
  }
  return paths;
}

/// Source mapping shared by compile flags and the dependency-file collector.
final class SourceClosure {
  final Map<String, String> roots;
  final String devkitPro;
  final Map<String, File> files = {};

  SourceClosure(this.roots, this.devkitPro);

  String _inRoot(String path, String root) => p.relative(path, from: root);

  String mapPath(String path) {
    final absolute = p.normalize(path);
    if (absolute == devkitPro) return '@devkitpro@';
    if (p.isWithin(devkitPro, absolute)) {
      return '@devkitpro@/${_inRoot(absolute, devkitPro)}';
    }
    for (final entry in roots.entries) {
      if (absolute == entry.key) return '@src@/${entry.value}';
      if (p.isWithin(entry.key, absolute)) {
        return '@src@/${entry.value}/${_inRoot(absolute, entry.key)}';
      }
    }
    throw FormatException(
      'Native dependency outside declared source roots: $absolute',
    );
  }

  String collect(String path) {
    final file = File(p.normalize(path));
    final mapped = mapPath(file.path);
    if (mapped.startsWith('@devkitpro@')) return mapped;
    final actual = file.resolveSymbolicLinksSync();
    final root = roots.keys.firstWhere((r) => p.isWithin(r, file.path));
    if (!p.isWithin(root, actual)) {
      throw FormatException('Source dependency escapes $root: $path');
    }
    final name = mapped.substring('@src@/'.length);
    files[name] = file;
    return name;
  }
}

/// Splits words written by Ninja with POSIX single quotes or backslash escaping.
/// Unrecognized shell constructs are rejected rather than changing their meaning.
List<String> _words(String command) {
  final words = <String>[];
  var word = StringBuffer();
  var quoted = false;
  var escaped = false;
  for (final r in command.runes) {
    final char = String.fromCharCode(r);
    if (escaped) {
      word.write(char);
      escaped = false;
      continue;
    }
    if (char == "'") {
      quoted = !quoted;
      continue;
    }
    if (quoted) {
      word.write(char);
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (char == ' ' || char == '\t') {
      if (word.isNotEmpty) {
        words.add(word.toString());
        word = StringBuffer();
      }
      continue;
    }
    if ('"();|&<>'.contains(char) || r'$'.contains(char)) {
      throw FormatException(
        'Unsupported shell character in compile command: $char',
      );
    }
    word.write(char);
  }
  if (quoted || escaped) {
    throw const FormatException('Incomplete quoted compile argument');
  }
  if (word.isNotEmpty) words.add(word.toString());
  return words;
}

typedef CompileUnit = ({
  String compiler,
  List<String> flags,
  String source,
  String group,
});
Map<String, Object> unitJson(CompileUnit u) => {
  'compiler': u.compiler,
  'flags': u.flags,
  'source': u.source,
  'group': u.group,
};

/// Captures a native archive compile, retaining its compiler flags and input.
CompileUnit captureUnit(
  Map<String, Object?> row,
  String group,
  SourceClosure closure,
  TargetProfile profile,
) {
  final directory = row['directory']! as String;
  final args = _words(row['command']! as String);
  final compiler = args.first;
  final tool = ['gcc', 'g++'].singleWhere(
    (s) => compiler == '${profile.compilerPrefix}$s',
    orElse: () => throw FormatException('Unexpected compiler $compiler'),
  );
  final source = row['file']! as String;
  final flags = <String>[];
  for (var i = 1; i < args.length; i++) {
    final flag = args[i];
    switch (flag) {
      case '-c':
        if (args[++i] != source) {
          throw FormatException(
            'Source differs from compilation database: $source',
          );
        }
      case '-o':
        if (args[++i] != row['output']) {
          throw FormatException(
            'Output differs from compilation database for $source',
          );
        }
      case '-MF':
        i++;
      case '-Werror' || '-MMD':
        break;
      default:
        if (flag.startsWith('-I')) {
          final include = flag.length == 2 ? args[++i] : flag.substring(2);
          flags.add('-I${closure.mapPath(p.join(directory, include))}');
        } else {
          if (flag.contains('/') || !flag.startsWith('-')) {
            throw FormatException(
              'Unsupported path or argument in target compile: $flag',
            );
          }
          flags.add(flag);
        }
    }
  }
  final bundledSource = closure.collect(p.join(directory, source));
  if (bundledSource.startsWith('@devkitpro@')) {
    throw FormatException(
      'Archive requires a devkitPro translation unit: $source',
    );
  }
  return (compiler: tool, flags: flags, source: bundledSource, group: group);
}

/// Derives one mode's relocatable translation units and source closure from
/// the built archive membership, compile database and GCC dependencies.
Future<({List<Map<String, Object>> units, Map<String, File> files})>
captureCompilePlan({
  required String sourcePath,
  required String build,
  required Directory repository,
  required BuildMode mode,
  required TargetProfile profile,
  required Future<String> Function(String, List<String>, {String? cwd}) run,
}) async {
  final devkit = p.dirname(profile.libctru);
  final launcher = p.join(repository.path, 'runtime/ctr/source');
  final tools = p.join(repository.path, 'toolchain');
  final ninja = p.join(sourcePath, 'buildtools/ninja/ninja');
  final groups = {
    'runtime': mode == BuildMode.aot
        ? 'obj/runtime/libdart_aotruntime.a'
        : 'obj/runtime/libdart_jit.a',
    'io': 'obj/runtime/bin/ctr/libdart_io.a',
  };
  Future<String> tool(List<String> args) =>
      run(ninja, ['-C', build, '-t', ...args]);
  final rows =
      jsonDecode(await tool(['compdb-targets', ...groups.values]))
          as List<Object?>;
  final byOutput = {
    for (final row in rows.cast<Map<String, Object?>>())
      row['output']! as String: row,
  };
  final closure = SourceClosure({
    p.join(build, 'gen'): 'gen/${mode.name}',
    sourcePath: 'sdk',
    launcher: 'launcher',
    tools: 'toolchain',
  }, devkit);
  final plan = <CompileUnit>[];
  final objects = <String>{};
  for (final entry in groups.entries) {
    for (final obj in archiveObjects(await tool(['query', entry.value]))) {
      final row = byOutput[obj];
      if (row == null) {
        throw FormatException('Missing compiler command for $obj');
      }
      objects.add(obj);
      plan.add(captureUnit(row, entry.key, closure, profile));
    }
  }
  for (final dep in ninjaDependencies(await tool(['deps']), objects)) {
    closure.collect(p.join(build, dep));
  }
  final vm = plan.singleWhere(
    (u) => u.source == 'sdk/runtime/vm/os_thread_ctr.cc',
  );
  final flags = [
    ...vm.flags,
    '-I@src@/launcher',
    '-I@src@/sdk/runtime/include',
  ];
  final compilerFlags = [for (final f in flags) _producerFlag(f, closure)];
  final launchers =
      Directory(launcher)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.cc'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final sourceFile in [
    ...launchers,
    File(p.join(tools, 'native_layout_check.cc')),
    File(p.join(tools, 'soft_math_bridge.cc')),
  ]) {
    final isMath = p.basename(sourceFile.path) == 'soft_math_bridge.cc';
    final deps = await run('${profile.compilerPrefix}g++', [
      ...compilerFlags,
      '-MM',
      '-MT',
      'unit',
      sourceFile.path,
    ], cwd: build);
    for (final dep in _makeDependencies(deps)) {
      closure.collect(p.join(build, dep));
    }
    final name = closure.collect(sourceFile.path);
    if (!isMath) {
      plan.add((
        source: name,
        compiler: 'g++',
        flags: flags,
        group: sourceFile.parent.path == tools ? 'check' : 'launcher',
      ));
    }
  }
  return (
    units: [for (final unit in plan) unitJson(unit)],
    files: closure.files,
  );
}

String _producerFlag(String flag, SourceClosure closure) {
  if (flag.startsWith('-I@src@/')) {
    final value = flag.substring('-I@src@/'.length);
    for (final entry in closure.roots.entries) {
      if (value == entry.value) return '-I${entry.key}';
      if (value.startsWith('${entry.value}/')) {
        return '-I${p.join(entry.key, value.substring(entry.value.length + 1))}';
      }
    }
    throw FormatException('Unknown source include path: $flag');
  }
  return flag.replaceAll('@devkitpro@', closure.devkitPro);
}

Iterable<String> _makeDependencies(String text) sync* {
  final line = text.replaceAll(RegExp(r'\\\r?\n'), '');
  if (!line.startsWith('unit:')) {
    throw FormatException('Invalid compiler dependency output: $line');
  }
  for (final match in RegExp(
    r'(?:\\.|[^\s\\])+',
  ).allMatches(line.substring(5))) {
    yield match[0]!.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
  }
}
