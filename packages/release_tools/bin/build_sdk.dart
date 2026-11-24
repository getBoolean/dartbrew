import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:release_tools/src/build_identity.dart';
import 'package:release_tools/src/release_check.dart';
import 'package:release_tools/src/sdk_build.dart';
import 'package:release_tools/src/stage_runner.dart';

const _usage =
    'Configures and builds the patched Dart SDK for CTR, one component and '
    'mode per output directory. `identity` prints the build identity only.\n\n'
    'Usage: build_sdk identity|configure|build --component <c> --mode <m> '
    '[options]';

const _actions = ['identity', 'configure', 'build'];

Future<void> main(List<String> arguments) async {
  final repository = await repositoryRoot();
  final parser = ArgParser()
    ..addOption(
      'manifest',
      help: 'The pin table.',
      defaultsTo: p.join(repository, 'toolchain', 'versions.json'),
    )
    ..addOption(
      'profile',
      help: 'The CTR target profile.',
      defaultsTo: p.join(repository, 'toolchain', 'target-ctr.json'),
    )
    ..addOption(
      'source',
      help: 'The patched Dart SDK checkout.',
      defaultsTo: p.join(repository, 'third_party', 'dart-sdk'),
    )
    ..addOption(
      'component',
      allowed: [for (final component in SdkComponent.values) component.name],
      mandatory: true,
    )
    ..addOption(
      'mode',
      allowed: [for (final mode in BuildMode.values) mode.name],
      mandatory: true,
    )
    ..addOption(
      'output-root',
      help: 'Holds the output directories (default: <source>/out/ctr).',
    )
    ..addMultiOption('target', help: 'An explicit Ninja target; repeatable.')
    ..addOption(
      'jobs',
      help: 'The maximum concurrent Ninja jobs.',
      defaultsTo: '2',
    )
    ..addFlag(
      'check-includes',
      negatable: false,
      help: 'Also run upstream GN include ownership checks.',
    );
  final ArgResults options;
  final String action;
  final int jobs;
  try {
    options = parser.parse(arguments);
    if (options.rest case [final name] when _actions.contains(name)) {
      action = name;
    } else {
      throw ArgParserException('expected one of ${_actions.join(', ')}');
    }
    final parsedJobs = int.tryParse(options.option('jobs')!);
    if (parsedJobs == null || parsedJobs < 1) {
      throw ArgParserException('--jobs must be a positive integer');
    }
    jobs = parsedJobs;
  } on ArgParserException catch (error) {
    stderr.writeln('${error.message}\n\n$_usage\n${parser.usage}');
    exitCode = 64;
    return;
  }

  try {
    final manifestFile = File(options.option('manifest')!).absolute;
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
    final profile = TargetProfile.load(File(options.option('profile')!));
    final identity = BuildIdentity.of(
      manifest: manifest,
      profile: profile,
      component: SdkComponent.values.byName(options.option('component')!),
      mode: BuildMode.values.byName(options.option('mode')!),
    );
    if (action == 'identity') {
      stdout.writeln(jsonEncode(identity.toJson()));
      return;
    }
    final source = p.normalize(p.absolute(options.option('source')!));
    final request = SdkBuildRequest(
      source: source,
      manifestFile: manifestFile,
      manifest: manifest,
      profile: profile,
      identity: identity,
      bootstrapScript: File(p.join(repository, 'toolchain', 'bootstrap.py')),
      outputRoot: p.normalize(
        p.absolute(
          options.option('output-root') ?? p.join(source, 'out', 'ctr'),
        ),
      ),
      scope: SdkBuildScope.values.byName(action),
      targets: options.multiOption('target'),
      jobs: jobs,
      checkIncludes: options.flag('check-includes'),
    );
    final output = await buildSdk(
      request,
      runStage: StageRunner(request.outputDirectory).call,
      queryToolchain: queryInstalledToolchain,
    );
    stdout.writeln(jsonEncode({'output': output.path, ...identity.toJson()}));
  } on Exception catch (failure) {
    // SdkBuildFailure, ProcessException (a failed stage or a missing tool),
    // FileSystemException and FormatException each name what failed.
    stderr.writeln(failure);
    exitCode = 1;
  }
}
