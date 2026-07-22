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
      );
  }

  /// Flag name for `--fail-fast`.
  static const failFastFlagName = 'fail-fast';

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
    final criteria = PackageFilterCriteria.fromNameGlobs(
      match: argResults!.multiOption(matchOptionName),
      noMatch: argResults!.multiOption(noMatchOptionName),
      dirExists: argResults!.multiOption(dirExistsOptionName),
      fileExists: argResults!.multiOption(fileExistsOptionName),
      dependsOn: argResults!.multiOption(dependsOnOptionName),
      groups: group == null ? const [] : [group],
    ).withPackageNameSelection(
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
      announcePackageScopeStart(package);
      final vars = rippleEnvironment(
        rootPath: config.rootPath,
        package: package,
      );
      final resolvedCommand = substituteRippleVars(command, vars: vars);
      announceCommandStart(resolvedCommand);
      final result = await _runPackageCommand(
        resolvedCommand,
        workingDirectory: package.path,
        environment: vars,
      );
      announceCommandEnd(resolvedCommand, exitCode: result.exitCode);
      announcePackageScopeEnd(package, exitCode: result.exitCode);

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

  /// Exit code used when the child process cannot be started.
  static const spawnFailureExitCode = 127;

  Future<ProcessRunResult> _runPackageCommand(
    List<String> command, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    try {
      return await runProcess(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } on ProcessException catch (error) {
      final executable = command.isEmpty ? '(empty)' : command.first;
      stderr.writeln(
        'Failed to run "$executable" in $workingDirectory: ${error.message}',
      );
      return const ProcessRunResult(
        exitCode: spawnFailureExitCode,
        stdout: '',
        stderr: '',
      );
    }
  }
}
