import 'dart:async';
import 'dart:io';

import 'run_identity.dart';
import 'stream.dart';
import 'verdict.dart';

/// A device that `run` and `test` start an app on: a console or an emulator.
abstract interface class RunDevice {
  /// The environment of runs on this device.
  RunEnvironment get environment;

  /// Whether a connection from [address] can be the app on this device.
  ///
  /// The host listener destroys connections from any other peer, so a
  /// stray or hostile client cannot take over the run.
  bool acceptsPeer(InternetAddress address);

  /// Sends [app] to the device and starts it with the run [identity], telling
  /// it to connect back to the host listener on [hostPort].
  ///
  /// Completes once the device has accepted the app; the connect deadline
  /// starts then.
  Future<void> launch(File app, RunIdentity identity, int hostPort);

  /// Releases the device after the run, for example by closing an emulator.
  Future<void> dispose();
}

/// A [RunDevice] whose app also appends its records to a journal the host
/// can read, such as an emulator's SD card on the host's disk.
///
/// [runOnDevice] reads the journal when the app has not connected back
/// within the connect deadline.
abstract interface class JournalingDevice implements RunDevice {
  /// The bytes appended to the journal since [launch], as they appear.
  ///
  /// Ends when the device stops, for example when the emulator exits.
  /// Cancelling the subscription stops reading.
  Stream<List<int>> journal();
}

/// How long a run may stay silent before the host gives up.
final class RunDeadlines {
  /// How long after [RunDevice.launch] the app has to connect back.
  ///
  /// On a [JournalingDevice] the run then reads the journal instead, and
  /// ends with a connect timeout only if the journal also gains nothing
  /// within this long.
  final Duration connect;

  /// How long the connection may carry no bytes, keepalives included,
  /// before it counts as lost.
  final Duration idle;

  /// The longest the whole run may take after launch, or null for no limit.
  final Duration? timeout;

  const RunDeadlines({
    this.connect = const Duration(seconds: 15),
    this.idle = const Duration(seconds: 10),
    this.timeout,
  });
}

/// The result of [runOnDevice].
final class RunResult {
  final Verdict verdict;

  /// The exit code and message for [verdict] and how the stream ended (see
  /// [exitFor]).
  final RunExit exit;

  const RunResult(this.verdict, this.exit);
}

/// Launches [app] on [device] and streams its records from the first
/// connection to [listener] until the app closes the connection or a
/// deadline passes.
///
/// When [device] is a [JournalingDevice] and no connection arrives within
/// the connect deadline, records are read from its journal instead, filtered
/// by run ID, until the current run's terminal record, a rule violation,
/// the journal's end or a deadline.
///
/// [listener] must already be bound, so a fast app cannot miss it. Each
/// accepted output record's text goes to [onOutput] as it arrives.
///
/// When the app connects, [input] is called once for the program's stdin,
/// such as the terminal's. Its bytes go to the app over the connection; when
/// it ends, or cannot be opened, the host closes its sending side, which the
/// app reads as the end of stdin. Reading it stops when the run ends.
/// Without [input] the host sends nothing and keeps its side open.
/// Connections from peers [RunDevice.acceptsPeer] rejects are closed without
/// affecting the run, and connections after the first accepted one are
/// refused. The listener is left open for the caller to close, and [device]
/// is not disposed.
///
/// Throws whatever [RunDevice.launch] throws, such as a
/// `DartbrewException` for a failed upload.
Future<RunResult> runOnDevice({
  required RunDevice device,
  required File app,
  required RunIdentity identity,
  required ServerSocket listener,
  RunDeadlines deadlines = const RunDeadlines(),
  void Function(String text)? onOutput,
  Stream<List<int>> Function()? input,
}) async {
  final accumulator = VerdictAccumulator(identity);
  final parser = RuntimeLineParser();
  final ended = Completer<StreamEnd>();
  void end(StreamEnd reason) {
    if (!ended.isCompleted) ended.complete(reason);
  }

  void feed(List<RuntimeLine> lines) {
    for (final line in lines) {
      final text = accumulator.add(line);
      if (text != null) onOutput?.call(text);
    }
  }

  Socket? connection;
  StreamSubscription<List<int>>? forwarding;
  Timer? idle;
  StreamSubscription<List<int>>? journal;
  Timer? journalSilent;
  final accepting = listener.listen((socket) {
    bool expected;
    try {
      expected = device.acceptsPeer(socket.remoteAddress);
    } on SocketException {
      expected = false; // The peer is already gone.
    }
    if (!expected) {
      socket.destroy();
      return;
    }
    if (connection != null || journal != null || ended.isCompleted) {
      socket.destroy();
      return;
    }
    connection = socket;
    idle = Timer(deadlines.idle, () => end(StreamEnd.idleTimeout));
    socket.listen(
      (chunk) {
        if (ended.isCompleted) return;
        idle?.cancel();
        idle = Timer(deadlines.idle, () => end(StreamEnd.idleTimeout));
        feed(parser.feed(chunk));
      },
      onDone: () => end(StreamEnd.closed),
      onError: (Object _) => end(StreamEnd.closed),
      cancelOnError: true,
    );
    if (input == null) return;
    void endInput() {
      if (!ended.isCompleted) socket.close().ignore();
    }

    // A failed write (the console dropped off Wi-Fi) also ends the reading
    // side, which reports the lost connection; it must not surface here.
    socket.done.ignore();
    try {
      forwarding = input().listen(
        (chunk) {
          if (!ended.isCompleted) socket.add(chunk);
        },
        onDone: endInput,
        onError: (Object _) => endInput(),
        cancelOnError: true,
      );
    } on Exception {
      // This process has no usable stdin: the program reads none.
      endInput();
    }
  }, onError: (Object _) {});

  void readJournal(JournalingDevice device) {
    final journalParser = RuntimeLineParser();
    void feedJournal(List<RuntimeLine> lines) {
      feed(lines);
      final terminal = lines.any(
        (line) =>
            line is RuntimeRecord &&
            line.fields['run_id'] == identity.runId &&
            line.fields['event'] == 'terminal',
      );
      if (terminal || accumulator.error != null) end(StreamEnd.closed);
    }

    journalSilent = Timer(
      deadlines.connect,
      () => end(StreamEnd.connectTimeout),
    );
    journal = device.journal().listen(
      (chunk) {
        if (ended.isCompleted) return;
        journalSilent?.cancel();
        feedJournal(journalParser.feed(chunk));
      },
      onDone: () {
        if (ended.isCompleted) return;
        feedJournal(journalParser.close());
        end(StreamEnd.closed);
      },
      onError: (Object _) => end(StreamEnd.closed),
      cancelOnError: true,
    );
  }

  Timer? connect;
  Timer? overall;
  try {
    await device.launch(app, identity, listener.port);
    if (connection == null) {
      connect = Timer(deadlines.connect, () {
        if (connection != null || ended.isCompleted) return;
        if (device case final JournalingDevice journaling) {
          readJournal(journaling);
        } else {
          end(StreamEnd.connectTimeout);
        }
      });
    }
    if (deadlines.timeout case final timeout?) {
      overall = Timer(timeout, () => end(StreamEnd.userTimeout));
    }
    final reason = await ended.future;
    if (reason == StreamEnd.closed) feed(parser.close());
    final verdict = accumulator.finish();
    return RunResult(verdict, exitFor(verdict, reason, port: listener.port));
  } finally {
    connect?.cancel();
    overall?.cancel();
    idle?.cancel();
    journalSilent?.cancel();
    await journal?.cancel();
    await forwarding?.cancel();
    await accepting.cancel();
    connection?.destroy();
  }
}
