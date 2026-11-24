// dart:io stdio, Platform and process-level calls (U8). Every line is
// deterministic. Run it with stdin at its end (dartbrew run < /dev/null):
// launched without a host, its stdin read opens the software keyboard.
import 'dart:io';

Future<void> main() async {
  print('os:${Platform.operatingSystem}');
  print('environment:${Platform.environment.length}');
  print('processors:${Platform.numberOfProcessors >= 1}');
  print('locale:${Platform.localeName.isNotEmpty}');
  print('hostname:${Platform.localHostname}');
  print(
    'os-version:${Platform.operatingSystemVersion.startsWith('Horizon kernel ')}',
  );
  print('version:${Platform.version.isNotEmpty}');
  final executable = Platform.executable;
  print('executable:${executable.isEmpty || executable.endsWith('.3dsx')}');
  print('script:${Platform.script.isScheme('file')}');
  print('pid:${pid > 0}');
  print('separator:${Platform.pathSeparator}');

  // stdout and stderr arrive in order with print.
  stdout.write('stdout ');
  stdout.writeln('line');
  print('print line');
  stderr.writeln('stderr line');
  stdout.write('partial');
  print(' then print');

  // stdin of a non-interactive run is empty.
  final input = await stdin.toList();
  print('stdin:${input.fold<int>(0, (sum, chunk) => sum + chunk.length)}');

  // sleep blocks the isolate.
  final watch = Stopwatch()..start();
  sleep(const Duration(milliseconds: 200));
  print('sleep:${watch.elapsedMilliseconds >= 200}');

  // Processes are unsupported and say so.
  try {
    await Process.run('ls', []);
    print('process:ran');
  } on ProcessException catch (error) {
    print('process:${error.message}');
  }
  print('exit-code:$exitCode');
}
