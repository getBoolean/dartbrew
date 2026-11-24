import 'dart:async';
import 'dart:io';

import '../errors.dart';
import '../targets/ctr/netloader.dart';
import 'device.dart';
import 'run_identity.dart';
import 'transport.dart';

/// A console reached through its netloader at [address].
final class ConsoleDevice implements RunDevice {
  final DeviceTransport transport;
  final InternetAddress address;

  /// Where upload progress is reported; standard error by default.
  final StringSink progress;

  ConsoleDevice(this.transport, this.address, {StringSink? progress})
    : progress = progress ?? stderr;

  @override
  RunEnvironment get environment => RunEnvironment.hardware;

  @override
  bool acceptsPeer(InternetAddress address) =>
      address.type == this.address.type &&
      address.address == this.address.address;

  /// Uploads [app] under its own file name, so the console saves it as
  /// `sdmc:/3ds/<name>` and repeated runs overwrite it. The argv carries
  /// the identity's launcher tokens, including the optional linked values,
  /// which always equal the values linked into the uploaded app.
  @override
  Future<void> launch(File app, RunIdentity identity, int hostPort) =>
      transport.upload(
        address,
        app,
        arguments: identity.launcherArguments(hostPort),
        onProgress: _reportProgress(),
      );

  /// Reports each further tenth of the upload, since a large app can take
  /// minutes on console Wi-Fi.
  void Function(int, int) _reportProgress() {
    var reported = 0;
    return (sent, total) {
      final tenths = total == 0 ? 10 : sent * 10 ~/ total;
      if (tenths <= reported) return;
      reported = tenths;
      String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
      progress.writeln(
        'Uploaded ${tenths * 10}% (${mb(sent)} of ${mb(total)} MB).',
      );
    };
  }

  @override
  Future<void> dispose() async {}
}

/// Finds the one console whose netloader answers within [wait].
///
/// Tells [prompt] to open the netloader first. Once a console answers,
/// listens [settle] longer so a second console is noticed rather than picked
/// at random. Throws a [DartbrewException] with exit code 1 when none
/// answers and 64 when several do, and passes on the transport's failures.
Future<InternetAddress> discoverConsole(
  DeviceTransport transport, {
  required Duration wait,
  Duration settle = const Duration(seconds: 1),
  required StringSink prompt,
}) async {
  prompt.writeln(
    'Waiting up to ${_seconds(wait)} for a console. Open the netloader in '
    'Homebrew Launcher on the console (press Y).',
  );
  final found = <InternetAddress>[];
  final done = Completer<void>();
  Timer? settling;
  late final StreamSubscription<InternetAddress> subscription;
  subscription = transport
      .discover(wait)
      .listen(
        (address) {
          found.add(address);
          settling ??= Timer(settle, () {
            if (!done.isCompleted) done.complete();
          });
        },
        onError: (Object error, StackTrace stack) {
          if (!done.isCompleted) done.completeError(error, stack);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
  try {
    await done.future;
  } finally {
    settling?.cancel();
    await subscription.cancel();
  }
  if (found.isEmpty) {
    throw DartbrewException(
      1,
      'No console answered within ${_seconds(wait)}. Open Homebrew Launcher '
      'on the console and press Y to start the netloader, then run again. '
      'If the netloader is waiting and still not found, allow UDP port '
      '$netloaderPort through this computer\'s firewall, or pass the '
      'console\'s address with -d <ip>.',
    );
  }
  if (found.length > 1) {
    throw DartbrewException(
      64,
      'Found ${found.length} consoles; choose one with -d <ip>:\n'
      '${found.map((a) => '  ${a.address}').join('\n')}',
    );
  }
  return found.single;
}

String _seconds(Duration duration) {
  final seconds = duration.inMilliseconds / 1000;
  return '${seconds == seconds.roundToDouble() ? seconds.round() : seconds} s';
}
