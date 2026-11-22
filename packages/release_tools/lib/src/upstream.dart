import 'dart:convert';
import 'dart:io';

/// Fetches the JSON document at a URL; the one network capability the
/// upstream check needs.
///
/// Throws [UpstreamUnavailable] when the document cannot be fetched.
typedef FetchJson = Future<Object?> Function(Uri url);

/// An upstream source that could not be read.
final class UpstreamUnavailable implements Exception {
  final Uri url;
  final String reason;

  const UpstreamUnavailable(this.url, this.reason);

  @override
  String toString() => 'cannot read $url: $reason';
}

/// The Docker Hub repository of devkitPro's official devkitARM image.
const devkitArmImageRepository = 'devkitpro/devkitarm';

final _libctruReleasesUrl = Uri.parse(
  'https://api.github.com/repos/devkitPro/libctru/releases?per_page=20',
);
final _buildscriptsCommitsUrl = Uri.parse(
  'https://api.github.com/repos/devkitPro/buildscripts/commits?per_page=100',
);
final _imageTagsUrl = Uri.parse(
  'https://hub.docker.com/v2/repositories/$devkitArmImageRepository/tags'
  '?page_size=100&ordering=last_updated',
);
Uri _dartReleaseUrl(String channel) => Uri.parse(
  'https://storage.googleapis.com/dart-archive/channels/$channel/release/'
  'latest/VERSION',
);

/// devkitPro marks each devkitARM release with a `buildscripts` commit
/// titled like this; GitHub releases stopped being cut for devkitARM.
final _devkitArmReleaseCommit = RegExp(r'^devkitARM: release (\d+(?:\.\d+)?)');

/// devkitPro tags each image build with its date; `latest` is skipped.
final _datedImageTag = RegExp(r'^\d{8}$');

/// How long a connection to an upstream source may take before the check
/// reports it unavailable, so an unreachable host cannot stall a release.
const _connectionTimeout = Duration(seconds: 15);

/// An [HttpClient] for [httpFetchJson]; the caller closes it.
HttpClient upstreamHttpClient() =>
    HttpClient()..connectionTimeout = _connectionTimeout;

/// A live [FetchJson] over [client], which the caller owns and closes.
FetchJson httpFetchJson(HttpClient client) => (url) async {
  try {
    final request = await client.getUrl(url);
    request.headers
      ..set(HttpHeaders.userAgentHeader, 'release_tools')
      ..set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw UpstreamUnavailable(url, 'HTTP ${response.statusCode}: $body');
    }
    return jsonDecode(body);
  } on IOException catch (error) {
    throw UpstreamUnavailable(url, '$error');
  } on FormatException catch (error) {
    throw UpstreamUnavailable(url, 'not JSON: ${error.message}');
  }
};

/// The versions of the devkitPro image a release is built with: the
/// `container` entry of `toolchain/versions.json`.
final class ContainerPin {
  /// The image's index digest, such as `sha256:116a...`.
  final String digest;

  /// The `dkp-pacman` versions, such as `r68-1` and `2.7.0-1`.
  final String devkitArm;
  final String libctru;

  /// The version `arm-none-eabi-gcc -dumpversion` prints, such as `16.1.0`.
  final String gcc;

  const ContainerPin({
    required this.digest,
    required this.devkitArm,
    required this.libctru,
    required this.gcc,
  });

  /// The image reference stored in the pin table.
  String get image => '$devkitArmImageRepository@$digest';
}

/// The pins in `toolchain/versions.json` that `check_upstream` compares.
final class Pins {
  final ContainerPin container;
  final String dartVersion;

  const Pins({required this.container, required this.dartVersion});

  factory Pins.parse(String versionsJson) {
    final document = jsonDecode(versionsJson) as Map<String, Object?>;
    final container = document['container']! as Map<String, Object?>;
    final image = container['image']! as String;
    const prefix = '$devkitArmImageRepository@';
    if (!image.startsWith(prefix)) {
      throw FormatException('container image $image is not $prefix<digest>');
    }
    return Pins(
      container: ContainerPin(
        digest: image.substring(prefix.length),
        devkitArm: container['devkitARM']! as String,
        libctru: container['libctru']! as String,
        gcc: container['gcc']! as String,
      ),
      dartVersion:
          (document['dart']! as Map<String, Object?>)['version']! as String,
    );
  }
}

/// One dated build of the devkitARM image.
typedef ImageTag = ({String name, String digest});

/// A version an upstream published, and when.
typedef Release = ({String version, DateTime published});

/// The upstream state compared against the [Pins].
final class UpstreamReport {
  final Pins pins;
  final Release libctru;
  final Release devkitArm;

  /// The dated image tags, newest first.
  final List<ImageTag> images;
  final String dartChannel;
  final Release dart;

  const UpstreamReport({
    required this.pins,
    required this.libctru,
    required this.devkitArm,
    required this.images,
    required this.dartChannel,
    required this.dart,
  });

  ImageTag get newestImage => images.first;

  /// The pinned versions without pacman's package release suffix, as
  /// upstream names them: `2.7.0` and `r68`.
  String get _pinnedLibctru => _withoutPackageRelease(pins.container.libctru);
  String get _pinnedDevkitArm =>
      _withoutPackageRelease(pins.container.devkitArm);

  bool get isLibctruCurrent => _pinnedLibctru == libctru.version;

  bool get isDevkitArmCurrent => _pinnedDevkitArm == 'r${devkitArm.version}';

  bool get isImageCurrent => pins.container.digest == newestImage.digest;

  bool get isDartCurrent => pins.dartVersion == dart.version;

  int get updateCount => [
    isLibctruCurrent,
    isDevkitArmCurrent,
    isImageCurrent,
    isDartCurrent,
  ].where((isCurrent) => !isCurrent).length;

  /// The first image built on or after the day [release] was published.
  ///
  /// devkitPro publishes packages and the image before tagging the release
  /// commit, so an image pushed hours before the commit still contains it;
  /// image tags are compared by day. `update_upstream` reads the real
  /// versions from the image.
  ImageTag? imageContaining(Release release) {
    final day = _tagDay(release.published);
    ImageTag? first;
    for (final image in images) {
      if (image.name.compareTo(day) < 0) break;
      first = image;
    }
    return first;
  }

  /// The report as lines for a terminal.
  List<String> get lines => [
    updateCount == 0
        ? 'upstream: all pins current'
        : 'upstream: $updateCount update${updateCount == 1 ? '' : 's'} '
              'available',
    isLibctruCurrent
        ? '  libctru $_pinnedLibctru current'
        : '  libctru $_pinnedLibctru -> ${libctru.version} '
              '(${_releasedIn(libctru)})',
    isDevkitArmCurrent
        ? '  devkitARM $_pinnedDevkitArm current'
        : '  devkitARM $_pinnedDevkitArm -> r${devkitArm.version} '
              '(${_releasedIn(devkitArm)})',
    isImageCurrent
        ? '  $devkitArmImageRepository image ${pins.container.digest} current '
              '(tag ${newestImage.name})'
        : '  $devkitArmImageRepository image ${pins.container.digest} -> '
              '${newestImage.digest} (tag ${newestImage.name})',
    isDartCurrent
        ? '  dart ${pins.dartVersion} current ($dartChannel channel)'
        : '  dart ${pins.dartVersion} -> ${dart.version} '
              '($dartChannel channel, released ${_day(dart.published)})',
  ];

  String _releasedIn(Release release) {
    final image = imageContaining(release);
    final released = 'released ${_day(release.published)}';
    return image == null
        ? '$released; not in a $devkitArmImageRepository image yet'
        : '$released; in image ${image.digest} (tag ${image.name})';
  }
}

/// Reads every upstream named by [pins] through [fetch].
///
/// Throws [UpstreamUnavailable] naming the source that could not be read.
Future<UpstreamReport> checkUpstream(Pins pins, FetchJson fetch) async {
  final channel = dartChannel(pins.dartVersion);
  return UpstreamReport(
    pins: pins,
    libctru: await _newestLibctru(fetch),
    devkitArm: await _newestDevkitArm(fetch),
    images: await datedImageTags(fetch),
    dartChannel: channel,
    dart: await _newestDart(fetch, channel),
  );
}

/// The Dart release channel [version] belongs to.
String dartChannel(String version) => version.endsWith('.beta')
    ? 'beta'
    : version.endsWith('.dev')
    ? 'dev'
    : 'stable';

/// The dated devkitARM image tags on Docker Hub, newest first.
///
/// Throws [UpstreamUnavailable] when there are none.
Future<List<ImageTag>> datedImageTags(FetchJson fetch) async {
  final page = await fetch(_imageTagsUrl) as Map<String, Object?>;
  final tags = [
    for (final tag in page['results']! as List<Object?>)
      if (tag case {
        'name': final String name,
        'digest': final String digest,
      } when _datedImageTag.hasMatch(name))
        (name: name, digest: digest),
  ]..sort((a, b) => b.name.compareTo(a.name));
  if (tags.isEmpty) {
    throw UpstreamUnavailable(_imageTagsUrl, 'no dated image tags');
  }
  return tags;
}

Future<Release> _newestLibctru(FetchJson fetch) async {
  final releases = await fetch(_libctruReleasesUrl) as List<Object?>;
  for (final release in releases) {
    if (release case {
      'tag_name': final String tag,
      'draft': false,
      'prerelease': false,
      'published_at': final String published,
    }) {
      return (
        version: tag.startsWith('v') ? tag.substring(1) : tag,
        published: DateTime.parse(published),
      );
    }
  }
  throw UpstreamUnavailable(_libctruReleasesUrl, 'no published release');
}

Future<Release> _newestDevkitArm(FetchJson fetch) async {
  final commits = await fetch(_buildscriptsCommitsUrl) as List<Object?>;
  for (final commit in commits) {
    if (commit case {
      'commit': {
        'message': final String message,
        'committer': {'date': final String date},
      },
    }) {
      final release = _devkitArmReleaseCommit.firstMatch(message);
      if (release != null) {
        return (version: release[1]!, published: DateTime.parse(date));
      }
    }
  }
  throw UpstreamUnavailable(
    _buildscriptsCommitsUrl,
    'no "devkitARM: release N" commit in the latest 100 commits',
  );
}

Future<Release> _newestDart(FetchJson fetch, String channel) async {
  final url = _dartReleaseUrl(channel);
  final latest = await fetch(url) as Map<String, Object?>;
  return (
    version: latest['version']! as String,
    published: DateTime.parse(latest['date']! as String),
  );
}

/// `2.7.0-1` to `2.7.0`: the upstream version without pacman's package
/// release suffix.
String _withoutPackageRelease(String packageVersion) =>
    packageVersion.split('-').first;

String _day(DateTime time) =>
    time.toUtc().toIso8601String().substring(0, '2026-01-31'.length);

String _tagDay(DateTime time) => _day(time).replaceAll('-', '');

/// The shell command that prints an image's devkitARM and libctru package
/// versions, then its gcc version.
const _imageVersionsCommand =
    'dkp-pacman -Q devkitARM libctru && '
    '/opt/devkitpro/devkitARM/bin/arm-none-eabi-gcc -dumpversion';

/// Reads the versions inside the image [digest] with `docker run`.
///
/// Throws [ProcessException] when docker fails.
Future<ContainerPin> readImageVersions(String digest) async {
  final image = '$devkitArmImageRepository@$digest';
  final result = await Process.run('docker', [
    'run',
    '--rm',
    image,
    'sh',
    '-c',
    _imageVersionsCommand,
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'docker',
      ['run', '--rm', image],
      'could not read versions from $image: ${result.stderr}',
      result.exitCode,
    );
  }
  return parseImageVersions(digest, result.stdout as String);
}

/// The [ContainerPin] for [digest] from the output of the image versions
/// command: `devkitARM <version>`, `libctru <version>`, then gcc's version.
ContainerPin parseImageVersions(String digest, String output) {
  final packages = <String, String>{};
  String? gcc;
  for (final line in const LineSplitter().convert(output.trim())) {
    switch (line.trim().split(' ')) {
      case [final name, final version]:
        packages[name] = version;
      case [final version]:
        gcc = version;
    }
  }
  final devkitArm = packages['devkitARM'];
  final libctru = packages['libctru'];
  if (devkitArm == null || libctru == null || gcc == null) {
    throw FormatException('image versions output is incomplete', output);
  }
  return ContainerPin(
    digest: digest,
    devkitArm: devkitArm,
    libctru: libctru,
    gcc: gcc,
  );
}

/// [versionsJson] with its `container` entry set to [pin], every other byte
/// unchanged.
///
/// Throws [FormatException] when the entry or one of its fields does not
/// appear exactly once.
String rewriteContainerPin(String versionsJson, ContainerPin pin) {
  final entry = _single(RegExp(r'"container"\s*:\s*\{'), versionsJson);
  final end = versionsJson.indexOf('}', entry.end);
  if (end < 0) throw FormatException('container entry is not closed');
  var body = versionsJson.substring(entry.end, end);
  for (final (field, value) in [
    ('image', pin.image),
    ('devkitARM', pin.devkitArm),
    ('gcc', pin.gcc),
    ('libctru', pin.libctru),
  ]) {
    final match = _single(RegExp('("$field"\\s*:\\s*)"[^"]*"'), body);
    body = body.replaceRange(match.start, match.end, '${match[1]}"$value"');
  }
  return versionsJson.replaceRange(entry.end, end, body);
}

RegExpMatch _single(RegExp pattern, String text) {
  final matches = pattern.allMatches(text).toList();
  if (matches.length != 1) {
    throw FormatException(
      'expected one match of ${pattern.pattern}, found ${matches.length}',
    );
  }
  return matches.single;
}
