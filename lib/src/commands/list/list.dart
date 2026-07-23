import 'dart:io';

import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/filters.dart';

/// {@template ripple_cli.list_command}
/// `ripple list` — print packages matching discovery and filter criteria.
/// {@endtemplate}
class ListCommand extends RippleCommand {
  /// {@macro ripple_cli.list_command}
  ListCommand() {
    argParser
      ..addOption(
        groupOptionName,
        help: 'Only packages that belong to this named group from '
            'packages.groups.',
        valueHelp: 'name',
      )
      ..addMultiOption(
        matchOptionName,
        help: 'Only packages whose name matches this glob. May be passed '
            'multiple times (OR). Intersected with other filters.',
        valueHelp: 'glob',
      )
      ..addMultiOption(
        noMatchOptionName,
        help: 'Exclude packages whose name matches this glob. May be passed '
            'multiple times (OR). Negation of --$matchOptionName.',
        valueHelp: 'glob',
      )
      ..addMultiOption(
        dirExistsOptionName,
        help: 'Only packages that contain this relative directory. '
            'May be passed multiple times (AND).',
        valueHelp: 'path',
      )
      ..addMultiOption(
        fileExistsOptionName,
        help: 'Only packages that contain this relative file. '
            'May be passed multiple times (AND).',
        valueHelp: 'path',
      )
      ..addMultiOption(
        dependsOnOptionName,
        help: 'Only packages that declare this direct dependency '
            '(dependencies or dev_dependencies). May be passed multiple '
            'times (AND).',
        valueHelp: 'package',
      )
      ..addMultiOption(
        presetOptionName,
        help: 'AND a named packages.filtersPresets expression into the '
            'seed filters. May be passed multiple times.',
        valueHelp: 'name',
      );
  }

  /// Option name for `--group`.
  static const groupOptionName = 'group';

  /// Option name for `--match`.
  static const matchOptionName = 'match';

  /// Option name for `--no-match`.
  static const noMatchOptionName = 'no-match';

  /// Option name for `--dir-exists`.
  static const dirExistsOptionName = 'dir-exists';

  /// Option name for `--file-exists`.
  static const fileExistsOptionName = 'file-exists';

  /// Option name for `--depends-on`.
  static const dependsOnOptionName = 'depends-on';

  /// Option name for `--preset`.
  static const presetOptionName = 'preset';

  @override
  String get name => 'list';

  @override
  String get description =>
      'List packages matching include/exclude and filters.';

  @override
  Future<void> run() async {
    final config = loadRippleConfig();
    final packages = discoverPackages(config);
    final group = argResults!.option(groupOptionName);
    final criteria = PackageFilterCriteria.fromNameGlobs(
      match: argResults!.multiOption(matchOptionName),
      noMatch: argResults!.multiOption(noMatchOptionName),
      dirExists: argResults!.multiOption(dirExistsOptionName),
      fileExists: argResults!.multiOption(fileExistsOptionName),
      dependsOn: argResults!.multiOption(dependsOnOptionName),
      groups: group == null ? const [] : [group],
      presets: argResults!.multiOption(presetOptionName),
    ).withPackageNameSelection(
      ripplePackagesEnv: Platform.environment[ripplePackagesEnvVar],
    );

    final filtered = filterPackages(
      packages,
      config: config,
      criteria: criteria,
    );

    for (final package in filtered) {
      stdout.writeln(package.relativePath);
    }
  }
}
