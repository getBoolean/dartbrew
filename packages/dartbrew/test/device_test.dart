import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartbrew/src/commands/run.dart';
import 'package:dartbrew/src/device/azahar_device.dart';
import 'package:dartbrew/src/device/console_device.dart';
import 'package:dartbrew/src/device/device.dart';
import 'package:dartbrew/src/device/device_choice.dart';
import 'package:dartbrew/src/device/run_identity.dart';
import 'package:dartbrew/src/device/stream.dart';
import 'package:dartbrew/src/device/verdict.dart';
import 'package:dartbrew/src/targets/ctr/netloader.dart';
import 'package:dartbrew/src/targets/ctr/pipeline.dart';
import 'package:test/test.dart';

const _identity = RunIdentity(
  schema: 2,
  runId: '0123456789abcdef0123456789abcdef',
  fixture: 'hello',
  mode: BuildMode.jit,
  compatibility: 'ctr-jit-1',
  artifactSha256: 'a',
  buildId: 'b',
  environment: RunEnvironment.hardware,
);

String _record(Map<String, Object?> fields) =>
    'CTR_RUNTIME ${jsonEncode({...fields, 'run_id': _identity.runId})}\n';

/// The records of a passing run of [_identity].
String _passingRun() => [
  _record({
    'event': 'begin',
    'schema': 2,
    'fixture': 'hello',
    'mode': 'jit',
    'compatibility': 'ctr-jit-1',
    'artifact_sha256': 'a',
    'build_id': 'b',
    'environment': 'hardware',
  }),
  _record({'event': 'output', 'text': 'hello'}),
  _record({'event': 'assert', 'name': 'cleanup', 'status': 'pass'}),
  _record({'event': 'terminal', 'outcome': 'pass', 'assertions': 1}),
].join();

final class _FakeDevice implements RunDevice {
  final bool Function(InternetAddress address) accepts;
  final Future<void> Function(int hostPort) onLaunch;

  _FakeDevice({required this.accepts, required this.onLaunch});

  @override
  RunEnvironment get environment => RunEnvironment.hardware;

  @override
  bool acceptsPeer(InternetAddress address) => accepts(address);

  @override
  Future<void> launch(File app, RunIdentity identity, int hostPort) =>
      onLaunch(hostPort);

  @override
  Future<void> dispose() async {}
}

/// Whether the host closes [socket] within [within].
Future<bool> _closedByHost(Socket socket, Duration within) => socket
    .drain<void>()
    .then((_) => true, onError: (Object _) => true)
    .timeout(within, onTimeout: () => false);

DeviceRunSettings _settings(DeviceChoice device) => DeviceRunSettings(
  mode: BuildMode.jit,
  device: device,
  wait: Duration.zero,
  timeout: null,
  hostPort: defaultHostPort,
  project: '.',
  offline: false,
  sdkPath: '.',
);

void main() {
  group('host listener', () {
    test('closes a connection from a peer the device rejects and streams '
        'the expected peer instead', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      var peers = 0;
      bool? foreignClosed;
      final device = _FakeDevice(
        // The first peer stands in for a foreign host on the network.
        accepts: (_) => peers++ > 0,
        onLaunch: (port) async {
          final foreign = await Socket.connect(
            InternetAddress.loopbackIPv4,
            port,
          );
          foreignClosed = await _closedByHost(
            foreign,
            const Duration(seconds: 2),
          );
          foreign.destroy();
          final app = await Socket.connect(InternetAddress.loopbackIPv4, port);
          app.write(_passingRun());
          try {
            await app.flush();
            await app.close();
          } on SocketException {
            app.destroy();
          }
        },
      );

      final result = await runOnDevice(
        device: device,
        app: File('unused.3dsx'),
        identity: _identity,
        listener: listener,
        deadlines: const RunDeadlines(
          connect: Duration(seconds: 5),
          idle: Duration(seconds: 5),
        ),
      );

      expect(foreignClosed, isTrue);
      expect(result.verdict.outcome, Outcome.pass);
      expect(result.verdict.output, ['hello']);
    });

    test(
      'forwards input to the app and ends it by closing the host side',
      () async {
        final listener = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(listener.close);
        final received = <int>[];
        final device = _FakeDevice(
          accepts: (_) => true,
          onLaunch: (port) async {
            final app = await Socket.connect(
              InternetAddress.loopbackIPv4,
              port,
            );
            // The app reads stdin to its end, then reports and closes.
            app.listen(
              received.addAll,
              onDone: () async {
                app.write(_passingRun());
                await app.flush();
                await app.close();
              },
            );
          },
        );

        final result = await runOnDevice(
          device: device,
          app: File('unused.3dsx'),
          identity: _identity,
          listener: listener,
          input: () => Stream.fromIterable([
            utf8.encode('line one\n'),
            utf8.encode('line two\n'),
          ]),
          deadlines: const RunDeadlines(
            connect: Duration(seconds: 5),
            idle: Duration(seconds: 5),
          ),
        );

        expect(utf8.decode(received), 'line one\nline two\n');
        expect(result.verdict.outcome, Outcome.pass);
      },
    );

    test('stops reading input that never ends when the run ends', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final input = StreamController<List<int>>();
      final device = _FakeDevice(
        accepts: (_) => true,
        onLaunch: (port) async {
          final app = await Socket.connect(InternetAddress.loopbackIPv4, port);
          app.listen((_) {}, onError: (Object _) {});
          app.write(_passingRun());
          await app.flush();
          await app.close();
        },
      );

      final result = await runOnDevice(
        device: device,
        app: File('unused.3dsx'),
        identity: _identity,
        listener: listener,
        input: () => input.stream,
        deadlines: const RunDeadlines(
          connect: Duration(seconds: 5),
          idle: Duration(seconds: 5),
        ),
      );

      expect(result.verdict.outcome, Outcome.pass);
      expect(input.hasListener, isFalse);
    });

    test('a console accepts only its own address', () {
      final device = ConsoleDevice(
        NetloaderClient(),
        InternetAddress('192.168.1.20'),
      );
      expect(device.acceptsPeer(InternetAddress('192.168.1.20')), isTrue);
      expect(device.acceptsPeer(InternetAddress('192.168.1.21')), isFalse);
      expect(device.acceptsPeer(InternetAddress.loopbackIPv4), isFalse);
    });

    test('Azahar accepts only loopback', () {
      final device = AzaharDevice(executable: 'azahar', sdmc: 'sdmc');
      expect(device.acceptsPeer(InternetAddress.loopbackIPv4), isTrue);
      expect(device.acceptsPeer(InternetAddress('192.168.1.20')), isFalse);
    });

    test('binds loopback for Azahar runs and every interface for consoles, '
        'unless an address is given', () {
      final runner = DeviceRunner();
      expect(
        runner.listenAddressFor(_settings(const Azahar(null))),
        InternetAddress.loopbackIPv4,
      );
      expect(
        runner.listenAddressFor(_settings(const DiscoverConsole())),
        InternetAddress.anyIPv4,
      );
      expect(
        runner.listenAddressFor(
          _settings(ConsoleAt(InternetAddress('192.168.1.20'))),
        ),
        InternetAddress.anyIPv4,
      );
      final given = InternetAddress('127.0.0.5');
      expect(
        DeviceRunner(
          listenAddress: given,
        ).listenAddressFor(_settings(const Azahar(null))),
        given,
      );
    });
  });

  group('line length cap', () {
    const cap = RuntimeLineParser.maxLineLength;

    test('a record line of exactly the cap is parsed', () {
      const head = '${RuntimeLineParser.prefix}{"event":"output","text":"';
      const tail = '"}';
      final line = '$head${'x' * (cap - head.length - tail.length)}$tail';
      expect(utf8.encode(line), hasLength(cap));
      final lines = RuntimeLineParser().feed(utf8.encode('$line\n'));
      expect(lines, [isA<RuntimeRecord>()]);
    });

    test('a record line over the cap is one malformed record and its rest '
        'is skipped up to the next line', () {
      final parser = RuntimeLineParser();
      final lines = [
        ...parser.feed(utf8.encode('${RuntimeLineParser.prefix}{"text":"')),
        for (var i = 0; i < 5; i++) ...parser.feed(List.filled(cap ~/ 2, 0x78)),
        ...parser.feed(utf8.encode('"}\n${_record({'event': 'output'})}')),
        ...parser.close(),
      ];
      expect(lines, [isA<MalformedRecord>(), isA<RuntimeRecord>()]);
    });

    test('an unprefixed line over the cap is ignored', () {
      final parser = RuntimeLineParser();
      final lines = [
        ...parser.feed(List.filled(cap + 1, 0x78)),
        ...parser.feed(utf8.encode('\n${_record({'event': 'output'})}')),
      ];
      expect(lines, [isA<RuntimeRecord>()]);
    });

    test('an unfinished line over the cap adds nothing on close', () {
      final parser = RuntimeLineParser();
      final lines = [
        ...parser.feed(utf8.encode(RuntimeLineParser.prefix)),
        ...parser.feed(List.filled(cap, 0x78)),
        ...parser.close(),
      ];
      expect(lines, [isA<MalformedRecord>()]);
    });
  });
}
