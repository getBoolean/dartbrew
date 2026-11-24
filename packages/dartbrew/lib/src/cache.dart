import 'dart:io';

import 'package:path/path.dart' as p;
import 'cache_lock.dart';

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

  /// Returns the entry for [key], allowing only one active builder per key.
  /// Checks cancellation while waiting and immediately before publication.
  Future<Directory> getOrBuild(
    String key,
    Future<void> Function(Directory work) build, {
    void Function()? checkCancelled,
  }) async {
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'Expected a cache identifier');
    }
    final entry = Directory(p.join(root.path, key));
    checkCancelled?.call();
    if (entry.existsSync()) return entry;
    final lockDir = Directory(p.join(root.path, '.locks'))
      ..createSync(recursive: true);
    final file = File(p.join(lockDir.path, key));
    if (!Platform.isWindows && !file.existsSync()) file.createSync();
    return withCacheLock(file, checkCancelled, () async {
      if (entry.existsSync()) return entry;
      final prefix = '.build-$key-';
      // The OS may have released the previous owner's lock on a hard
      // termination. Only that key's unpublished directories are ours.
      for (final old in root.listSync(followLinks: false)) {
        if (old is Directory && p.basename(old.path).startsWith(prefix)) {
          old.deleteSync(recursive: true);
        }
      }
      final work = root.createTempSync(prefix);
      try {
        await build(work);
        checkCancelled?.call();
        work.renameSync(entry.path);
        return entry;
      } finally {
        if (work.existsSync()) work.deleteSync(recursive: true);
      }
    });
  }
}
