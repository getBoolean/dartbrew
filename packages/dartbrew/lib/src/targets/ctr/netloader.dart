import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../device/transport.dart';
import '../../errors.dart';

/// The port the Homebrew Launcher netloader uses for discovery, for replies
/// to the host and for uploads.
const netloaderPort = 17491;

/// The largest compressed frame the netloader can receive in one piece.
const maxFrameLength = 16 * 1024;

/// The largest argv block sent; the reference client uses the same limit.
const maxArgvLength = 3072;

const _discoveryInterval = Duration(milliseconds: 150);
final _ping = ascii.encode('3dsboot');
final _pong = ascii.encode('boot3ds');

/// The exit code of a command whose discovery or upload failed.
const _failureExitCode = 1;

/// Lists the local addresses to send discovery broadcasts from.
typedef InterfaceAddressLister = Future<List<InternetAddress>> Function();

/// Every non-loopback IPv4 address of this host.
Future<List<InternetAddress>> ipv4InterfaceAddresses() async => [
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  ))
    ...interface.addresses.where((address) => !address.isLoopback),
];

/// A client for the Homebrew Launcher netloader on CTR consoles.
///
/// Discovery broadcasts `3dsboot` and collects `boot3ds` replies. The
/// netloader sends its reply to [replyPort] on the host, not to the port the
/// broadcast came from, so discovery binds that port to receive it.
///
/// The defaults are the real protocol's. Tests pass loopback addresses and
/// free ports instead.
final class NetloaderClient implements DeviceTransport {
  /// The port the console listens on, for discovery and uploads.
  final int port;

  /// The host port the console sends discovery replies to.
  final int replyPort;

  /// The local address the reply socket binds.
  final InternetAddress receiveAddress;

  /// Where discovery broadcasts are sent.
  final InternetAddress broadcastAddress;

  /// The local addresses broadcasts are sent from, one socket each, so every
  /// network adapter is tried on hosts with several.
  final InterfaceAddressLister interfaceAddresses;

  /// How long [upload] waits for the console to accept the connection.
  final Duration connectTimeout;

  /// How long [upload] waits for each acknowledgement or write to make
  /// progress. The console can pause for several seconds while it saves a
  /// large app to its SD card, so this is generous.
  final Duration ackTimeout;

  NetloaderClient({
    this.port = netloaderPort,
    this.replyPort = netloaderPort,
    InternetAddress? receiveAddress,
    InternetAddress? broadcastAddress,
    this.interfaceAddresses = ipv4InterfaceAddresses,
    this.connectTimeout = const Duration(seconds: 15),
    this.ackTimeout = const Duration(seconds: 60),
  }) : receiveAddress = receiveAddress ?? InternetAddress.anyIPv4,
       broadcastAddress =
           broadcastAddress ?? InternetAddress('255.255.255.255');

  /// Emits each console that answers within [wait].
  ///
  /// Emits a [DartbrewException] naming [replyPort] when that port cannot
  /// be bound, for example because another program holds it.
  @override
  Stream<InternetAddress> discover(Duration wait) {
    final controller = StreamController<InternetAddress>();
    final sockets = <RawDatagramSocket>[];
    final seen = <String>{};
    Timer? ticker;
    Timer? deadline;
    var stopped = false;

    void stop() {
      if (stopped) return;
      stopped = true;
      ticker?.cancel();
      deadline?.cancel();
      for (final socket in sockets) {
        socket.close();
      }
    }

    bool keep(RawDatagramSocket socket) {
      if (stopped) {
        socket.close();
        return false;
      }
      sockets.add(socket);
      return true;
    }

    Future<void> start() async {
      final RawDatagramSocket receiver;
      try {
        receiver = await RawDatagramSocket.bind(
          receiveAddress,
          replyPort,
          reuseAddress: false,
        );
      } on SocketException catch (error) {
        if (stopped) return;
        stop();
        controller.addError(
          DartbrewException(
            _failureExitCode,
            'Could not listen on UDP port $replyPort for console replies '
            '(${error.osError?.message ?? error.message}). Close the other '
            'program using it, such as another dartbrew or 3dslink, and try '
            'again.',
          ),
        );
        await controller.close();
        return;
      }
      if (!keep(receiver)) return;
      receiver.listen((event) {
        if (stopped || event != RawSocketEvent.read) return;
        for (var d = receiver.receive(); d != null; d = receiver.receive()) {
          if (_startsWith(d.data, _pong) && seen.add(d.address.address)) {
            controller.add(d.address);
          }
        }
      }, onError: (Object _) {});

      final senders = <RawDatagramSocket>[];
      for (final address in await interfaceAddresses()) {
        try {
          final sender = await RawDatagramSocket.bind(address, 0);
          if (!keep(sender)) return;
          sender.broadcastEnabled = true;
          // Drains stray datagrams and ICMP errors so they are never
          // reported as unhandled.
          sender.listen((event) {
            if (event == RawSocketEvent.read) sender.receive();
          }, onError: (Object _) {});
          senders.add(sender);
        } on SocketException {
          // An adapter that cannot be bound is skipped; the others still run.
        }
      }
      if (stopped) return;

      void ping() {
        for (final sender in senders) {
          try {
            sender.send(_ping, broadcastAddress, port);
          } on SocketException {
            // A failing adapter must not end discovery on the others.
          }
        }
      }

      ping();
      ticker = Timer.periodic(_discoveryInterval, (_) => ping());
    }

    controller
      ..onListen = () {
        deadline = Timer(wait, () {
          stop();
          controller.close();
        });
        start();
      }
      ..onCancel = stop;
    return controller.stream;
  }

  /// Sends [app] to the netloader on [console], which saves it as
  /// `sdmc:/3ds/<basename>` and launches it.
  ///
  /// The app's argv is `sdmc:/3ds/<basename>` followed by [arguments]; the
  /// console then appends its own `<hex ip>_3DSLINK_` entry, which libctru
  /// removes and turns into `__3dslink_host`.
  ///
  /// Throws a [DartbrewException] when the console cannot be reached
  /// within [connectTimeout], rejects the upload, drops the connection, or
  /// leaves a write or acknowledgement pending for longer than [ackTimeout].
  @override
  Future<void> upload(
    InternetAddress console,
    File app, {
    List<String> arguments = const [],
    void Function(int sent, int total)? onProgress,
  }) async {
    final name = p.basename(app.path);
    final argv = encodeArgv(['sdmc:/3ds/$name', ...arguments]);
    final data = await app.readAsBytes();
    final where = '${console.address}:$port';

    final Socket socket;
    try {
      socket = await Socket.connect(console, port, timeout: connectTimeout);
    } on SocketException catch (error) {
      throw DartbrewException(
        _failureExitCode,
        'Could not connect to the netloader at $where '
        '(${error.osError?.message ?? error.message}). Check that '
        'Homebrew Launcher shows the netloader as waiting (press Y).',
      );
    }
    socket.done.ignore();
    final reader = _Reader(socket);
    var stage = 'sending the file name';
    DartbrewException lost([String? cause]) => DartbrewException(
      _failureExitCode,
      'Lost the connection to the console at $where while $stage'
      '${cause == null ? '' : ' ($cause)'}.',
    );
    // Each step must make progress within ackTimeout, so a console that
    // stops answering without closing the connection cannot hang the upload.
    Future<void> step(Future<void> future) =>
        future.timeout(ackTimeout, onTimeout: () => throw lost('timed out'));
    Future<void> ack() async {
      final code = await reader.int32().timeout(
        ackTimeout,
        onTimeout: () => throw lost('timed out'),
      );
      _checkAck(code ?? (throw lost('connection closed')), where);
    }

    try {
      final nameBytes = utf8.encode(name);
      socket
        ..add(_int32(nameBytes.length))
        ..add(nameBytes)
        ..add(_int32(data.length));
      await step(socket.flush());
      stage = 'waiting for the console to accept the file';
      await ack();

      stage = 'sending the app';
      final frames = compressedFrames(data);
      final total = frames.fold<int>(0, (sum, frame) => sum + frame.length);
      var sent = 0;
      for (final frame in frames) {
        socket
          ..add(_int32(frame.length))
          ..add(frame);
        await step(socket.flush());
        sent += frame.length;
        onProgress?.call(sent, total);
      }
      stage = 'waiting for the console to save the app';
      await ack();

      stage = 'sending the launch arguments';
      socket
        ..add(_int32(argv.length))
        ..add(argv);
      await step(socket.flush());
      await step(socket.close());
    } on SocketException catch (error) {
      throw lost(error.osError?.message ?? error.message);
    } finally {
      await reader.cancel();
      socket.destroy();
    }
  }
}

/// [data] as a zlib stream, split into frames of at most [maxFrameLength]
/// bytes.
List<Uint8List> compressedFrames(List<int> data) {
  final stream = Uint8List.fromList(ZLibEncoder().convert(data));
  return [
    for (var start = 0; start < stream.length; start += maxFrameLength)
      Uint8List.sublistView(
        stream,
        start,
        start + maxFrameLength < stream.length
            ? start + maxFrameLength
            : stream.length,
      ),
  ];
}

/// The argv block body: each of [argv] NUL-terminated, back to back.
///
/// Throws a [DartbrewException] when it exceeds [maxArgvLength] bytes.
Uint8List encodeArgv(List<String> argv) {
  final bytes = utf8.encode(argv.map((arg) => '$arg\x00').join());
  if (bytes.length > maxArgvLength) {
    throw DartbrewException(
      _failureExitCode,
      'The program arguments take ${bytes.length} bytes; the netloader '
      'accepts at most $maxArgvLength.',
    );
  }
  return bytes;
}

void _checkAck(int code, String where) {
  if (code == 0) return;
  final reason = switch (code) {
    -1 => 'it could not create the file on the SD card',
    -2 => 'the SD card does not have enough space',
    -3 => 'it does not have enough memory',
    _ => 'unknown reason',
  };
  throw DartbrewException(
    _failureExitCode,
    'The console at $where rejected the upload with code $code ($reason).',
  );
}

Uint8List _int32(int value) =>
    Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);

bool _startsWith(List<int> data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) return false;
  }
  return true;
}

/// Reads little-endian integers from a socket's byte stream.
final class _Reader {
  final StreamIterator<Uint8List> _bytes;
  final _pending = <int>[];

  _Reader(Stream<Uint8List> stream) : _bytes = StreamIterator(stream);

  /// The next int32, or null when the stream ends first.
  Future<int?> int32() async {
    while (_pending.length < 4) {
      if (!await _bytes.moveNext()) return null;
      _pending.addAll(_bytes.current);
    }
    final value = ByteData.sublistView(
      Uint8List.fromList(_pending.sublist(0, 4)),
    ).getInt32(0, Endian.little);
    _pending.removeRange(0, 4);
    return value;
  }

  Future<void> cancel() => _bytes.cancel();
}
