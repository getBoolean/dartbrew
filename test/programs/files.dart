// dart:io files and directories on the SD card (U6). Every line is
// deterministic: paths are relative to the app folder or fixed SD card paths.
import 'dart:io';

String _type(FileSystemEntity entity) => switch (entity) {
  Directory() => 'dir',
  File() => 'file',
  _ => 'other',
};

Future<void> main() async {
  // Directory.systemTemp is cleared at every start; a previous run leaves a
  // file in it below.
  final temp = Directory.systemTemp;
  print('temp:${temp.path}:${temp.existsSync()}:${temp.listSync().isEmpty}');
  print('cwd:${Directory.current.isAbsolute}');

  final root = Directory('files_fixture');
  if (root.existsSync()) root.deleteSync(recursive: true);
  root.createSync();

  // Write, read back, append and truncate.
  final file = File('files_fixture/data.txt');
  file.writeAsStringSync('hello');
  print('write:${file.readAsStringSync()}:${file.lengthSync()}');
  file.writeAsStringSync(' world', mode: FileMode.append);
  print('append:${file.readAsStringSync()}:${file.lengthSync()}');
  final truncating = file.openSync(mode: FileMode.append);
  truncating.truncateSync(5);
  truncating.closeSync();
  print('truncate:${file.readAsStringSync()}:${file.lengthSync()}');

  // A recursive listing reports every entry with its type.
  Directory('files_fixture/tree/a/b').createSync(recursive: true);
  File('files_fixture/tree/a/one.txt').writeAsStringSync('1');
  File('files_fixture/tree/a/b/two.txt').writeAsStringSync('2');
  final listed = [
    for (final entity in Directory(
      'files_fixture/tree',
    ).listSync(recursive: true))
      '${_type(entity)}:${entity.path}',
  ]..sort();
  for (final entry in listed) {
    print('list:$entry');
  }

  // Rename across folders, then a recursive delete leaves nothing behind.
  final moved = File('files_fixture/tree/a/one.txt')
      .renameSync('files_fixture/tree/a/b/moved.txt');
  print(
    'rename:${moved.readAsStringSync()}:'
    '${File('files_fixture/tree/a/one.txt').existsSync()}',
  );
  Directory('files_fixture/tree').deleteSync(recursive: true);
  print('delete:${Directory('files_fixture/tree').existsSync()}');

  // Missing paths.
  print('stat:${FileStat.statSync('files_fixture/missing').type}');
  try {
    File('/dartbrew_missing_file.txt').readAsStringSync();
    print('missing:read');
  } on PathNotFoundException {
    print('missing:PathNotFoundException');
  }

  // Links and watching are unsupported and say so.
  try {
    Link('files_fixture/link').createSync('files_fixture/data.txt');
    print('link:created');
  } on FileSystemException catch (error) {
    print('link:${error.osError?.message}');
  }
  try {
    final subscription = root.watch().listen((_) {});
    await subscription.cancel();
    print('watch:listened');
  } on FileSystemException catch (error) {
    print('watch:${error.message}');
  }

  // RandomAccessFile reads and writes at offset 0, mid-file and the end.
  final bytes = File('files_fixture/random.txt')
    ..writeAsStringSync('0123456789');
  final random = bytes.openSync(mode: FileMode.append);
  for (final (position, text) in [(0, 'A'), (5, 'M'), (10, 'Z')]) {
    random.setPositionSync(position);
    random.writeStringSync(text);
  }
  final read = [
    for (final position in [0, 5, 10])
      String.fromCharCodes((random..setPositionSync(position)).readSync(1)),
  ];
  print('random:${read.join()}:${random.lengthSync()}');
  random.closeSync();
  print('random:${bytes.readAsStringSync()}');

  // "sdmc:/3ds/..." and "/3ds/..." are the same file.
  Directory('/3ds').createSync(recursive: true);
  const sdmc = 'sdmc:/3ds/dartbrew_files_fixture.txt';
  File(sdmc).writeAsStringSync('same');
  final slash = File('/3ds/dartbrew_files_fixture.txt');
  print(
    'sdmc:${slash.readAsStringSync()}:'
    '${FileSystemEntity.identicalSync(sdmc, slash.path)}:'
    '${File(sdmc).absolute.path}',
  );
  slash.deleteSync();

  // Uri.base follows Directory.current, as on other platforms.
  print(
    'uri-base:${Uri.base.resolve('x').toFilePath() == File('x').absolute.path}',
  );

  // 40 concurrent asynchronous reads all complete.
  final shared = File('files_fixture/shared.txt')
    ..writeAsStringSync('x' * 1000);
  final reads = await Future.wait([
    for (var i = 0; i < 40; i++) shared.readAsString(),
  ]);
  print('concurrent:${reads.length}:${reads.every((r) => r.length == 1000)}');

  root.deleteSync(recursive: true);
  print('cleanup:${root.existsSync()}');
  File('${temp.path}/left_by_files_fixture.txt').writeAsStringSync('x');
}
