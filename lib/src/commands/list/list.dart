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
      ..addOption(
        packagesOptionName,
        help: 'Comma-separated package names to include. Intersected with '
            '$ripplePackagesEnvVar and other filters.',
        valueHelp: 'a,b',
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
      );
  }

  /// Option name for `--group`.
  static const groupOptionName = 'group';

  /// Option name for `--packages`.
  static const packagesOptionName = 'packages';

  /// Option name for `--dir-exists`.
  static const dirExistsOptionName = 'dir-exists';

  /// Option name for `--file-exists`.
  static const fileExistsOptionName = 'file-exists';

  /// Option name for `--depends-on`.
  static const dependsOnOptionName = 'depends-on';

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
    final criteria = PackageFilterCriteria(
      dirExists: argResults!.multiOption(dirExistsOptionName),
      fileExists: argResults!.multiOption(fileExistsOptionName),
      dependsOn: argResults!.multiOption(dependsOnOptionName),
      groups: group == null ? const [] : [group],
    ).withPackageNameSelection(
      packages: parsePackageNameList(argResults!.option(packagesOptionName)),
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
