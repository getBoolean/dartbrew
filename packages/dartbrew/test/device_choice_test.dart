import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:dartbrew/src/commands/run.dart';
import 'package:dartbrew/src/device/device_choice.dart';
import 'package:dartbrew/src/targets/ctr/pipeline.dart';
import 'package:test/test.dart';

/// Parses `run`'s device options from [arguments] in the current directory.
DeviceRunSettings _settings(List<String> arguments) {
  final parser = ArgParser();
  addDeviceRunOptions(parser);
  return DeviceRunSettings.parse(parser.parse(arguments), 'usage');
}

void main() {
  test('no -d discovers a console and builds JIT', () {
    final settings = _settings([]);
    expect(settings.device, isA<DiscoverConsole>());
    expect(settings.mode, BuildMode.jit);
  });

  test('-d console discovers a console', () {
    expect(_settings(['-d', 'console']).device, isA<DiscoverConsole>());
  });

  test('-d <ip> is the console at that address and builds JIT', () {
    final settings = _settings(['-d', '192.168.1.20']);
    expect(
      settings.device,
      isA<ConsoleAt>().having(
        (choice) => choice.address,
        'address',
        InternetAddress('192.168.1.20'),
      ),
    );
    expect(settings.mode, BuildMode.jit);
  });

  test('-d azahar is Azahar at the --azahar path and builds AOT', () {
    final settings = _settings(['-d', 'azahar', '--azahar', 'emu/azahar']);
    expect(
      settings.device,
      isA<Azahar>().having(
        (choice) => choice.executablePath,
        'executablePath',
        'emu/azahar',
      ),
    );
    expect(settings.mode, BuildMode.aot);
    expect(
      _settings(['-d', 'azahar']).device,
      isA<Azahar>().having((c) => c.executablePath, 'executablePath', isNull),
    );
  });

  for (final invalid in ['300.1.1.1', '::1', 'my-console']) {
    test('-d $invalid is a usage error', () {
      expect(
        () => _settings(['-d', invalid]),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            '-d must be "console", "azahar" or a console\'s IPv4 address.',
          ),
        ),
      );
    });
  }
}
