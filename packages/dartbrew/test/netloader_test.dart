import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartbrew/src/errors.dart';
import 'package:dartbrew/src/targets/ctr/netloader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('discovery', () {
    test('finds a console that replies to the reply port', () async {
      final replyPort = await freeUdpPort();
      final console = await FakeConsoleResponder.start(replyPort);
      addTearDown(console.close);

      final found = await loopbackClient(
        port: console.port,
        replyPort: replyPort,
      ).discover(const Duration(milliseconds: 600)).toList();

      expect(found.map((a) => a.address), ['127.0.0.1']);
      expect(console.pings, greaterThan(1), reason: 'broadcast repeats');
      expect(console.senderPorts, isNot(contains(replyPort)));
    });

    test('returns nothing after the wait when no console replies', () async {
      final watch = Stopwatch()..start();
      final found = await loopbackClient(
        port: await freeUdpPort(),
      ).discover(const Duration(milliseconds: 400)).toList();

      expect(found, isEmpty);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(380));
    });

    test('fails naming the reply port when it is already bound', () async {
      final blocker = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        reuseAddress: false,
      );
      addTearDown(blocker.close);

      await expectLater(
        loopbackClient(
          port: await freeUdpPort(),
          replyPort: blocker.port,
        ).discover(const Duration(milliseconds: 300)).toList(),
        throwsA(
          isA<DartbrewException>().having(
            (e) => e.message,
            'message',
            contains('UDP port ${blocker.port}'),
          ),
        ),
      );
    });
  });

  group('upload', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('netloader_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    File app(List<int> bytes) =>
        File(p.join(dir.path, 'hello.3dsx'))..writeAsBytesSync(bytes);

    test('sends the file byte-identical with the given argv', () async {
      final netloader = await FakeNetloader.start();
      addTearDown(netloader.close);
      final bytes = utf8.encode('3DSX${'payload ' * 500}');

      await loopbackClient(port: netloader.port).upload(
        InternetAddress.loopbackIPv4,
        app(bytes),
        arguments: ['--run-id=abc', 'port=4567'],
      );
      final got = await netloader.upload;

      expect(got.name, 'hello.3dsx');
      expect(got.declaredSize, bytes.length);
      expect(got.payload, bytes);
      expect(got.argv, ['sdmc:/3ds/hello.3dsx', '--run-id=abc', 'port=4567']);
      expect(got.closedByHost, isTrue);
    });

    test('splits a 40 KiB file into frames of at most 16 KiB', () async {
      final netloader = await FakeNetloader.start();
      addTearDown(netloader.close);
      final random = Random(1);
      final bytes = Uint8List.fromList([
        for (var i = 0; i < 40 * 1024; i++) random.nextInt(256),
      ]);

      await loopbackClient(
        port: netloader.port,
      ).upload(InternetAddress.loopbackIPv4, app(bytes));
      final got = await netloader.upload;

      expect(got.payload, bytes);
      expect(got.frameLengths, hasLength(3));
      expect(got.frameLengths, everyElement(lessThanOrEqualTo(16 * 1024)));
    });

    test('reports progress after each frame, ending at the total', () async {
      final netloader = await FakeNetloader.start();
      addTearDown(netloader.close);
      final random = Random(2);
      final bytes = Uint8List.fromList([
        for (var i = 0; i < 40 * 1024; i++) random.nextInt(256),
      ]);
      final reports = <(int, int)>[];

      await loopbackClient(port: netloader.port).upload(
        InternetAddress.loopbackIPv4,
        app(bytes),
        onProgress: (sent, total) => reports.add((sent, total)),
      );
      final got = await netloader.upload;
      final total = got.frameLengths.fold<int>(0, (a, b) => a + b);

      expect(reports, hasLength(got.frameLengths.length));
      expect(reports.map((r) => r.$2), everyElement(total));
      expect(reports.last.$1, total);
    });

    for (final (stage, behavior) in [
      ('file', const FakeBehavior(firstAck: -2)),
      ('write', const FakeBehavior(secondAck: -1)),
    ]) {
      test('a negative $stage ack fails naming the code', () async {
        final netloader = await FakeNetloader.start(behavior);
        addTearDown(netloader.close);
        final code = behavior.firstAck != 0
            ? behavior.firstAck
            : behavior.secondAck;

        await expectLater(
          loopbackClient(
            port: netloader.port,
          ).upload(InternetAddress.loopbackIPv4, app([1, 2, 3])),
          throwsA(
            isA<DartbrewException>().having(
              (e) => e.message,
              'message',
              contains('code $code'),
            ),
          ),
        );
      });
    }

    test('the console closing mid-upload is a lost connection', () async {
      final netloader = await FakeNetloader.start(
        const FakeBehavior(closeAfterFrames: 1),
      );
      addTearDown(netloader.close);
      final random = Random(2);
      final bytes = [for (var i = 0; i < 40 * 1024; i++) random.nextInt(256)];

      await expectLater(
        loopbackClient(
          port: netloader.port,
        ).upload(InternetAddress.loopbackIPv4, app(bytes)),
        throwsA(
          isA<DartbrewException>().having(
            (e) => e.message,
            'message',
            contains('Lost the connection'),
          ),
        ),
      );
    });

    test('a console that accepts but never acknowledges is a lost '
        'connection after the ack deadline', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      final held = <Socket>[];
      silent.listen((socket) {
        held.add(socket);
        socket.listen((_) {}, onError: (Object _) {});
      });
      addTearDown(() {
        for (final socket in held) {
          socket.destroy();
        }
      });
      final client = NetloaderClient(
        port: silent.port,
        connectTimeout: const Duration(seconds: 5),
        ackTimeout: const Duration(milliseconds: 200),
      );

      final watch = Stopwatch()..start();
      await expectLater(
        client.upload(InternetAddress.loopbackIPv4, app([1, 2, 3])),
        throwsA(
          isA<DartbrewException>().having(
            (e) => e.message,
            'message',
            contains('Lost the connection'),
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('an unreachable console fails naming the address', () async {
      await expectLater(
        loopbackClient(
          port: await freeTcpPort(),
        ).upload(InternetAddress.loopbackIPv4, app([1])),
        throwsA(
          isA<DartbrewException>().having(
            (e) => e.message,
            'message',
            contains('127.0.0.1'),
          ),
        ),
      );
    });
  });

  test('argv over the limit is rejected before connecting', () {
    expect(
      () => encodeArgv(['x' * maxArgvLength]),
      throwsA(isA<DartbrewException>()),
    );
    expect(encodeArgv(['a', 'bc']), [97, 0, 98, 99, 0]);
  });
}

/// A client aimed at loopback, so tests never broadcast on a real network.
NetloaderClient loopbackClient({required int port, int replyPort = 0}) =>
    NetloaderClient(
      port: port,
      replyPort: replyPort,
      receiveAddress: InternetAddress.loopbackIPv4,
      broadcastAddress: InternetAddress.loopbackIPv4,
      interfaceAddresses: () async => [InternetAddress.loopbackIPv4],
    );

Future<int> freeUdpPort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  socket.close();
  // Sockets close asynchronously; give the port time to be released.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return port;
}

Future<int> freeTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// A console netloader's discovery side: answers `3dsboot` with `boot3ds`
/// sent to [replyPort] on the sender's address, like the real netloader.
final class FakeConsoleResponder {
  final RawDatagramSocket _socket;
  int pings = 0;
  final senderPorts = <int>{};

  FakeConsoleResponder._(this._socket, int replyPort) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = _socket.receive(); d != null; d = _socket.receive()) {
        if (ascii.decode(d.data, allowInvalid: true) != '3dsboot') continue;
        pings++;
        senderPorts.add(d.port);
        _socket.send(ascii.encode('boot3ds'), d.address, replyPort);
      }
    }, onError: (Object _) {});
  }

  int get port => _socket.port;

  /// Starts a responder that replies to [replyPort].
  static Future<FakeConsoleResponder> start(int replyPort) async =>
      FakeConsoleResponder._(
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
        replyPort,
      );

  void close() => _socket.close();
}

final class FakeBehavior {
  final int firstAck;
  final int secondAck;
  final int? closeAfterFrames;
  const FakeBehavior({
    this.firstAck = 0,
    this.secondAck = 0,
    this.closeAfterFrames,
  });
}

final class ReceivedUpload {
  String? name;
  int? declaredSize;
  final frameLengths = <int>[];
  List<int>? payload;
  List<String>? argv;
  bool closedByHost = false;
}

/// A console netloader's upload side, accepting one TCP connection.
final class FakeNetloader {
  final ServerSocket _server;
  final FakeBehavior _behavior;
  final _done = Completer<ReceivedUpload>();

  FakeNetloader._(this._server, this._behavior) {
    _server.first.then(_serve);
  }

  static Future<FakeNetloader> start([
    FakeBehavior behavior = const FakeBehavior(),
  ]) async => FakeNetloader._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    behavior,
  );

  int get port => _server.port;

  /// What the host sent, once the host closes its side.
  Future<ReceivedUpload> get upload => _done.future;

  Future<void> close() => _server.close();

  Future<void> _serve(Socket socket) async {
    socket.done.ignore();
    final input = StreamIterator(socket);
    final pending = <int>[];
    final got = ReceivedUpload();

    Future<List<int>?> take(int n) async {
      while (pending.length < n) {
        if (!await input.moveNext()) return null;
        pending.addAll(input.current);
      }
      final bytes = pending.sublist(0, n);
      pending.removeRange(0, n);
      return bytes;
    }

    Future<int> int32() async => ByteData.sublistView(
      Uint8List.fromList((await take(4))!),
    ).getInt32(0, Endian.little);

    void ack(int code) => socket.add(
      Uint8List(4)..buffer.asByteData().setInt32(0, code, Endian.little),
    );

    try {
      got.name = utf8.decode((await take(await int32()))!);
      got.declaredSize = await int32();
      ack(_behavior.firstAck);
      await socket.flush();
      if (_behavior.firstAck != 0) return;

      final decoded = BytesBuilder();
      final inflate = RawZLibFilter.inflateFilter();
      final compressed = BytesBuilder();
      while (true) {
        final length = await int32();
        got.frameLengths.add(length);
        final frame = (await take(length))!;
        compressed.add(frame);
        inflate.process(frame, 0, frame.length);
        for (var out = inflate.processed(); out != null;) {
          decoded.add(out);
          out = inflate.processed();
        }
        if (_behavior.closeAfterFrames == got.frameLengths.length) return;
        if (decoded.length >= got.declaredSize!) break;
      }
      got.payload = ZLibDecoder().convert(compressed.takeBytes());
      ack(_behavior.secondAck);
      await socket.flush();
      if (_behavior.secondAck != 0) return;

      final argv = utf8.decode((await take(await int32()))!);
      got.argv = argv.split('\x00')..removeLast();
      got.closedByHost = !await input.moveNext();
      _done.complete(got);
    } finally {
      await input.cancel();
      socket.destroy();
    }
  }
}
