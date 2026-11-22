import 'run_identity.dart';
import 'stream.dart';

/// What the app reported about a run.
enum Outcome { pass, fail, incomplete }

/// What the host saw of the app besides its records.
enum Observation { crash, timeout }

/// Why the record stream stopped.
enum StreamEnd { closed, idleTimeout, connectTimeout, userTimeout }

/// The result of one run.
final class Verdict {
  const Verdict(
    this.outcome,
    this.reason,
    this.output, {
    this.noTerminal = false,
    this.exitCode,
  });

  final Outcome outcome;

  /// Why the outcome is [Outcome.incomplete] because of the records or the
  /// host observation, or null when the app reported the outcome itself.
  final String? reason;

  /// The text of every output record accepted before the verdict was decided.
  final List<String> output;

  /// Whether the journal ended without a complete begin, cleanup and terminal
  /// sequence, so the stream's end decides what to tell the user.
  final bool noTerminal;

  /// The code the program ended with through `exit` or a nonzero `exitCode`,
  /// from the terminal record's `exit_code`; null when it carried none.
  final int? exitCode;
}

/// The launcher contract schemas a `begin` record may carry.
const supportedSchemas = [1, 2];

/// Computes the verdict of one run from its records, as they arrive.
///
/// After the first rule violation later records are ignored.
final class VerdictAccumulator {
  /// [expected] is the identity of the run the host started.
  VerdictAccumulator(this.expected);

  final RunIdentity expected;
  final _output = <String>[];
  var _active = false;
  String? _cleanup;
  Map<String, Object?>? _terminal;
  String? _error;

  /// The rule violation that decided the verdict, if one has occurred.
  String? get error => _error;

  /// Feeds one record and returns its text if it is an accepted output
  /// record, so the caller can print it at once.
  String? add(RuntimeLine line) {
    if (_error != null) return null;
    try {
      return _add(line);
    } on _Violation catch (violation) {
      _error = violation.reason;
      return null;
    }
  }

  String? _add(RuntimeLine line) {
    if (line is! RuntimeRecord) {
      if (_active) throw const _Violation('malformed current-run record');
      return null;
    }
    final record = line.fields;
    if (record['run_id'] != expected.runId) {
      if (_active) throw const _Violation('interleaved run');
      return null;
    }
    if (_terminal != null) throw const _Violation('record after terminal');
    final event = record['event'];
    if (event == 'begin') {
      if (_active || !expected.matchesBegin(record)) {
        throw const _Violation('duplicate begin or identity mismatch');
      }
      if (!supportedSchemas.contains(record['schema'])) {
        throw const _Violation('unsupported begin schema');
      }
      _active = true;
    } else if (!_active) {
      throw const _Violation('record before begin');
    } else if (event == 'output' && record['text'] is String) {
      final text = record['text'] as String;
      _output.add(text);
      return text;
    } else if (event == 'assert') {
      final status = record['status'];
      if (_cleanup != null ||
          record['name'] != 'cleanup' ||
          (status != 'pass' && status != 'fail')) {
        throw const _Violation('invalid cleanup assertion');
      }
      _cleanup = status as String;
    } else if (event == 'terminal') {
      _terminal = record;
    } else {
      throw const _Violation('unknown event');
    }
    return null;
  }

  /// The verdict for the records fed so far, given what the host observed.
  Verdict finish([Observation? observation]) {
    final output = List<String>.unmodifiable(_output);
    final error = _error;
    if (error != null) return Verdict(Outcome.incomplete, error, output);
    final problem = _finalProblem(observation);
    if (problem != null) {
      return Verdict(
        Outcome.incomplete,
        problem.reason,
        output,
        noTerminal: problem.noTerminal,
      );
    }
    final terminal = _terminal!;
    final outcome = switch (terminal['outcome']) {
      'pass' => Outcome.pass,
      'fail' => Outcome.fail,
      _ => Outcome.incomplete,
    };
    return Verdict(
      outcome,
      null,
      output,
      exitCode: terminal['exit_code'] as int?,
    );
  }

  ({String reason, bool noTerminal})? _finalProblem(Observation? observation) {
    final terminal = _terminal;
    if (!_active ||
        terminal == null ||
        _cleanup == null ||
        terminal['assertions'] != 1) {
      return (reason: 'missing begin, cleanup or terminal', noTerminal: true);
    }
    final outcome = terminal['outcome'];
    // exit(n) and a nonzero exitCode end the run with exit_code: 0 passes,
    // any other code fails carrying it.
    final exitCode = terminal['exit_code'];
    if (terminal.containsKey('exit_code') && exitCode is! int) {
      return (reason: 'invalid exit code', noTerminal: false);
    }
    if (!const ['pass', 'fail', 'incomplete'].contains(outcome) ||
        (_cleanup == 'fail' && outcome != 'fail') ||
        (exitCode != null &&
            (outcome == 'incomplete' ||
                (outcome == 'pass' && exitCode != 0)))) {
      return (reason: 'contradictory outcome', noTerminal: false);
    }
    if (observation == Observation.crash) {
      return (reason: 'host observed crash', noTerminal: false);
    }
    return null;
  }
}

final class _Violation implements Exception {
  const _Violation(this.reason);

  final String reason;
}

/// How `run` ends: the process exit code and what to tell the user.
final class RunExit {
  const RunExit(this.code, [this.message]);

  final int code;

  /// Null when nothing needs saying, such as a pass or a failure whose error
  /// text was already streamed.
  final String? message;

  @override
  String toString() => 'RunExit($code, $message)';
}

/// Maps [verdict] and the reason the stream ended to the exit code and
/// message of `run`.
///
/// [port] is the port the app should have connected back to, named in the
/// firewall hint.
RunExit exitFor(Verdict verdict, StreamEnd end, {int? port}) {
  switch (verdict.outcome) {
    case Outcome.pass:
      return const RunExit(0);
    case Outcome.fail:
      // The program's own exit code when a process can exit with it (1-255),
      // or 255 for any other failure.
      final code = verdict.exitCode;
      return RunExit(code != null && code >= 1 && code <= 255 ? code : 255);
    case Outcome.incomplete:
      if (verdict.noTerminal) {
        return RunExit(1, switch (end) {
          StreamEnd.closed || StreamEnd.idleTimeout => 'lost connection',
          StreamEnd.connectTimeout =>
            'app never connected back; check the host firewall for inbound '
                'TCP${port == null ? '' : ' on port $port'}',
          StreamEnd.userTimeout => 'timed out',
        });
      }
      return RunExit(1, verdict.reason ?? 'stopped on console');
  }
}
