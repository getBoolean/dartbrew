import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartbrew/sdk_manifest.dart';
import 'package:dartbrew/src/sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const payload = 'sealed tool bytes';
final payloadDigest = sha256.convert(utf8.encode(payload)).toString();

/// A temporary SDK for tests. Deleted when the current test ends.
class FakeSdk {
  final Directory root;
  FakeSdk._(this.root);

  /// Every argument list the stub for [tool] was started with, in order.
  List<List<String>> calls(String tool) {
    final log = File(p.join(root.path, 'calls', '$tool.json'));
    if (!log.existsSync()) return [];
    return [
      for (final call in jsonDecode(log.readAsStringSync()) as List<Object?>)
        (call as List<Object?>).cast<String>(),
    ];
  }

  /// Rewrites `sdk.json` with [edit] applied to its decoded JSON object.
  void editManifest(void Function(Map<String, Object?> json) edit) {
    final file = File(p.join(root.path, 'sdk.json'));
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    edit(json);
    file.writeAsStringSync(jsonEncode(json));
  }
}

/// The runtime every fake SDK's manifest names. Its files are sealed only
/// when a test adds them as assets, as [ctrBuildSdk] does.
final fakeRuntime = SdkRuntime(
  sdkHead: 'head',
  platform: 'runtime/platform.dill',
  aot: RuntimeMode(
    compatibility: 'a' * 64,
    objects: ['runtime/aot.o'],
    archive: 'runtime/aot.a',
    ioArchive: 'runtime/aot-io.a',
  ),
  jit: RuntimeMode(
    compatibility: 'b' * 64,
    objects: ['runtime/jit.o'],
    archive: 'runtime/jit.a',
    ioArchive: 'runtime/jit-io.a',
  ),
  link: LinkPlan(
    layout: 'runtime/layout.ld',
    math: 'runtime/libm.a',
    startup: ['runtime/crt0.o'],
    libraries: ['runtime/libctru.a'],
    grouped: ['runtime/libc.a'],
    end: ['runtime/crtend.o'],
  ),
);

/// Writes a minimal SDK with one sealed asset, `bin/tool`, whose manifest
/// names [fakeRuntime] and maps each [SdkTool] to `tools/<key>.dart`.
///
/// Each entry in [tools] seals a stub executable at that path. A stub
/// records its arguments (see [FakeSdk.calls]), writes `<name> stdout` and
/// `<name> stderr`, and exits with the given code. Start stubs with
/// [startStub].
///
/// Each entry in [assets] adds a sealed file with the given contents.
///
/// [files] replaces the generated `files` map as-is.
FakeSdk fakeSdk({
  String? host,
  Map<String, String>? files,
  Map<String, int> tools = const {},
  Map<String, String> assets = const {},
}) {
  final root = Directory.systemTemp.createTempSync('dartbrew-sdk-test-');
  addTearDown(() => root.deleteSync(recursive: true));
  final sealed = <String, String>{};
  void seal(String relative, String contents) {
    final file = File(p.joinAll([root.path, ...relative.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    sealed[relative] = sha256.convert(utf8.encode(contents)).toString();
  }

  seal('bin/tool', payload);
  assets.forEach(seal);
  final calls = Directory(p.join(root.path, 'calls'))..createSync();
  for (final MapEntry(key: name, value: code) in tools.entries) {
    final log = p.join(calls.path, '$name.json');
    seal('tools/$name.dart', '''
import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  final log = File(${jsonEncode(log)});
  final calls = log.existsSync() ? jsonDecode(log.readAsStringSync()) as List : [];
  log.writeAsStringSync(jsonEncode([...calls, arguments]));
  stdout.writeln('$name stdout');
  stderr.writeln('$name stderr');
  exitCode = $code;
}
''');
  }
  final manifest = SdkManifest(
    host: host ?? currentHost(),
    tools: {for (final tool in SdkTool.values) tool: 'tools/${tool.key}.dart'},
    runtime: fakeRuntime,
    files: files ?? sealed,
  );
  File(
    p.join(root.path, 'sdk.json'),
  ).writeAsStringSync(jsonEncode(manifest.toJson()));
  return FakeSdk._(root);
}

/// A process starter that runs fake SDK stubs with the current Dart VM.
Future<Process> startStub(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  ProcessStartMode mode = ProcessStartMode.normal,
}) => Process.start(
  Platform.resolvedExecutable,
  [executable, ...arguments],
  workingDirectory: workingDirectory,
  environment: environment,
  mode: mode,
);
