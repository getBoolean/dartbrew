// Experiment (not a qualified fixture): records how each unsupported area fails.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

void _entry(Object? message) {}

String _clip(Object error) {
  final text = error.toString().replaceAll(RegExp(r'\s+'), ' ');
  return text.length > 120 ? text.substring(0, 120) : text;
}

Future<void> _area(String name, FutureOr<void> Function() call) async {
  print('try:$name');
  try {
    await Future.sync(call).timeout(const Duration(seconds: 5));
    print('area:$name:completed::');
  } on TimeoutException catch (error) {
    print('area:$name:timeout:${error.runtimeType}:${_clip(error)}');
  } catch (error) {
    print('area:$name:threw:${error.runtimeType}:${_clip(error)}');
  }
}

Future<void> main(List<String> args) async {
  await _area('socket', () async {
    final socket = await Socket.connect(
      '127.0.0.1',
      9,
      timeout: const Duration(seconds: 3),
    );
    socket.destroy();
  });
  await _area('process', () => Process.run('echo', ['probe']));
  await _area('isolate', () async {
    final isolate = await Isolate.spawn(_entry, null);
    isolate.kill();
  });
  await _area('ffi', () => DynamicLibrary.open('libprobe_missing.so'));
}
