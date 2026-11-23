import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/build_identity.dart';
import 'package:release_tools/src/compile_plan.dart';
import 'package:release_tools/src/release_check.dart';
import 'package:test/test.dart';

void main() {
  test(
    'compiler inputs keep their order and omit host paths and dependency flags',
    () async {
      final root = Directory.systemTemp.createTempSync('runtime-source-');
      addTearDown(() => root.deleteSync(recursive: true));
      final profile = TargetProfile.load(
        File(p.join(await repositoryRoot(), 'toolchain', 'target-ctr.json')),
      );
      final file = File(p.join(root.path, 'file name.cc'))
        ..writeAsStringSync('int value;');
      final devkit = p.join(root.parent.path, 'devkitpro');
      final closure = SourceClosure({root.path: 'sdk'}, devkit);
      final unit = captureUnit(
        {
          'directory': root.path,
          'output': 'unit.o',
          'file': 'file name.cc',
          'command':
              "${profile.compilerPrefix}g++ -MMD -MF obj.d -I. -Wall -Werror -DVAL=2 -c 'file name.cc' -o unit.o",
        },
        'runtime',
        closure,
        profile,
      );
      expect(unitJson(unit), {
        'compiler': 'g++',
        'source': 'sdk/file name.cc',
        'flags': ['-I@src@/sdk', '-Wall', '-DVAL=2'],
        'group': 'runtime',
      });
      expect(closure.files.values.single.path, file.path);
      expect(closure.collect(p.join(devkit, 'inc.h')), '@devkitpro@/inc.h');
      expect(closure.files, hasLength(1));
      expect(
        () => closure.collect(p.join(root.parent.path, 'other.h')),
        throwsFormatException,
      );
    },
  );
  test('requires a valid dependency record for every archived object', () {
    const deps = 'obj/x.o: #deps 2, deps mtime 1 (VALID)\n    x.cc\n    a.h\n';
    expect(ninjaDependencies(deps, {'obj/x.o'}), {'x.cc', 'a.h'});
    expect(() => ninjaDependencies(deps, {'missing.o'}), throwsFormatException);
    expect(
      () => ninjaDependencies(deps.replaceFirst('VALID', 'STALE'), {'obj/x.o'}),
      throwsFormatException,
    );
    expect(
      () => ninjaDependencies(deps.replaceFirst('#deps 2', '#deps 3'), {
        'obj/x.o',
      }),
      throwsFormatException,
    );
  });

  test('archive order excludes order-only prerequisites and outputs', () {
    const query =
        'obj/lib.a:\n  input: alink\n    z.o\n    a.o\n'
        '    || phony/stamp\n  outputs:\n    other.o\n';
    expect(archiveObjects(query), ['z.o', 'a.o']);
  });
}
