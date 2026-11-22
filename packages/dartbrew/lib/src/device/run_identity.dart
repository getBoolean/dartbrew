import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../targets/ctr/pipeline.dart' show BuildMode, CtrBuild;

/// Where a run executes, as the launcher reports it in `environment`.
enum RunEnvironment {
  /// A console.
  hardware,

  /// The Azahar emulator.
  azahar,

  /// The CTR runtime's host VM driver (`make -C runtime/ctr host-vm`).
  host,
}

/// A new random 32-hex-digit run ID.
String newRunId([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(
    16,
    (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// The identity of one run: what the host tells the launcher it started, and
/// what the launcher's `begin` record must echo back.
///
/// It owns every encoding of the identity: `run.json`, the
/// `ctr-runtime-run.cfg` text, the launcher's argv tokens and the `begin`
/// record match (see the "Launcher contract" runbook section).
final class RunIdentity {
  /// The launcher contract schema.
  final int schema;
  final String runId;
  final String fixture;
  final BuildMode mode;
  final String compatibility;
  final String artifactSha256;
  final String buildId;
  final RunEnvironment environment;

  const RunIdentity({
    required this.schema,
    required this.runId,
    required this.fixture,
    required this.mode,
    required this.compatibility,
    required this.artifactSha256,
    required this.buildId,
    required this.environment,
  });

  /// The identity of a new run of [build] in [environment], with [runId] or
  /// else a new random one.
  RunIdentity.ofBuild(
    CtrBuild build, {
    required this.schema,
    required this.environment,
    String? runId,
  }) : runId = runId ?? newRunId(),
       fixture = build.fixture,
       mode = build.mode,
       compatibility = build.compatibility,
       artifactSha256 = build.artifactSha256,
       buildId = build.buildId;

  /// The fields in the order the launcher reads `ctr-runtime-run.cfg`, with
  /// the values `run.json` and the `begin` record carry.
  Map<String, Object> get _fields => {
    'schema': schema,
    'run_id': runId,
    'fixture': fixture,
    'mode': mode.name,
    'compatibility': compatibility,
    'artifact_sha256': artifactSha256,
    'build_id': buildId,
    'environment': environment.name,
  };

  /// Writes this identity as `run.json` in [directory].
  void writeRunRecord(String directory) => File(
    p.join(directory, 'run.json'),
  ).writeAsStringSync('${jsonEncode(_fields)}\n');

  /// The `ctr-runtime-run.cfg` text: one `key=value` line per field, then,
  /// when [host] is given, the `host=` line naming the listener the launcher
  /// connects to.
  String runConfig({({InternetAddress address, int port})? host}) => [
    for (final MapEntry(:key, :value) in _fields.entries) '$key=$value\n',
    if (host != null) 'host=${host.address.address}:${host.port}\n',
  ].join();

  /// The launcher's argv tokens for this identity and the host listener on
  /// [hostPort].
  List<String> launcherArguments(int hostPort) {
    final fields = _fields;
    return [
      for (final key in const [
        'schema',
        'run_id',
        'artifact_sha256',
        'environment',
        'fixture',
        'mode',
        'compatibility',
        'build_id',
      ])
        '--ctr-run=$key=${fields[key]}',
      '--ctr-host-port=$hostPort',
    ];
  }

  /// Whether the `begin` record [record] carries exactly this identity, with
  /// every field equal in value and JSON type.
  bool matchesBegin(Map<String, Object?> record) =>
      _fields.entries.every((field) => record[field.key] == field.value);
}
