import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dartbrew/sdk_manifest.dart';
import 'package:path/path.dart' as p;

import 'host.dart';
import 'host_binary_audit.dart';
import 'notices.dart';
import 'stage_runner.dart';

typedef _Json = Map<String, Object?>;

Future<_Json> _read(File file) async =>
    jsonDecode(await file.readAsString()) as _Json;
Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).single).toString();
const _pretty = JsonEncoder.withIndent('  ');
Future<void> _save(File file, Object data) =>
    file.writeAsString('${_pretty.convert(data)}\n');

/// Rejects components built for different hosts, source trees or snapshot formats.
void checkComponentIdentity(
  Host host,
  Map<String, Object?> compiler,
  Map<String, Object?> runtime,
) {
  final source = compiler['source']! as _Json;
  final identity = compiler['generated']! as _Json;
  if (compiler['host'] != host.id ||
      (runtime.containsKey('host') && runtime['host'] != host.id)) {
    throw FormatException('Producer or component host differs from ${host.id}');
  }
  final head = runtime['sdk_head'];
  if (head is! String ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(head) ||
      head != source['head'] ||
      identity['git_short_hash'] != head.substring(0, 10)) {
    throw const FormatException('Component sdk_head mismatch');
  }
  final hash = runtime['snapshot_hash'];
  if (hash is! String ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(hash) ||
      hash != identity['snapshot_hash']) {
    throw const FormatException('Component snapshot_hash mismatch');
  }
}

/// Compares AOT assembly with the Linux producer's reference digest. Only the
/// DWARF producer string may identify a different host.
Map<String, String> checkCodegen(
  Uint8List bytes,
  String expected,
  Host host,
  String version,
) {
  final actual = sha256.convert(bytes).toString();
  if (actual == expected) {
    return {'match': 'exact', 'sha256': actual, 'comparable_sha256': actual};
  }
  const prefix = 'Dart SDK version: ';
  final suffix = ' on "${host.os.name}_arm"';
  if (!version.startsWith(prefix) ||
      !version.endsWith(suffix) ||
      version.contains(RegExp(r'[\r\n]'))) {
    throw const FormatException('Invalid host/target in precompiler version');
  }
  final producer = 'Dart ${version.substring(prefix.length)}\n';
  final banner = '.string ${jsonEncode(producer)}\n';
  final linuxProducer =
      'Dart ${version.substring(prefix.length, version.length - suffix.length)} on "linux_arm"\n';
  final linuxBanner = '.string ${jsonEncode(linuxProducer)}\n';
  const marker = '.section .debug_info,""\n';
  final sections = utf8.decode(bytes).split(marker);
  if (sections.length != 2 || sections.last.split(banner).length != 2) {
    throw const FormatException('Missing unique DWARF producer banner');
  }
  final normalized =
      sections.first + marker + sections.last.replaceFirst(banner, linuxBanner);
  final normalizedHash = sha256.convert(utf8.encode(normalized)).toString();
  if (normalizedHash != expected) {
    throw const FormatException(
      'Generated assembly differs beyond DWARF producer hostname',
    );
  }
  return {
    'match': 'dwarf-producer-host-only',
    'sha256': actual,
    'comparable_sha256': normalizedHash,
  };
}

bool _safeName(String name) =>
    SdkManifest.isAssetPath(name) &&
    !name.contains(':') &&
    !name.split('/').contains('.');
File _member(Directory directory, String relative) {
  if (!_safeName(relative)) {
    throw FormatException('Invalid component member $relative');
  }
  return File(p.joinAll([directory.path, ...relative.split('/')]));
}

Future<File> _checked(Directory component, String name, String hash) async {
  final file = _member(component, name);
  if (!p.isWithin(
        await component.resolveSymbolicLinks(),
        await file.resolveSymbolicLinks(),
      ) ||
      await _digest(file) != hash) {
    throw FormatException('Component path or hash mismatch for $name');
  }
  return file;
}

Future<String> _capture(String exe, List<String> args, {String? cwd}) async {
  final result = await Process.run(exe, args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw ProcessException(exe, args, '${result.stderr}', result.exitCode);
  }
  return (result.stdout as String) + (result.stderr as String);
}

/// Rejects compiled target objects and archives even when their extensions
/// have been changed. The native runtime component contains source and kernel data.
Future<void> checkSourceAsset(File file) async {
  final ext = p.extension(file.path).toLowerCase();
  if ({'.a', '.o', '.ld', '.so', '.3dsx'}.contains(ext)) {
    throw FormatException('Forbidden target build product: ${file.path}');
  }
  final stream = await file.open();
  try {
    final bytes = await stream.read(20);
    if ((bytes.length >= 8 &&
            (ascii.decode(bytes.sublist(0, 8), allowInvalid: true) ==
                    '!<arch>\n' ||
                ascii.decode(bytes.sublist(0, 8), allowInvalid: true) ==
                    '!<thin>\n')) ||
        (bytes.length >= 20 &&
            ByteData.sublistView(bytes).getUint32(0) == 0x7f454c46 &&
            ByteData.sublistView(
                  bytes,
                ).getUint16(18, bytes[5] == 1 ? Endian.little : Endian.big) ==
                40)) {
      throw FormatException('Found compiled target binary: ${file.path}');
    }
  } finally {
    await stream.close();
  }
}

Future<void> _copy(File file, File destination) async {
  await destination.parent.create(recursive: true);
  await destination.create(exclusive: true);
  await file.copy(destination.path);
}

Future<void> _archive(Directory sdk, File output) async {
  final zip = ZipFileEncoder()..create(output.path);
  try {
    await zip.addDirectory(sdk, includeDirName: true, followLinks: false);
  } finally {
    await zip.close();
  }
}

/// Creates one SDK archive and records checks against its extracted contents.
/// A failed run retains the stage logs and artifacts under [output].
Future<Map<String, Object?>> assembleSdk({
  required Host host,
  required String version,
  required Directory repository,
  required Directory precompiler,
  required Directory runtime,
  required Directory output,
}) async {
  final precompilerRecord = File(
    p.join(precompiler.path, 'native-precompiler.json'),
  );
  final runtimeRecord = File(p.join(runtime.path, 'runtime.json'));
  final compiler = await _read(precompilerRecord);
  final target = await _read(runtimeRecord);
  checkComponentIdentity(host, compiler, target);
  if (await FileSystemEntity.type(output.path) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException(
      'Output already exists; choose a fresh directory',
      output.path,
    );
  }
  await output.create(recursive: true);
  await File(p.join(output.path, 'assembly.lock')).create(exclusive: true);
  final stages = StageRunner(output);
  final sdkName = 'dartbrew-$version-${host.id}';
  final sdk = Directory(p.join(output.path, sdkName));
  await sdk.create();
  final suffix = host.executableSuffix;
  final tools = <String, String>{'dart': 'host-dart/bin/dart$suffix'};
  final executables = <String>{'dartbrew$suffix'};
  final auditFiles = <String>{'dartbrew$suffix'};
  for (final (role, field, basename) in [
    ('snapshot', 'executable', 'gen_snapshot'),
    ('kernel', 'kernel_compiler', 'ctr-kernel'),
  ]) {
    final record = compiler[field]! as _Json;
    final source = await _checked(
      precompiler,
      record['path']! as String,
      record['sha256']! as String,
    );
    final relative = 'bin/$basename$suffix';
    await _copy(source, _member(sdk, relative));
    tools[role] = relative;
    executables.add(relative);
    auditFiles.add(relative);
  }

  final hostDart = Directory(p.join(precompiler.path, 'host-dart'));
  final hostFiles = compiler['host_dart']! as _Json;
  for (final MapEntry(key: name, value: object) in hostFiles.entries) {
    final stem = p.posix.basenameWithoutExtension(name);
    if (name.startsWith('bin/') &&
        (name.endsWith('.sym') ||
            RegExp('_(asan|msan|tsan)\$').hasMatch(stem))) {
      continue;
    }
    final record = object! as _Json;
    final source = await _checked(hostDart, name, record['sha256']! as String);
    final relative = 'host-dart/$name';
    await _copy(source, _member(sdk, relative));
    if (record['executable'] == true) executables.add(relative);
    if (name.startsWith('bin/') &&
        (name.endsWith('.exe') ||
            {
              'dart',
              'dartvm',
              'dartaotruntime',
              'dartcliruntime',
              'gen_snapshot',
            }.contains(p.posix.basename(name)))) {
      auditFiles.add(relative);
    }
  }
  // Copying through a producer may lose execute bits. Set them before using
  // the staged tools, and check them again after extraction.
  if (!Platform.isWindows) {
    for (final relative in executables.where(
      (name) => name != 'dartbrew$suffix',
    )) {
      final path = _member(sdk, relative).path;
      if (File(path).statSync().mode & 0x49 == 0) {
        await _capture('chmod', ['755', path]);
      }
    }
  }
  final targetFiles = (target['files']! as _Json).cast<String, String>();
  final sourceRoot = target['native_src']! as String;
  final plan = target['compile_plan']! as String;
  final platform = target['platform']! as String;
  if (!targetFiles.containsKey(platform) ||
      !targetFiles.containsKey(plan) ||
      !targetFiles.keys.any((n) => n.startsWith('$sourceRoot/'))) {
    throw const FormatException(
      'Missing sealed runtime sources, compile plan or platform',
    );
  }
  for (final MapEntry(key: name, value: hash) in targetFiles.entries) {
    if (name != plan &&
        name != platform &&
        !name.startsWith('$sourceRoot/') &&
        !name.startsWith('source-notices/')) {
      throw FormatException('Unexpected runtime bundle member $name');
    }
    final source = await _checked(runtime, name, hash);
    await checkSourceAsset(source);
    final destination = name.startsWith('source-notices/')
        ? 'notices/$name'
        : name;
    await _copy(source, _member(sdk, destination));
  }
  final snapshot = _member(sdk, tools['snapshot']!).path;
  final probe = await _read(File(p.join(runtime.path, 'probe.json')));
  final kernel = await _checked(
    runtime,
    probe['kernel']! as String,
    probe['kernel_sha256']! as String,
  );
  final assembly = File(p.join(output.path, 'cross-host-probe.S'));
  await stages(snapshot, [
    '--snapshot_kind=app-aot-assembly',
    '--assembly=${assembly.path}',
    kernel.path,
  ], 'codegen');
  final generation = checkCodegen(
    await assembly.readAsBytes(),
    probe['assembly_sha256']! as String,
    host,
    (await _capture(snapshot, ['--version'])).trim(),
  );

  final dart = _member(sdk, tools['dart']!).path;
  final package = p.join(repository.path, 'packages', 'dartbrew');
  final cli = _member(sdk, 'dartbrew$suffix');
  for (final (stage, args) in [
    ('pub', ['pub', 'get', '--enforce-lockfile']),
    ('analyze', ['analyze']),
    ('test', ['test', '-r', 'expanded']),
    (
      'cli',
      [
        'compile',
        'exe',
        '-DDARTBREW_VERSION=$version',
        'bin/dartbrew.dart',
        '-o',
        cli.path,
      ],
    ),
  ]) {
    await stages(dart, args, stage, workingDirectory: package);
  }
  final dependencies = await _capture(dart, [
    'pub',
    'deps',
    '--json',
  ], cwd: package);
  await writeNotices(
    repository: repository,
    sdk: sdk,
    pins: await _read(File(p.join(repository.path, 'toolchain/versions.json'))),
    pubGraph: jsonDecode(dependencies) as _Json,
    sourceNotices: targetFiles.keys.where(
      (s) => s.startsWith('source-notices/'),
    ),
  );
  await _copy(
    File(p.join(repository.path, 'docs/user-guide.md')),
    _member(sdk, 'README.md'),
  );
  await _copy(precompilerRecord, _member(sdk, 'provenance/host.json'));
  await _copy(runtimeRecord, _member(sdk, 'provenance/runtime.json'));
  final files = <String, String>{};
  await for (final file in sdk.list(recursive: true, followLinks: false)) {
    if (file is File) {
      final name = p.split(p.relative(file.path, from: sdk.path)).join('/');
      files[name] = await _digest(file);
      if (host.os == HostOs.macos) {
        final input = await file.open();
        try {
          final header = await input.read(4);
          if (header.length == 4 &&
              const {0xfeedfacf, 0xbebafeca, 0xbfbafeca}.contains(
                ByteData.sublistView(header).getUint32(0, Endian.little),
              )) {
            auditFiles.add(name);
          }
        } finally {
          await input.close();
        }
      }
    }
  }
  final manifest = SdkManifest.fromJson({
    'schema': SdkManifest.schema,
    'host': host.id,
    'tools': tools,
    'runtime': target,
    'files': files,
  });
  await _save(_member(sdk, 'sdk.json'), {
    ...manifest.toJson(),
    'version': version,
    'snapshot_hash': target['snapshot_hash'],
  });
  final audit = await auditHostBinaries(
    sdk,
    host,
    auditFiles.map((s) => _member(sdk, s)),
  );
  final archive = File(p.join(output.path, '$sdkName.zip'));
  await _archive(sdk, archive);
  final extraction = p.join(output.path, 'extracted download');
  await extractFileToDisk(archive.path, extraction, verify: true);
  final installed = Directory(p.join(extraction, sdkName));
  if (!Platform.isWindows) {
    for (final relative in executables) {
      if ((await _member(installed, relative).stat()).mode & 0x49 == 0) {
        throw FormatException('Zip lost executable mode for $relative');
      }
    }
  }
  final installedCli = _member(installed, 'dartbrew$suffix').path;
  for (final (stage, args) in [
    ('help', ['--help']),
    ('version', ['--version']),
    ('doctor', ['doctor']),
  ]) {
    await stages(installedCli, args, stage, environment: {'PATH': ''});
  }
  final tests = p.join(repository.path, 'packages/release_tools');
  await stages(
    dart,
    ['pub', 'get', '--enforce-lockfile'],
    'release-tools-pub',
    workingDirectory: tests,
  );
  await stages(
    dart,
    ['test', 'test/native_sdk_integration_test.dart', '-r', 'expanded'],
    'integration',
    workingDirectory: tests,
    environment: {'DARTBREW_NATIVE_SDK': installed.path},
  );
  final receipt = <String, Object?>{
    'host': host.id,
    'sdk_archive': p.basename(archive.path),
    'sdk_sha256': await _digest(archive),
    'sdk_manifest_sha256': await _digest(_member(installed, 'sdk.json')),
    'files': files.length,
    'devkitpro': target['devkitpro'],
    'code_generation': generation,
    'dependency_audit': audit,
    if (host.os == HostOs.macos)
      'minimum_macos': highestMacosVersion(
        audit.values.map(
          (record) =>
              (record as Map<String, Object>)['minimum_macos']! as String,
        ),
      ),
    'native_build_checks':
        'Extracted SDK passed doctor and the native SDK integration suite.',
  };
  await _save(File(p.join(output.path, 'verification.json')), receipt);
  return receipt;
}
