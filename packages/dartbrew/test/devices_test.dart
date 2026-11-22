import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartbrew/src/commands/devices.dart';
import 'package:dartbrew/src/targets/ctr/azahar.dart';
import 'package:dartbrew/src/targets/ctr/netloader.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class DevicesRun {
  final int? code;
  final String out;
  final String err;
  DevicesRun(this.code, this.out, this.err);
}

/// Runs `devices` with [client]; Azahar is looked for only in [environment]
/// (none by default), so an installed Azahar does not change the output.
Future<DevicesRun> runDevices(
  NetloaderClient client,
  List<String> args, {
  Map<String, String> environment = const {},
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final runner = CommandRunner<int>('dartbrew', 'test')
    ..addCommand(
      devicesCommand(
        transport: () => client,
        azaharHost: AzaharHost(
          environment: environment,
          operatingSystem: Platform.operatingSystem,
          currentDirectory: Directory.systemTemp.path,
        ),
        out: out,
        err: err,
      ),
    );
  final code = await runner.run(['devices', ...args]);
  return DevicesRun(code, out.toString(), err.toString());
}

NetloaderClient loopbackClient({required int port, int replyPort = 0}) =>
    NetloaderClient(
      port: port,
      replyPort: replyPort,
      receiveAddress: InternetAddress.loopbackIPv4,
      broadcastAddress: InternetAddress.loopbackIPv4,
      interfaceAddresses: () async => [InternetAddress.loopbackIPv4],
    );

Future<int> freeUdpPort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  socket.close();
  // Sockets close asynchronously; give the port time to be released.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return port;
}

/// Answers `3dsboot` with `boot3ds` sent to [replyPort], like a console.
Future<RawDatagramSocket> fakeConsole(int replyPort) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    for (var d = socket.receive(); d != null; d = socket.receive()) {
      if (ascii.decode(d.data, allowInvalid: true) == '3dsboot') {
        socket.send(ascii.encode('boot3ds'), d.address, replyPort);
      }
    }
  });
  return socket;
}

void main() {
  test('one console is listed by IP and exits 0', () async {
    final replyPort = await freeUdpPort();
    final console = await fakeConsole(replyPort);
    addTearDown(console.close);

    final r = await runDevices(
      loopbackClient(port: console.port, replyPort: replyPort),
      ['--target', 'ctr', '--wait', '0.5'],
    );

    expect(r.code, 0);
    expect(r.out, contains('Found 1 device:'));
    expect(r.out, contains('console  127.0.0.1'));
    expect(r.err, isEmpty);
  });

  test('no console prints netloader and firewall guidance, exits 0', () async {
    final r = await runDevices(loopbackClient(port: await freeUdpPort()), [
      '--wait',
      '0.3',
    ]);

    expect(r.code, 0);
    expect(r.out, contains('No devices found.'));
    expect(r.out, contains('Homebrew Launcher and press Y'));
    expect(r.out, contains('UDP port 17491'));
  });

  test('a busy reply port prints an error naming it and exits 1', () async {
    final blocker = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      reuseAddress: false,
    );
    addTearDown(blocker.close);

    final r = await runDevices(
      loopbackClient(port: await freeUdpPort(), replyPort: blocker.port),
      ['--wait', '0.3'],
    );

    expect(r.code, 1);
    expect(r.err, contains('UDP port ${blocker.port}'));
  });

  test(
    'Azahar found through DARTBREW_AZAHAR is listed with its path',
    () async {
      final dir = Directory.systemTemp.createTempSync('dartbrew-devices-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final azahar = File(p.join(dir.path, 'azahar.exe'))
        ..writeAsStringSync('');

      final r = await runDevices(
        loopbackClient(port: await freeUdpPort()),
        ['--wait', '0.3'],
        environment: {'DARTBREW_AZAHAR': azahar.path},
      );

      expect(r.code, 0);
      expect(r.out, contains('Found 1 device:'));
      expect(r.out, contains('azahar   ${azahar.path}'));
    },
  );

  test('Azahar found on PATH is listed', () async {
    final dir = Directory.systemTemp.createTempSync('dartbrew-devices-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final name = Platform.isWindows ? 'azahar.exe' : 'azahar';
    final azahar = File(p.join(dir.path, name))..writeAsStringSync('');

    final r = await runDevices(
      loopbackClient(port: await freeUdpPort()),
      ['--wait', '0.3'],
      environment: {'PATH': dir.path},
    );

    expect(r.code, 0);
    expect(r.out, contains('azahar   ${azahar.path}'));
  });

  test('an unknown --target is a usage error', () async {
    await expectLater(
      runDevices(loopbackClient(port: 1), ['--target', 'ntr']),
      throwsA(isA<UsageException>()),
    );
  });

  test('a non-numeric --wait is a usage error', () async {
    await expectLater(
      runDevices(loopbackClient(port: 1), ['--wait', 'soon']),
      throwsA(isA<UsageException>()),
    );
  });
}
