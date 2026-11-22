/// Maps error text from a test run on CTR to the unsupported API area that
/// caused it (KTD10).
///
/// The launcher links the SDK's `dart:io` layer ported to CTR. Files,
/// directories, stdio, `Platform` and `exit` work; areas not ported yet fail
/// with an `OSError` whose text is `<Area> is not supported on CTR
/// (dart:io)`, so that text, plus the stack, identifies the area. Links,
/// file watching and processes stay unsupported by design. The table also
/// keeps the VM's own unresolved-native text (host drivers resolve no
/// `dart:io` native), `dart:ffi` and `dart:isolate` failure messages, and
/// `package:test_api`'s `spawnHybridUri` error. The shapes are recorded in
/// `docs/ctr-supported-features.md`.
library;

/// One row of [unsupportedAreas]: an area name and the error text that
/// identifies it.
final class UnsupportedArea {
  /// The area as named in messages, for example `file I/O`.
  final String name;

  /// Matches error text, a stack trace, or the name of an unresolved native.
  final RegExp pattern;

  const UnsupportedArea(this.name, this.pattern);

  /// The failure message that names this area.
  String get message => '$name is not supported on CTR';
}

/// The classification table, checked in order; the first match wins.
///
/// Order matters: `IOService_` natives serve sockets as well as the working
/// file I/O, so only socket frames and messages name an area. Text from the
/// working areas (files, stdio, `Platform`, `exit`) matches no row, so their
/// ordinary failures are reported as they are.
final List<UnsupportedArea> unsupportedAreas = [
  UnsupportedArea(
    'hybrid tests (spawnHybridUri and spawnHybridCode)',
    RegExp(r'spawnHybrid(Uri|Code)|Can.t connect to the test runner'),
  ),
  UnsupportedArea(
    'sockets',
    RegExp(
      r'\b(Socket_\w+|ServerSocket_\w+|RawSocketOption_\w+|'
      r'InternetAddress_\w+|NetworkInterface_\w+|SecureSocket_\w+|'
      r'SecurityContext_\w+|_NativeSocket|_NativeSynchronousSocket|'
      r'_RawSocket|_RawServerSocket|_InternetAddress|_HttpClient)\b|'
      r'\b(Socket|InternetAddress|NetworkInterface|RawSynchronousSocket) '
      r'is not supported on CTR',
    ),
  ),
  UnsupportedArea(
    'processes',
    RegExp(
      r'\b(Process_Start|Process_Wait|Process_KillPid|_ProcessImpl|'
      r'ProcessInfo_\w+)\b|\bProcess is not supported on CTR',
    ),
  ),
  // The SD card and romfs have no links.
  UnsupportedArea('links', RegExp(r'\bLink is not supported on CTR')),
  UnsupportedArea(
    'file system watching',
    RegExp(r'File system watching is not supported'),
  ),
  UnsupportedArea(
    'isolates',
    RegExp(
      r'IsolateSpawnException|Unable to spawn isolate|Isolate\.spawn|'
      r'\bIsolate_spawn\w*',
    ),
  ),
  UnsupportedArea(
    'FFI',
    RegExp(
      r'Failed to load dynamic library|Failed to lookup symbol|'
      r'\bFfi_\w+|\bDynamicLibrary\b',
    ),
  ),
  // Any other area the CTR I/O layer or a host driver's resolver refused.
  UnsupportedArea('dart:io', RegExp(r'is not supported on CTR \(dart:io\)')),
];

/// The area that [text] (an error, a stack trace, or the last output of a
/// run that stopped) names, or null when none is attributable.
UnsupportedArea? classifyUnsupported(String text) {
  for (final area in unsupportedAreas) {
    if (area.pattern.hasMatch(text)) return area;
  }
  return null;
}
