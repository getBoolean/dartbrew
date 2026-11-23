import 'dart:io';

import 'package:path/path.dart' as p;

/// A cache of immutable native build directories. A directory becomes visible
/// under its final key only after its contents have been built successfully.
final class NativeCache {
  final Directory root;

  NativeCache(this.root);

  factory NativeCache.forUser({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    String requiredVariable(String name) {
      final path = env[name];
      if (path == null || !p.isAbsolute(path)) {
        throw FileSystemException(
          'Cannot locate native cache: set $name to an absolute path.',
        );
      }
      return path;
    }

    final String location;
    if (Platform.isWindows) {
      location = requiredVariable('LOCALAPPDATA');
    } else if (Platform.isMacOS) {
      location = p.join(requiredVariable('HOME'), 'Library', 'Caches');
    } else {
      final xdg = env['XDG_CACHE_HOME'];
      location = xdg != null && p.isAbsolute(xdg)
          ? xdg
          : p.join(requiredVariable('HOME'), '.cache');
    }
    return NativeCache(Directory(p.join(location, 'dartbrew', 'native')));
  }

  /// Returns the entry for [key]. Concurrent builders publish one winner.
  Future<Directory> getOrBuild(
    String key,
    Future<void> Function(Directory work) build,
  ) async {
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'Expected a cache identifier');
    }
    final entry = Directory(p.join(root.path, key));
    if (entry.existsSync()) return entry;
    root.createSync(recursive: true);
    final work = root.createTempSync('.build-');
    try {
      await build(work);
      if (!entry.existsSync()) {
        try {
          work.renameSync(entry.path);
        } on FileSystemException {
          if (!entry.existsSync()) rethrow;
        }
      }
      return entry;
    } finally {
      if (work.existsSync()) work.deleteSync(recursive: true);
    }
  }
}
