import 'dart:io';

import 'package:path/path.dart' as p;

import '../../errors.dart';

/// The parts of the host the Azahar locator reads, so tests can supply their
/// own environment, operating system and working directory.
final class AzaharHost {
  final Map<String, String> environment;

  /// A [Platform.operatingSystem] value: `windows`, `linux` or `macos`.
  final String operatingSystem;

  /// The directory Azahar is started in; Linux and macOS look for a portable
  /// `user/` directory here.
  final String currentDirectory;

  const AzaharHost({
    required this.environment,
    required this.operatingSystem,
    required this.currentDirectory,
  });

  /// The real host.
  factory AzaharHost.current() => AzaharHost(
    environment: Platform.environment,
    operatingSystem: Platform.operatingSystem,
    currentDirectory: Directory.current.path,
  );

  bool get _windows => operatingSystem == 'windows';

  String? get _home => _windows
      ? environment['USERPROFILE'] ?? environment['HOME']
      : environment['HOME'];

  String _absolute(String path) =>
      p.normalize(p.isAbsolute(path) ? path : p.join(currentDirectory, path));
}

/// The exit code of a command that could not find Azahar or its SD card.
const _notFoundExitCode = 1;

/// The executable names searched for on `PATH`, per operating system.
List<String> _pathNames(String operatingSystem) => switch (operatingSystem) {
  'windows' => const ['azahar.exe'],
  'macos' => const ['azahar', 'Azahar.app/Contents/MacOS/azahar'],
  _ => const ['azahar', 'azahar.AppImage'],
};

/// The Azahar executable: [path] (from `--azahar`), then the
/// `DARTBREW_AZAHAR` environment variable, then the first per-OS name found
/// on `PATH`.
///
/// Throws a [DartbrewException] naming `--azahar` and `DARTBREW_AZAHAR` when
/// none is found, or when the explicitly named file does not exist.
String locateAzahar(AzaharHost host, {String? path}) {
  const hint =
      'Pass its path with --azahar <path> or set the DARTBREW_AZAHAR '
      'environment variable.';
  if (path != null) {
    final executable = host._absolute(path);
    if (File(executable).existsSync()) return executable;
    throw DartbrewException(
      _notFoundExitCode,
      'No Azahar executable at $executable (--azahar).',
    );
  }
  if (host.environment['DARTBREW_AZAHAR'] case final named?
      when named.isNotEmpty) {
    final executable = host._absolute(named);
    if (File(executable).existsSync()) return executable;
    throw DartbrewException(
      _notFoundExitCode,
      'No Azahar executable at $executable (DARTBREW_AZAHAR). $hint',
    );
  }
  final separator = host._windows ? ';' : ':';
  final search = host.environment['PATH'] ?? host.environment['Path'] ?? '';
  for (final directory in search.split(separator)) {
    if (directory.isEmpty) continue;
    for (final name in _pathNames(host.operatingSystem)) {
      final candidate = p.join(directory, name);
      if (File(candidate).existsSync()) return host._absolute(candidate);
    }
  }
  throw DartbrewException(
    _notFoundExitCode,
    'Azahar was not found on PATH. $hint',
  );
}

/// The Azahar executable [locateAzahar] would pick without `--azahar`, or
/// null when there is none.
String? findAzahar(AzaharHost host) {
  try {
    return locateAzahar(host);
  } on DartbrewException {
    return null;
  }
}

/// Azahar's emulated SD card directory for [executable].
///
/// `DARTBREW_AZAHAR_SDMC` wins. Otherwise Azahar's user directory is a
/// portable `user/` next to the executable (Windows) or in the working
/// directory (Linux, macOS) when it exists, else the per-OS default. A
/// `qt-config.ini` (the Qt frontend dartbrew launches) or `emu.ini` in that
/// user directory's `config/` with `[Data Storage] use_custom_storage=true`
/// points the card at its `sdmc_directory`, `qt-config.ini` first; otherwise
/// the card is the user directory's `sdmc/`.
///
/// Throws a [DartbrewException] when the home directory is unknown.
String azaharSdmc(String executable, AzaharHost host) {
  if (host.environment['DARTBREW_AZAHAR_SDMC'] case final sdmc?
      when sdmc.isNotEmpty) {
    return host._absolute(sdmc);
  }
  final portable = p.join(
    host._windows ? p.dirname(executable) : host.currentDirectory,
    'user',
  );
  final user = Directory(portable).existsSync()
      ? portable
      : _defaultUserDirectory(host);
  for (final name in const ['qt-config.ini', 'emu.ini']) {
    if (_customSdmc(File(p.join(user, 'config', name))) case final custom?) {
      return custom;
    }
  }
  return p.join(user, 'sdmc');
}

String _defaultUserDirectory(AzaharHost host) {
  String home() =>
      host._home ??
      (throw const DartbrewException(
        _notFoundExitCode,
        'Could not find your home directory to locate Azahar\'s SD card. '
        'Set DARTBREW_AZAHAR_SDMC to its sdmc directory.',
      ));
  return switch (host.operatingSystem) {
    'windows' => p.join(
      host.environment['APPDATA'] ?? p.join(home(), 'AppData', 'Roaming'),
      'Azahar',
    ),
    'macos' => p.join(home(), 'Library', 'Application Support', 'Azahar'),
    _ => p.join(
      host.environment['XDG_DATA_HOME'] ?? p.join(home(), '.local', 'share'),
      'azahar-emu',
    ),
  };
}

/// The `sdmc_directory` of [config] when its `[Data Storage]` section turns
/// on `use_custom_storage`, else null. Qt's settings files spell the section
/// `[Data%20Storage]`.
String? _customSdmc(File config) {
  if (!config.existsSync()) return null;
  String? section;
  var custom = false;
  String? sdmc;
  for (final raw in config.readAsLinesSync()) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line
          .substring(1, line.length - 1)
          .trim()
          .replaceAll('%20', ' ');
      continue;
    }
    if (section != 'Data Storage') continue;
    final equals = line.indexOf('=');
    if (equals < 0) continue;
    final key = line.substring(0, equals).trim();
    var value = line.substring(equals + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (key == 'use_custom_storage') custom = value == 'true';
    if (key == 'sdmc_directory') sdmc = value;
  }
  return custom && sdmc != null && sdmc.isNotEmpty ? sdmc : null;
}
