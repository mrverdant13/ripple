import 'dart:io';

import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/exec.dart';
import 'package:ripple_cli/src/filters.dart';
import 'package:ripple_cli/src/scripts.dart';

/// {@template ripple_cli.run_command}
/// `ripple run` — execute a named script from ripple.yaml.
/// {@endtemplate}
class RunCommand extends RippleCommand {
  /// {@macro ripple_cli.run_command}
  RunCommand() {
    argParser
      ..addFlag(
        failFastFlagName,
        help: 'For exec: scripts, stop after the first package whose command '
            'exits non-zero.',
        negatable: false,
      )
      ..addOption(
        groupOptionName,
        help: 'Only packages that belong to this named group from '
            'packages.groups. Valid only for exec: scripts.',
        valueHelp: 'name',
      )
      ..addMultiOption(
        matchOptionName,
        help: 'Only packages whose name matches this glob. May be passed '
            'multiple times (OR). Intersected with script filters and other '
            'filters. Valid only for exec: scripts.',
        valueHelp: 'glob',
      )
      ..addMultiOption(
        noMatchOptionName,
        help: 'Exclude packages whose name matches this glob. May be passed '
            'multiple times (OR). Negation of --$matchOptionName. Valid only '
            'for exec: scripts.',
        valueHelp: 'glob',
      )
      ..addMultiOption(
        dirExistsOptionName,
        help: 'Only packages that contain this relative directory. '
            'May be passed multiple times (AND). Valid only for exec: scripts.',
        valueHelp: 'path',
      )
      ..addMultiOption(
        fileExistsOptionName,
        help: 'Only packages that contain this relative file. '
            'May be passed multiple times (AND). Valid only for exec: scripts.',
        valueHelp: 'path',
      )
      ..addMultiOption(
        dependsOnOptionName,
        help: 'Only packages that declare this direct dependency '
            '(dependencies or dev_dependencies). May be passed multiple '
            'times (AND). Valid only for exec: scripts.',
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

  /// Exit code used when the child process cannot be started.
  static const spawnFailureExitCode = 127;

  @override
  String get name => 'run';

  @override
  String get description => 'Execute a named script from ripple.yaml.';

  @override
  String get invocation =>
      '${runner.executableName} $name <script> [filters…] [--fail-fast]';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException(
        'Missing script name.\n'
        'Example: ripple run format.ci',
      );
    }
    if (rest.length > 1) {
      usageException(
        'Unexpected arguments: ${rest.skip(1).join(' ')}.\n'
        'Usage: ripple run <script> [filters…] [--fail-fast]',
      );
    }

    final scriptName = rest.first;
    final config = loadRippleConfig();
    final script = resolveScript(config, scriptName);

    final group = argResults!.option(groupOptionName);
    final cliCriteria = PackageFilterCriteria.fromNameGlobs(
      match: argResults!.multiOption(matchOptionName),
      noMatch: argResults!.multiOption(noMatchOptionName),
      dirExists: argResults!.multiOption(dirExistsOptionName),
      fileExists: argResults!.multiOption(fileExistsOptionName),
      dependsOn: argResults!.multiOption(dependsOnOptionName),
      groups: group == null ? const [] : [group],
    ).withPackageNameSelection(
      ripplePackagesEnv: Platform.environment[ripplePackagesEnvVar],
    );

    if (script.kind == ScriptKind.run) {
      if (!cliCriteria.isEmpty) {
        usageException(
          'Script "$scriptName" is a run: script and does not accept package '
          'filters.\n'
          'Remove --group, --match, --no-match, --dir-exists, --file-exists, '
          '--depends-on, and unset $ripplePackagesEnvVar.',
        );
      }

      final vars = rippleEnvironment(rootPath: config.rootPath);
      // run: scripts must not observe package-scoped RIPPLE_* vars, even when
      // those are present in the parent environment.
      final environment = Map<String, String>.from(Platform.environment)
        ..remove(ripplePackagePathEnvVar)
        ..remove(ripplePackageNameEnvVar)
        ..addAll(vars);
      for (final commandString in script.commands) {
        final command = parseScriptCommand(commandString);
        final resolvedCommand = substituteRippleVars(command, vars: vars);
        announceCommandStart(resolvedCommand);
        final result = await _runCommand(
          resolvedCommand,
          workingDirectory: config.rootPath,
          environment: environment,
          includeParentEnvironment: false,
        );
        announceCommandEnd(resolvedCommand, exitCode: result.exitCode);
        if (result.exitCode != 0) {
          exitCode = result.exitCode;
          return;
        }
      }
      return;
    }

    final scriptCriteria =
        PackageFilterCriteria.fromScriptFilters(script.filters);
    final criteria = scriptCriteria.intersect(cliCriteria);
    final packages = filterPackages(
      discoverPackages(config),
      config: config,
      criteria: criteria,
    );

    final failFast = argResults!.flag(failFastFlagName);
    var firstFailure = 0;

    for (final package in packages) {
      announcePackageScopeStart(package);
      final vars = rippleEnvironment(
        rootPath: config.rootPath,
        package: package,
      );
      var packageExitCode = 0;
      for (final commandString in script.commands) {
        final command = parseScriptCommand(commandString);
        final resolvedCommand = substituteRippleVars(command, vars: vars);
        announceCommandStart(resolvedCommand);
        final result = await _runCommand(
          resolvedCommand,
          workingDirectory: package.path,
          environment: vars,
        );
        announceCommandEnd(resolvedCommand, exitCode: result.exitCode);

        if (result.exitCode != 0) {
          packageExitCode = result.exitCode;
          firstFailure = firstFailure == 0 ? result.exitCode : firstFailure;
          if (failFast) {
            announcePackageScopeEnd(package, exitCode: packageExitCode);
            exitCode = result.exitCode;
            return;
          }
          break;
        }
      }
      announcePackageScopeEnd(package, exitCode: packageExitCode);
    }

    if (firstFailure != 0) {
      exitCode = firstFailure;
    }
  }

  Future<ProcessRunResult> _runCommand(
    List<String> command, {
    required String workingDirectory,
    required Map<String, String> environment,
    bool includeParentEnvironment = true,
  }) async {
    try {
      return await runProcess(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
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
