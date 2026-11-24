import 'dart:io';
import 'dart:typed_data';

import 'package:dartbrew/src/device/run_identity.dart';
import 'package:dartbrew/src/targets/ctr/pipeline.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _runId = '0123456789abcdef0123456789abcdef';

final _build = CtrBuild(
  application: File('dartbrew-hello-jit.3dsx'),
  artifact: Uint8List(0),
  mode: BuildMode.jit,
  fixture: 'hello',
  compatibility: 'ctr-jit-1',
  buildId: 'b' * 64,
  artifactSha256: 'a' * 64,
  payloadSha256: 'p' * 64,
  elfSha256: 'e' * 64,
  sdkManifestSha256: 's' * 64,
  sdkHead: 'head',
);

final _a = 'a' * 64;
final _b = 'b' * 64;

void main() {
  group('golden bytes', () {
    test('run.json of a schema-2 console run', () {
      final directory = Directory.systemTemp.createTempSync('run-identity-');
      addTearDown(() => directory.deleteSync(recursive: true));
      RunIdentity.ofBuild(
        _build,
        schema: 2,
        environment: RunEnvironment.hardware,
        runId: _runId,
      ).writeRunRecord(directory.path);
      expect(
        File(p.join(directory.path, 'run.json')).readAsStringSync(),
        '{"schema":2,"run_id":"$_runId","fixture":"hello","mode":"jit",'
        '"compatibility":"ctr-jit-1","artifact_sha256":"$_a",'
        '"build_id":"$_b","environment":"hardware"}\n',
      );
    });

    test('the schema-1 config file of a packaged build', () {
      expect(
        RunIdentity.ofBuild(
          _build,
          schema: 1,
          environment: RunEnvironment.hardware,
          runId: _runId,
        ).runConfig(),
        'schema=1\n'
        'run_id=$_runId\n'
        'fixture=hello\n'
        'mode=jit\n'
        'compatibility=ctr-jit-1\n'
        'artifact_sha256=$_a\n'
        'build_id=$_b\n'
        'environment=hardware\n',
      );
    });

    test('the Azahar config file names the loopback host port', () {
      expect(
        RunIdentity.ofBuild(
          _build,
          schema: 2,
          environment: RunEnvironment.azahar,
          runId: _runId,
        ).runConfig(host: (address: InternetAddress.loopbackIPv4, port: 17491)),
        'schema=2\n'
        'run_id=$_runId\n'
        'fixture=hello\n'
        'mode=jit\n'
        'compatibility=ctr-jit-1\n'
        'artifact_sha256=$_a\n'
        'build_id=$_b\n'
        'environment=azahar\n'
        'host=127.0.0.1:17491\n',
      );
    });

    test('the launcher argv of a console run', () {
      expect(
        RunIdentity.ofBuild(
          _build,
          schema: 2,
          environment: RunEnvironment.hardware,
          runId: _runId,
        ).launcherArguments(17491),
        [
          '--ctr-run=schema=2',
          '--ctr-run=run_id=$_runId',
          '--ctr-run=artifact_sha256=$_a',
          '--ctr-run=environment=hardware',
          '--ctr-run=fixture=hello',
          '--ctr-run=mode=jit',
          '--ctr-run=compatibility=ctr-jit-1',
          '--ctr-run=build_id=$_b',
          '--ctr-host-port=17491',
        ],
      );
    });
  });

  group('begin record', () {
    final identity = RunIdentity.ofBuild(
      _build,
      schema: 2,
      environment: RunEnvironment.azahar,
      runId: _runId,
    );
    final begin = <String, Object?>{
      'event': 'begin',
      'schema': 2,
      'run_id': _runId,
      'fixture': 'hello',
      'mode': 'jit',
      'compatibility': 'ctr-jit-1',
      'artifact_sha256': _a,
      'build_id': _b,
      'environment': 'azahar',
    };

    test('matches when it echoes every field', () {
      expect(identity.matchesBegin(begin), isTrue);
    });

    test('does not match a different value or JSON type of any field', () {
      for (final key in begin.keys.where((key) => key != 'event')) {
        expect(
          identity.matchesBegin({...begin, key: 'other'}),
          isFalse,
          reason: key,
        );
        expect(
          identity.matchesBegin({...begin}..remove(key)),
          isFalse,
          reason: key,
        );
      }
      expect(identity.matchesBegin({...begin, 'schema': '2'}), isFalse);
    });
  });

  test('a new run of a build gets a fresh 32-hex-digit run ID', () {
    RunIdentity run() => RunIdentity.ofBuild(
      _build,
      schema: 2,
      environment: RunEnvironment.hardware,
    );
    final first = run().runId;
    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(run().runId, isNot(first));
  });
}
