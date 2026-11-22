import 'package:dartbrew/src/test_runner/classify.dart';
import 'package:test/test.dart';

void main() {
  final cases = {
    "Failed to resolve native function 'Socket_CreateConnect' in "
            "'_NativeSocket.createConnect'":
        'sockets',
    "Failed to resolve native function 'InternetAddress_Parse' in "
            "'_InternetAddress._parse'":
        'sockets',
    // The CTR I/O layer's text for an area not ported yet.
    "SocketException: Failed host lookup: 'example.com' (OS Error: "
            'InternetAddress is not supported on CTR (dart:io), errno = 38)':
        'sockets',
    "Failed to resolve native function 'Process_Start' in "
            "'_ProcessImpl._startNative'":
        'processes',
    'ProcessException: Process is not supported on CTR (dart:io)\n'
            '  Command: ls':
        'processes',
    "FileSystemException: Cannot create link to target 'b', path = 'a' "
            '(OS Error: Link is not supported on CTR (dart:io), errno = 38)':
        'links',
    'FileSystemException: File system watching is not supported on this '
            'platform':
        'file system watching',
    'IsolateSpawnException: Unable to spawn isolate: no isolate group':
        'isolates',
    // Observed on a New 3DS (AOT and JIT).
    'Unsupported operation: Isolate.spawn': 'isolates',
    "Invalid argument(s): Failed to load dynamic library 'libx.so'": 'FFI',
    "Unsupported operation: Can't connect to the test runner.\n"
            'spawnHybridUri() is currently only supported within "dart test".':
        'hybrid tests (spawnHybridUri and spawnHybridCode)',
    // A host driver's fallback resolver names the native; the stack names
    // the area.
    'Unsupported operation: Platform_OperatingSystem is not supported on '
            'CTR (dart:io)\n#0      _ProcessImpl._start':
        'processes',
    'Unsupported operation: Platform_GetVersion is not supported on CTR '
            '(dart:io)\n#0      _HttpClient._openUrl':
        'sockets',
    'SocketException: Failed host lookup\n'
            '#0      _NativeSynchronousSocket.lookup':
        'sockets',
    'Unsupported operation: Foo_Bar is not supported on CTR (dart:io)':
        'dart:io',
  };
  cases.forEach((text, area) {
    test('"${text.split('\n').first}" is $area', () {
      expect(classifyUnsupported(text)?.name, area);
    });
  });

  test('the message names the area and the target', () {
    expect(
      classifyUnsupported("native function 'Socket_CreateConnect'")!.message,
      'sockets is not supported on CTR',
    );
  });

  test('ordinary failures are not attributed to an area', () {
    expect(classifyUnsupported('Expected: <8>\n  Actual: <7>'), isNull);
    expect(classifyUnsupported('Bad state: boom'), isNull);
    expect(classifyUnsupported('lost connection'), isNull);
  });

  test('failures of the working dart:io areas are not attributed', () {
    // Files, stdio, Platform and exit work on CTR; their errors are ordinary.
    expect(
      classifyUnsupported(
        "PathNotFoundException: Cannot open file, path = 'x' (OS Error: No "
        'such file or directory, errno = 2)\n#0      _File.open',
      ),
      isNull,
    );
    expect(
      classifyUnsupported('#0      _RandomAccessFile.readSync\n#1 _StdIOUtils'),
      isNull,
    );
    expect(classifyUnsupported('#0      _ProcessUtils._exit'), isNull);
  });
}
