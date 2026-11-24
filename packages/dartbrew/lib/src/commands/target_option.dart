import 'package:args/args.dart';

/// Adds the `--target` option. CTR is the only build target, so the option
/// accepts `ctr` and rejects any other value as a usage error.
void addTargetOption(ArgParser parser) => parser.addOption(
  'target',
  help: 'The build target.',
  allowed: ['ctr'],
  allowedHelp: {'ctr': 'CTR homebrew applications (.3dsx).'},
  defaultsTo: 'ctr',
);
