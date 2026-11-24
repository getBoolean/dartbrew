import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the host sent in one upload.
final class ConsoleUpload {
  final String name;
  final List<int> payload;

  /// The app's argv, without the netloader's trailing host entry.
  final List<String> argv;

  ConsoleUpload(this.name, this.payload, this.argv);

  /// The value of the `--ctr-run=<key>=` token.
  String? identity(String key) => _token('--ctr-run=$key=');

  /// The `--ctr-host-port=` value.
  int? get hostPort => int.tryParse(_token('--ctr-host-port=') ?? '');

  String? _token(String prefix) {
    for (final arg in argv) {
      if (arg.startsWith(prefix)) return arg.substring(prefix.length);
    }
    return null;
  }
}

/// The launcher side of a run: writes records to [socket] as the console
/// would, built from the identity in [upload].
final class FakeLauncher {
  final ConsoleUpload upload;
  final Socket socket;

  FakeLauncher(this.upload, this.socket);

  String get runId => upload.identity('run_id')!;

  void record(Map<String, Object?> fields) =>
      socket.write('CTR_RUNTIME ${jsonEncode({...fields, 'run_id': runId})}\n');

  /// The `begin` record echoing every argv identity token, as a launcher
  /// started by the netloader does.
  void begin() => record({
    'event': 'begin',
    'schema': int.parse(upload.identity('schema')!),
    for (final key in [
      'fixture',
      'mode',
      'compatibility',
      'artifact_sha256',
      'build_id',
      'environment',
    ])
      key: upload.identity(key),
  });

  void output(String text) => record({'event': 'output', 'text': text});

  void cleanup(String status) =>
      record({'event': 'assert', 'name': 'cleanup', 'status': status});

  void terminal(String outcome, {int? exitCode}) => record({
    'event': 'terminal',
    'outcome': outcome,
    'assertions': 1,
    'exit_code': ?exitCode,
  });

  /// A bare keepalive line.
  void keepalive() => socket.write('\n');

  Future<void> close() async {
    await socket.flush();
    await socket.close();
  }
}

/// Plays the app after an upload. Return without closing to leave the
/// connection open and silent.
typedef LauncherScript = Future<void> Function(FakeLauncher launcher);

/// A console netloader on loopback: accepts uploads on [port] and, when
/// [script] is given, connects back to the host port named in argv and runs
/// it.
final class FakeConsole {
  final ServerSocket _server;
  final LauncherScript? script;
  final uploads = <ConsoleUpload>[];
  final _sockets = <Socket>[];
  final _uploaded = Completer<ConsoleUpload>();

  FakeConsole._(this._server, this.script) {
    _server.listen(_serve);
  }

  /// Starts a console on a free loopback port, or on [port].
  static Future<FakeConsole> start({
    LauncherScript? script,
    int port = 0,
  }) async => FakeConsole._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, port),
    script,
  );

  int get port => _server.port;

  /// The first upload received.
  Future<ConsoleUpload> get uploaded => _uploaded.future;

  Future<void> close() async {
    await _server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }

  Future<void> _serve(Socket socket) async {
    socket.done.ignore();
    final input = StreamIterator(socket);
    final pending = <int>[];

    Future<List<int>> take(int n) async {
      while (pending.length < n) {
        if (!await input.moveNext()) throw const SocketException('closed');
        pending.addAll(input.current);
      }
      final bytes = pending.sublist(0, n);
      pending.removeRange(0, n);
      return bytes;
    }

    Future<int> int32() async => ByteData.sublistView(
      Uint8List.fromList(await take(4)),
    ).getInt32(0, Endian.little);

    void ack() => socket.add(Uint8List(4));

    final ConsoleUpload upload;
    try {
      final name = utf8.decode(await take(await int32()));
      final size = await int32();
      ack();
      final inflate = RawZLibFilter.inflateFilter();
      final payload = BytesBuilder();
      while (payload.length < size) {
        final frame = await take(await int32());
        inflate.process(frame, 0, frame.length);
        for (var out = inflate.processed(); out != null;) {
          payload.add(out);
          out = inflate.processed();
        }
      }
      ack();
      await socket.flush();
      final argv = utf8.decode(await take(await int32())).split('\x00')
        ..removeLast();
      upload = ConsoleUpload(name, payload.takeBytes(), argv);
    } finally {
      await input.cancel();
      socket.destroy();
    }
    uploads.add(upload);
    if (!_uploaded.isCompleted) _uploaded.complete(upload);

    final script = this.script;
    final port = upload.hostPort;
    if (script == null || port == null) return;
    final back = await Socket.connect(InternetAddress.loopbackIPv4, port);
    back.done.ignore();
    _sockets.add(back);
    await script(FakeLauncher(upload, back));
  }
}

/// Answers `3dsboot` with `boot3ds` sent to [replyPort], like a console's
/// netloader discovery, from a UDP socket bound on [port].
Future<RawDatagramSocket> fakeDiscoveryResponder(
  int replyPort, {
  int port = 0,
}) async {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.loopbackIPv4,
    port,
  );
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    for (var d = socket.receive(); d != null; d = socket.receive()) {
      if (ascii.decode(d.data, allowInvalid: true) == '3dsboot') {
        socket.send(ascii.encode('boot3ds'), d.address, replyPort);
      }
    }
  }, onError: (Object _) {});
  return socket;
}
