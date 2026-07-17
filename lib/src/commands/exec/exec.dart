import 'dart:io';

import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/exec.dart';
import 'package:ripple_cli/src/filters.dart';

/// {@template ripple_cli.exec_command}
/// `ripple exec` — run an ad-hoc command once per matching package.
/// {@endtemplate}
class ExecCommand extends RippleCommand {
  /// {@macro ripple_cli.exec_command}
  ExecCommand() {
    argParser
      ..addFlag(
        failFastFlagName,
        help: 'Stop after the first package whose command exits non-zero.',
        negatable: false,
      )
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

  /// Flag name for `--fail-fast`.
  static const failFastFlagName = 'fail-fast';

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
  String get name => 'exec';

  @override
  String get description => 'Run an ad-hoc command once per matching package.';

  @override
  String get invocation =>
      '${runner.executableName} $name [filters…] [--fail-fast] -- <command…>';

  @override
  Future<void> run() async {
    final command = argResults!.rest;
    if (command.isEmpty) {
      usageException(
        'Missing command. Pass the executable and arguments after `--`.\n'
        'Example: ripple exec -- dart analyze .',
      );
    }

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

    final failFast = argResults!.flag(failFastFlagName);
    var firstFailure = 0;

    for (final package in filtered) {
      final vars = rippleEnvironment(
        rootPath: config.rootPath,
        package: package,
      );
      final resolvedCommand = substituteRippleVars(command, vars: vars);
      final result = await runProcess(
        resolvedCommand,
        workingDirectory: package.path,
        environment: vars,
      );

      if (result.exitCode != 0) {
        firstFailure = firstFailure == 0 ? result.exitCode : firstFailure;
        if (failFast) {
          exitCode = result.exitCode;
          return;
        }
      }
    }

    if (firstFailure != 0) {
      exitCode = firstFailure;
    }
  }
}
