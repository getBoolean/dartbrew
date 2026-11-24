import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/host.dart';
import 'package:release_tools/src/precompiler.dart';
import 'package:release_tools/src/stage_runner.dart';
import 'package:test/test.dart';

String _sha(String text) => sha256.convert(utf8.encode(text)).toString();

const _head = 'abcdef0123456789abcdef0123456789abcdef01';
const _snapshotHash = '0123456789abcdef0123456789abcdef';
const _versionSource =
    'const char* Version::snapshot_hash_ = "$_snapshotHash";\n'
    'const char* Version::git_short_hash_ = "abcdef0123";\n';
const _graph = '    sources = [\n      "gen_snapshot.cc",\n    ]\n';
const _osSource =
    'intptr_t OS::ActivationFrameAlignment() {\n#if DART_HOST_OS_IOS\n'
    '#endif  // DART_HOST_OS_IOS\n}\n\nuintptr_t OS::CurrentRSS() {';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('precompiler-test-');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  File write(String relative, String content) =>
      File(p.join(root.path, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  group('GN arguments', () {
    const common = {
      'target_os': 'ctr',
      'dart_target_arch': 'arm',
      'dart_armv6k': true,
      'dart_use_compressed_pointers': false,
      'dart_use_crashpad': false,
      'dart_support_perfetto': false,
      'is_clang': true,
      'is_debug': false,
      'is_release': true,
    };
    for (final (host, expected) in [
      (
        Host.windowsX64,
        {
          ...common,
          'target_cpu': 'x64',
          'current_os': 'win',
          'current_cpu': 'x64',
        },
      ),
      (
        Host.linuxX64,
        {
          ...common,
          'target_cpu': 'x64',
          'current_os': 'linux',
          'current_cpu': 'x64',
        },
      ),
      (
        Host.macosArm64,
        {
          ...common,
          'target_cpu': 'arm64',
          'current_os': 'mac',
          'current_cpu': 'arm64',
          'mac_enable_relative_sdk_path': false,
        },
      ),
    ]) {
      test('build a native ${host.id} graph with the CTR ARM backend', () {
        expect(precompilerGnArguments(host), expected);
      });
    }
  });

  group('generated identity', () {
    test('is extracted from version.cc', () {
      expect(generatedIdentity(_versionSource, _head), {
        'snapshot_hash': _snapshotHash,
        'git_short_hash': 'abcdef0123',
      });
    });

    test('must match the patched source HEAD', () {
      expect(
        () => generatedIdentity(_versionSource, '0' * 40),
        throwsA(
          isA<PrecompilerFailure>().having(
            (failure) => failure.message,
            'message',
            contains('does not match'),
          ),
        ),
      );
    });

    test('must be unambiguous', () {
      expect(
        () => generatedIdentity(_versionSource * 2, _head),
        throwsA(
          isA<PrecompilerFailure>().having(
            (failure) => failure.message,
            'message',
            contains('ambiguous'),
          ),
        ),
      );
    });
  });

  test('CTR compiler definitions are required', () {
    expect(
      verifyCompilerDefines(
        'DART_TARGET_OS_CTR\nNDEBUG\nTARGET_ARCH_ARM\nDART_TARGET_ARMV6K\n',
      ),
      ['DART_TARGET_ARMV6K', 'DART_TARGET_OS_CTR', 'TARGET_ARCH_ARM'],
    );
    expect(
      () => verifyCompilerDefines('TARGET_ARCH_X64 DART_TARGET_OS_LINUX'),
      throwsA(isA<PrecompilerFailure>()),
    );
  });

  group('producer overlay', () {
    late File graph;
    late File osSource;
    late File stableSort;
    late File helper;

    setUp(() {
      graph = write('sdk/runtime/bin/BUILD.gn', _graph);
      osSource = write('sdk/runtime/vm/os_macos.cc', _osSource);
      stableSort = write('stable_sort.c', 'void qsort(void);\n');
      helper = File(p.join(root.path, 'sdk/runtime/bin/ctr_stable_sort.c'));
    });

    test('applies while building and restores the sources after', () async {
      final receipt = await withProducerOverlay(
        Directory(p.join(root.path, 'sdk')),
        stableSort,
        (receipt) async {
          expect(graph.readAsStringSync(), contains('"ctr_stable_sort.c"'));
          expect(osSource.readAsStringSync(), contains('DART_TARGET_OS_CTR'));
          expect(helper.readAsStringSync(), 'void qsort(void);\n');
          return receipt;
        },
      );
      expect(receipt['kind'], 'native-sort-and-target-alignment-v1');
      expect(receipt['files'], {
        'runtime/bin/BUILD.gn': {
          'base_sha256': _sha(_graph),
          'compiler_sha256': _sha(
            '    sources = [\n      "gen_snapshot.cc",\n'
            '      "ctr_stable_sort.c",\n    ]\n',
          ),
        },
        'runtime/vm/os_macos.cc': {
          'base_sha256': _sha(_osSource),
          'compiler_sha256': _sha(
            'intptr_t OS::ActivationFrameAlignment() {\n'
            '#if defined(DART_TARGET_OS_CTR)\n  return 8;\n#else\n'
            '#if DART_HOST_OS_IOS\n#endif  // DART_HOST_OS_IOS\n'
            '#endif  // DART_TARGET_OS_CTR\n}\n\n'
            'uintptr_t OS::CurrentRSS() {',
          ),
        },
        'runtime/bin/ctr_stable_sort.c': {
          'base_sha256': null,
          'compiler_sha256': _sha('void qsort(void);\n'),
        },
      });
      expect(graph.readAsStringSync(), _graph);
      expect(osSource.readAsStringSync(), _osSource);
      expect(helper.existsSync(), isFalse);
    });

    test('preserves a foreign edit made during the build', () async {
      await expectLater(
        withProducerOverlay(
          Directory(p.join(root.path, 'sdk')),
          stableSort,
          (_) async => graph.writeAsStringSync('foreign edit'),
        ),
        throwsA(
          isA<PrecompilerFailure>().having(
            (failure) => failure.message,
            'message',
            contains('changed'),
          ),
        ),
      );
      expect(graph.readAsStringSync(), 'foreign edit');
      expect(helper.existsSync(), isTrue);
    });
  });

  group('buildPrecompiler', () {
    const host = Host.linuxX64;
    late PrecompilerRequest request;
    late List<String> stages;
    late Map<String, Map<String, String>?> environments;
    late Directory buildDirectory;

    setUp(() {
      write('repository/toolchain/native_kernel.dart', 'driver');
      write('repository/release/native_stable_sort.c', 'stable sort');
      write('sdk/runtime/bin/BUILD.gn', _graph);
      write('sdk/runtime/vm/os_macos.cc', _osSource);
      write('sdk/buildtools/gn', 'gn binary');
      write('sdk/buildtools/ninja/ninja', 'ninja binary');
      write('sdk/buildtools/linux-x64/clang/bin/clang', 'clang binary');
      write('sdk/tools/sdks/dart-sdk/bin/dart', 'dart binary');
      write('sdk/tools/sdks/dart-sdk/version', '3.14.0');
      write('sdk/third_party/icu/.git/ctr-source.json', '{"head": "icu"}');
      final manifest = write(
        'versions.json',
        jsonEncode({
          'patches': <Object>[],
          'dependencies': {
            'gn': {
              'revision': 'gn-revision',
              'hosts': {
                'linux-x64': {
                  'package': 'gn/gn/linux-amd64',
                  'binary_sha256': _sha('gn binary'),
                },
              },
            },
            'clang': {'revision': 'clang-revision'},
            'ninja': {'version': '1.12.1'},
            'icu': {'revision': 'icu-revision'},
          },
        }),
      );
      final work = Directory(p.join(root.path, 'work'))..createSync();
      buildDirectory = Directory(p.join(work.path, 'native-build'));
      request = PrecompilerRequest(
        host: host,
        repository: Directory(p.join(root.path, 'repository')),
        source: Directory(p.join(root.path, 'sdk')),
        depotTools: Directory(p.join(root.path, 'depot_tools')),
        work: work,
        output: Directory(p.join(root.path, 'output')),
        manifest: manifest,
        python: 'python3',
        jobs: 2,
      );
      stages = [];
      environments = {};
    });

    /// Stands in for every build tool: records the stage and writes what the
    /// real tool would print or produce.
    Future<void> fakeTools(
      String executable,
      List<String> arguments,
      String stage, {
      String? workingDirectory,
      Map<String, String>? environment,
    }) async {
      stages.add(stage);
      environments[stage] = environment;
      void log(String text) =>
          File(p.join(request.work.path, '$stage.log')).writeAsStringSync(text);
      void produce(String path, String content) => File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      switch (stage) {
        case 'verify-checkout' || 'reverify-checkout':
          log('note from git\n{"head": "$_head", "inputs": {}}\n');
        case 'clang-version':
          log('clang version 20.0.0\n');
        case 'ninja-version':
          log('1.12.1\n');
        case 'gn-defines':
          expect(
            File(
              p.join(root.path, 'sdk/runtime/bin/ctr_stable_sort.c'),
            ).readAsStringSync(),
            'stable sort',
          );
          log('DART_TARGET_OS_CTR\nTARGET_ARCH_ARM\nDART_TARGET_ARMV6K\n');
        case 'ninja':
          produce(p.join(buildDirectory.path, 'gen_snapshot'), 'gen_snapshot');
          produce(
            p.join(buildDirectory.path, 'gen/runtime/version.cc'),
            _versionSource,
          );
        case 'gen-snapshot-version':
          log('Dart SDK version: 3.14.0 (ctr)\n');
        case 'ctr-kernel':
          produce(arguments[arguments.indexOf('-o') + 1], 'ctr-kernel');
      }
    }

    test('writes a receipt that hashes the produced files', () async {
      await buildPrecompiler(request, run: fakeTools);

      final receipt =
          jsonDecode(
                File(
                  p.join(request.output.path, 'native-precompiler.json'),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(receipt['host'], 'linux-x64');
      expect(receipt['source'], {'head': _head, 'inputs': <String, Object>{}});
      expect(receipt['icu'], {'head': 'icu'});
      expect(receipt['generated'], {
        'snapshot_hash': _snapshotHash,
        'git_short_hash': 'abcdef0123',
      });
      expect(receipt['gn'], {
        'revision': 'gn-revision',
        'package': 'gn/gn/linux-amd64',
        'binary_sha256': _sha('gn binary'),
      });
      expect(receipt['compiler'], {
        'pin': {'revision': 'clang-revision'},
        'sha256': _sha('clang binary'),
        'version': 'clang version 20.0.0',
      });
      expect(receipt['executable'], {
        'path': 'gen_snapshot',
        'sha256': _sha('gen_snapshot'),
        'version': 'Dart SDK version: 3.14.0 (ctr)',
      });
      expect(receipt['kernel_compiler'], {
        'path': 'ctr-kernel',
        'sha256': _sha('ctr-kernel'),
        'driver_sha256': _sha('driver'),
        'host_dart_sha256': _sha('dart binary'),
      });
      expect(receipt['host_dart'], {
        'bin/dart': {'sha256': _sha('dart binary'), 'executable': isA<bool>()},
        'version': {'sha256': _sha('3.14.0'), 'executable': isA<bool>()},
      });
      expect(receipt['compiler_defines'], [
        'DART_TARGET_ARMV6K',
        'DART_TARGET_OS_CTR',
        'TARGET_ARCH_ARM',
      ]);
      expect(
        File(p.join(request.output.path, 'gen_snapshot')).readAsStringSync(),
        'gen_snapshot',
      );
      expect(
        File(
          p.join(request.output.path, 'host-dart/bin/dart'),
        ).readAsStringSync(),
        'dart binary',
      );
      expect(
        File(p.join(buildDirectory.path, 'args.gn')).readAsStringSync(),
        contains('target_os = "ctr"\n'),
      );
      expect(stages.first, 'verify-checkout');
      expect(
        stages,
        containsAllInOrder(['gn-gen', 'ninja', 'reverify-checkout']),
      );
      expect(
        environments['gn-gen'],
        containsPair('DEPOT_TOOLS_WIN_TOOLCHAIN', '0'),
      );
    });

    test('stops before GN when the checkout fails verification', () async {
      Future<void> failingVerify(
        String executable,
        List<String> arguments,
        String stage, {
        String? workingDirectory,
        Map<String, String>? environment,
      }) async {
        stages.add(stage);
        throw StageFailure(executable, arguments, stage, 'dirty checkout', 1);
      }

      await expectLater(
        buildPrecompiler(request, run: failingVerify),
        throwsA(isA<StageFailure>()),
      );
      expect(stages, ['verify-checkout']);
      expect(
        File(p.join(root.path, 'sdk/runtime/bin/BUILD.gn')).readAsStringSync(),
        _graph,
      );
      expect(
        File(
          p.join(root.path, 'sdk/runtime/bin/ctr_stable_sort.c'),
        ).existsSync(),
        isFalse,
      );
      expect(request.output.existsSync(), isFalse);
    });

    test('refuses an existing output directory before verifying', () async {
      request.output.createSync();
      await expectLater(
        buildPrecompiler(request, run: fakeTools),
        throwsA(isA<PrecompilerFailure>()),
      );
      expect(stages, isEmpty);
    });

    test('refuses a job count outside 1 to 8 before verifying', () async {
      for (final jobs in [0, maxPrecompilerJobs + 1]) {
        final outOfRange = PrecompilerRequest(
          host: request.host,
          repository: request.repository,
          source: request.source,
          depotTools: request.depotTools,
          work: request.work,
          output: request.output,
          manifest: request.manifest,
          python: request.python,
          jobs: jobs,
        );
        await expectLater(
          buildPrecompiler(outOfRange, run: fakeTools),
          throwsA(isA<PrecompilerFailure>()),
        );
      }
      expect(stages, isEmpty);
    });
  });

  group('native stable sort', () {
    final compiler = _cCompiler();
    final skip = compiler == null ? 'needs cc, gcc or clang' : false;
    late _SortLibrary library;

    setUp(() async {
      library = await _SortLibrary.compile(compiler!, root);
      addTearDown(library.close);
    });

    test('compares only elements of the original array', () {
      const count = 33;
      final values = library.allocate(count * sizeOf<Int32>()).cast<Int32>();
      for (var index = 0; index < count; index++) {
        values[index] = count - 1 - index;
      }
      final first = values.address;
      final end = first + count * sizeOf<Int32>();
      final outside = <int>[];
      library.sort(values.cast(), count, sizeOf<Int32>(), (left, right) {
        for (final address in [left.address, right.address]) {
          if (address < first || address >= end) outside.add(address);
        }
        return left.cast<Int32>().value.compareTo(right.cast<Int32>().value);
      });
      expect(
        outside,
        isEmpty,
        reason: 'qsort compared temporary-buffer addresses',
      );
      expect(
        [for (var i = 0; i < count; i++) values[i]],
        [for (var i = 0; i < count; i++) i],
      );
    }, skip: skip);

    test('keeps equal keys in their original order', () {
      final random = Random(2105);
      for (final length in [0, 1, 2, 3, 31, 32, 33, 129, 1000]) {
        final pairs = [
          for (var sequence = 0; sequence < length; sequence++)
            (key: random.nextInt(11) - 5, sequence: sequence),
        ];
        final array = library
            .allocate(length * 2 * sizeOf<Int32>())
            .cast<Int32>();
        for (final (index, pair) in pairs.indexed) {
          array[2 * index] = pair.key;
          array[2 * index + 1] = pair.sequence;
        }
        library.sort(array.cast(), length, 2 * sizeOf<Int32>(), (left, right) {
          return left.cast<Int32>().value.compareTo(right.cast<Int32>().value);
        });
        final expected = [...pairs]
          ..sort(
            (left, right) => left.key != right.key
                ? left.key.compareTo(right.key)
                : left.sequence.compareTo(right.sequence),
          );
        expect(
          [
            for (var index = 0; index < length; index++)
              (key: array[2 * index], sequence: array[2 * index + 1]),
          ],
          expected,
          reason: 'length $length',
        );
      }
    }, skip: skip);
  });
}

/// The first C compiler on `PATH`, or null when there is none.
String? _cCompiler() {
  for (final name in ['cc', 'gcc', 'clang']) {
    try {
      if (Process.runSync(name, ['--version']).exitCode == 0) return name;
    } on ProcessException {
      continue;
    }
  }
  return null;
}

typedef _Compare = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _SortNative =
    Void Function(Pointer<Void>, Size, Size, Pointer<NativeFunction<_Compare>>);
typedef _Sort =
    void Function(Pointer<Void>, int, int, Pointer<NativeFunction<_Compare>>);

/// `release/native_stable_sort.c` compiled as `ctr_test_sort`, with an
/// allocator for its test arrays; [close] frees the arrays and the library.
final class _SortLibrary {
  final DynamicLibrary _library;
  final _Sort _sort;
  final Pointer<Void> Function(int) _allocate;
  final void Function(Pointer<Void>) _free;
  final _allocations = <Pointer<Void>>[];

  _SortLibrary(this._library)
    : _sort = _library.lookupFunction<_SortNative, _Sort>('ctr_test_sort'),
      _allocate = _library
          .lookupFunction<
            Pointer<Void> Function(Size),
            Pointer<Void> Function(int)
          >('test_allocate'),
      _free = _library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('test_free');

  static Future<_SortLibrary> compile(String compiler, Directory work) async {
    final repository = p.normalize(p.join(Directory.current.path, '..', '..'));
    final allocator = File(p.join(work.path, 'allocator.c'))
      ..writeAsStringSync(
        '#include <stdlib.h>\n'
        'void *test_allocate(size_t size) { return malloc(size ? size : 1); }\n'
        'void test_free(void *pointer) { free(pointer); }\n',
      );
    final library = p.join(work.path, 'sort${_sharedLibrarySuffix()}');
    final result = await Process.run(compiler, [
      '-shared',
      if (!Platform.isWindows) '-fPIC',
      '-O2',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-Dqsort=ctr_test_sort',
      p.join(repository, 'release', 'native_stable_sort.c'),
      allocator.path,
      '-o',
      library,
    ]);
    if (result.exitCode != 0) {
      throw StateError('compiling the stable sort failed: ${result.stderr}');
    }
    return _SortLibrary(DynamicLibrary.open(library));
  }

  Pointer<Void> allocate(int size) {
    final pointer = _allocate(size);
    _allocations.add(pointer);
    return pointer;
  }

  void sort(
    Pointer<Void> base,
    int count,
    int size,
    int Function(Pointer<Void>, Pointer<Void>) compare,
  ) {
    final callback = NativeCallable<_Compare>.isolateLocal(
      compare,
      exceptionalReturn: 0,
    );
    try {
      _sort(base, count, size, callback.nativeFunction);
    } finally {
      callback.close();
    }
  }

  void close() {
    _allocations.forEach(_free);
    _library.close();
  }
}

String _sharedLibrarySuffix() => switch (Platform.operatingSystem) {
  'windows' => '.dll',
  'macos' => '.dylib',
  _ => '.so',
};
