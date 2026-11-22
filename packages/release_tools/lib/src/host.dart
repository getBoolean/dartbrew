/// An operating system a dartbrew SDK runs on.
enum HostOs { windows, linux, macos }

/// A processor architecture a dartbrew SDK runs on.
enum HostArchitecture { x64, arm64 }

/// The hosts dartbrew releases an SDK for.
enum Host {
  windowsX64(HostOs.windows, HostArchitecture.x64, executableSuffix: '.exe'),
  linuxX64(HostOs.linux, HostArchitecture.x64),
  macosArm64(HostOs.macos, HostArchitecture.arm64);

  final HostOs os;
  final HostArchitecture architecture;

  /// Appended to an executable's name on this host.
  final String executableSuffix;

  const Host(this.os, this.architecture, {this.executableSuffix = ''});

  /// The host's name in archive names and records, such as `windows-x64`.
  String get id => '${os.name}-${architecture.name}';

  /// The host whose [id] is [id], or null when dartbrew does not support it.
  static Host? byId(String id) {
    for (final host in values) {
      if (host.id == id) return host;
    }
    return null;
  }
}
