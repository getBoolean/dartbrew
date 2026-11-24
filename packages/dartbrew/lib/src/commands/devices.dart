import 'dart:io';

import 'package:args/command_runner.dart';

import '../device/transport.dart';
import '../errors.dart';
import '../targets/ctr/azahar.dart';
import '../targets/ctr/netloader.dart';
import 'target_option.dart';

/// The `devices` command, ready for `CommandRunner.addCommand`.
///
/// [transport] creates the network transport that finds consoles; the
/// netloader client by default. [azaharHost] is where Azahar is looked for;
/// the real host by default. Output goes to [out] and errors to [err],
/// defaulting to stdout and stderr.
Command<int> devicesCommand({
  DeviceTransport Function() transport = NetloaderClient.new,
  AzaharHost? azaharHost,
  StringSink? out,
  StringSink? err,
}) => _DevicesCommand(
  transport,
  azaharHost ?? AzaharHost.current(),
  out ?? stdout,
  err ?? stderr,
);

/// One reachable device: what it is and how to address it with `-d`.
typedef _Device = ({String kind, String id});

class _DevicesCommand extends Command<int> {
  final DeviceTransport Function() _transport;
  final AzaharHost _azaharHost;
  final StringSink _out;
  final StringSink _err;

  _DevicesCommand(this._transport, this._azaharHost, this._out, this._err) {
    addTargetOption(argParser);
    argParser.addOption(
      'wait',
      help: 'Seconds to wait for consoles to answer.',
      defaultsTo: '3',
    );
  }

  @override
  String get name => 'devices';

  @override
  String get description => 'List the devices reachable right now.';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isNotEmpty) {
      throw UsageException('devices takes no arguments.', usage);
    }
    final seconds = num.tryParse(args.option('wait')!);
    if (seconds == null || seconds < 0) {
      throw UsageException('--wait must be a number of seconds.', usage);
    }
    final wait = Duration(milliseconds: (seconds * 1000).round());

    final List<InternetAddress> consoles;
    try {
      consoles = await _transport().discover(wait).toList();
    } on DartbrewException catch (error) {
      _err.writeln(error.message);
      return error.exitCode;
    }
    final azahar = findAzahar(_azaharHost);
    final devices = <_Device>[
      for (final console in consoles) (kind: 'console', id: console.address),
      if (azahar != null) (kind: 'azahar', id: azahar),
    ];

    if (devices.isEmpty) {
      _out.writeln(
        'No devices found.\n'
        'To use a console, open Homebrew Launcher and press Y to start the '
        'netloader, then run "dartbrew devices" again.\n'
        'If the console shows the netloader waiting and is still not found, '
        'allow UDP port $netloaderPort through this computer\'s firewall.',
      );
      return 0;
    }
    _out.writeln(
      'Found ${devices.length} ${devices.length == 1 ? 'device' : 'devices'}:',
    );
    for (final device in devices) {
      _out.writeln('  ${device.kind.padRight(8)} ${device.id}');
    }
    return 0;
  }
}
