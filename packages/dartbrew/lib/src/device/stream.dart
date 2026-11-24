import 'dart:convert';

/// One line of the app's output that starts with `CTR_RUNTIME `.
sealed class RuntimeLine {
  const RuntimeLine();
}

/// A prefixed line whose payload is a JSON object.
final class RuntimeRecord extends RuntimeLine {
  const RuntimeRecord(this.fields);

  final Map<String, Object?> fields;
}

/// A prefixed line whose payload is not a JSON object.
final class MalformedRecord extends RuntimeLine {
  const MalformedRecord();
}

/// Splits a byte stream into lines and parses the `CTR_RUNTIME ` ones.
///
/// Chunks may end anywhere, including inside a line or a multi-byte
/// character. Lines end at LF, a trailing CR is dropped, and lines without
/// the prefix (keepalive blanks, boot noise) are ignored. A line longer than
/// [maxLineLength] is not kept: a prefixed one becomes a single
/// [MalformedRecord], and the rest of it up to the next LF is skipped.
///
/// The launcher splits a long output line into output records marked
/// `"continues": true`, each followed directly by the record that continues
/// it. Those are joined back into one output record with the whole text. A
/// marked record that is not followed by an output record of the same run
/// (a journal left by a run that stopped mid-line) is dropped.
final class RuntimeLineParser {
  static const prefix = 'CTR_RUNTIME ';

  /// The longest line kept, in bytes, without its line ending.
  static const maxLineLength = 64 * 1024;

  static final _prefixBytes = utf8.encode(prefix);

  final _pending = <int>[];

  /// The output record whose text the next output record continues.
  RuntimeRecord? _continued;

  /// Whether the current line went over [maxLineLength] and is skipped up
  /// to its LF.
  var _skipping = false;

  /// Consumes [chunk] and returns the records of the lines it completed.
  List<RuntimeLine> feed(List<int> chunk) {
    final lines = <RuntimeLine>[];
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0x0A) continue;
      _append(chunk, start, i, lines);
      start = i + 1;
      if (_skipping) {
        _skipping = false;
      } else {
        _emit(lines);
      }
    }
    _append(chunk, start, chunk.length, lines);
    return lines;
  }

  /// Returns the record of a final line that has no line ending, if any.
  List<RuntimeLine> close() {
    final lines = <RuntimeLine>[];
    if (_skipping) {
      _skipping = false;
    } else {
      _emit(lines);
    }
    _continued = null;
    return lines;
  }

  void _append(List<int> chunk, int start, int end, List<RuntimeLine> lines) {
    if (_skipping) return;
    _pending.addAll(chunk.getRange(start, end));
    // One byte of slack for a trailing CR, which _emit drops.
    if (_pending.length <= maxLineLength + 1) return;
    _overflow(lines);
    _skipping = true;
  }

  void _overflow(List<RuntimeLine> lines) {
    var prefixed = _pending.length >= _prefixBytes.length;
    for (var i = 0; prefixed && i < _prefixBytes.length; i++) {
      prefixed = _pending[i] == _prefixBytes[i];
    }
    if (prefixed) lines.add(_join(const MalformedRecord())!);
    _pending.clear();
  }

  void _emit(List<RuntimeLine> lines) {
    if (_pending.isNotEmpty && _pending.last == 0x0D) _pending.removeLast();
    if (_pending.length > maxLineLength) return _overflow(lines);
    final text = utf8.decode(_pending, allowMalformed: true);
    _pending.clear();
    if (!text.startsWith(prefix)) return;
    RuntimeLine line;
    try {
      final record = jsonDecode(text.substring(prefix.length));
      line = record is Map<String, Object?>
          ? RuntimeRecord(record)
          : const MalformedRecord();
    } on FormatException {
      line = const MalformedRecord();
    }
    final joined = _join(line);
    if (joined != null) lines.add(joined);
  }

  /// Joins [line] to the continued output record, if any; null while more of
  /// the text is to come.
  RuntimeLine? _join(RuntimeLine line) {
    final continued = _continued;
    _continued = null;
    var joined = line;
    if (continued != null &&
        line is RuntimeRecord &&
        _isOutput(line) &&
        line.fields['run_id'] == continued.fields['run_id']) {
      joined = RuntimeRecord({
        ...line.fields,
        'text': '${continued.fields['text']}${line.fields['text']}',
      });
    }
    if (joined is RuntimeRecord &&
        _isOutput(joined) &&
        joined.fields['continues'] == true) {
      _continued = joined;
      return null;
    }
    return joined;
  }

  static bool _isOutput(RuntimeRecord record) =>
      record.fields['event'] == 'output' && record.fields['text'] is String;
}
