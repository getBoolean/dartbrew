import 'dart:io';

/// The device a `run` or `test` command runs on, chosen with `-d`.
sealed class DeviceChoice {
  const DeviceChoice();

  /// The choice for the `-d` value [device]: `console` to discover a
  /// console, `azahar` for Azahar at [azaharPath] (or the default location
  /// when null), or a console's IPv4 address. Null when [device] is none of
  /// these.
  static DeviceChoice? tryParse(String device, {String? azaharPath}) =>
      switch (device) {
        'console' => const DiscoverConsole(),
        'azahar' => Azahar(azaharPath),
        _ => switch (InternetAddress.tryParse(device)) {
          final address? when address.type == InternetAddressType.IPv4 =>
            ConsoleAt(address),
          _ => null,
        },
      };
}

/// The console at [address].
final class ConsoleAt extends DeviceChoice {
  final InternetAddress address;

  const ConsoleAt(this.address);
}

/// The one console whose netloader answers discovery.
final class DiscoverConsole extends DeviceChoice {
  const DiscoverConsole();
}

/// The Azahar emulator on this host.
final class Azahar extends DeviceChoice {
  /// The `--azahar` executable path, or null to look in the default places.
  final String? executablePath;

  const Azahar(this.executablePath);
}
