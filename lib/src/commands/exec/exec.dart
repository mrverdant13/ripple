import 'dart:io';

import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/exec.dart';
import 'package:ripple_cli/src/filters.dart';
import 'package:ripple_cli/src/git_diff.dart';
import 'package:ripple_cli/src/replacements.dart';

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
      ..addFlag(
        quietFlagName,
        help: 'Omit banners and child stdout/stderr for packages that exit 0. '
            'Failed packages still print banners and output.',
        negatable: false,
      )
      ..addOption(
        concurrencyOptionName,
        help: 'Max packages to run at once (default: 1, sequential by '
            'relative path). Must be at least 1.',
        valueHelp: 'n',
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
      )
      ..addMultiOption(
        presetOptionName,
        help: 'AND a named packages.filtersPresets expression into the '
            'seed filters. May be passed multiple times.',
        valueHelp: 'name',
      )
      ..addOption(
        changedOptionName,
        help: 'Only packages changed per a git descriptor: since:<ref>, '
            'range:<A..B>, or workdir:<tree-ish>. Pass at most once.',
        valueHelp: 'descriptor',
      )
      ..addOption(
        overrideOptionName,
        help: 'Overlay descriptor: none, default, or file:<path>. '
            'Overrides $rippleOverrideEnvVar when both are set.',
        valueHelp: 'descriptor',
      );
  }

  /// Flag name for `--fail-fast`.
  static const failFastFlagName = 'fail-fast';

  /// Flag name for `--quiet`.
  static const quietFlagName = 'quiet';

  /// Option name for `--concurrency`.
  static const concurrencyOptionName = 'concurrency';

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

  /// Option name for `--changed`.
  static const changedOptionName = 'changed';

  @override
  String get name => 'exec';

  @override
  String get description => 'Run an ad-hoc command once per matching package.';

  @override
  String get invocation =>
      '${runner.executableName} $name [filters…] [--fail-fast] [--quiet] '
      '[--concurrency <n>] -- <command…>';

  @override
  Future<void> run() async {
    final command = argResults!.rest;
    if (command.isEmpty) {
      usageException(
        'Missing command. Pass the executable and arguments after `--`.\n'
        'Example: ripple exec -- dart analyze .',
      );
    }

    final config = loadRippleConfig(
      overlay: resolveOverlayDescriptor(
        cli: argResults!.wasParsed(overrideOptionName)
            ? argResults!.option(overrideOptionName)
            : null,
      ),
    );
    final packages = discoverPackages(config);
    final group = argResults!.option(groupOptionName);
    final changedRaw = argResults!.option(changedOptionName);
    String? changed;
    if (changedRaw != null) {
      final trimmed = changedRaw.trim();
      if (trimmed.isEmpty) {
        usageException(
          'Invalid --$changedOptionName: value must be a non-empty descriptor',
        );
      }
      parseChangedDescriptor(trimmed);
      changed = trimmed;
    }

    final criteria = PackageFilterCriteria.fromNameGlobs(
      match: argResults!.multiOption(matchOptionName),
      noMatch: argResults!.multiOption(noMatchOptionName),
      dirExists: argResults!.multiOption(dirExistsOptionName),
      fileExists: argResults!.multiOption(fileExistsOptionName),
      dependsOn: argResults!.multiOption(dependsOnOptionName),
      groups: group == null ? const [] : [group],
      presets: argResults!.multiOption(presetOptionName),
      changed: changed,
    ).withPackageNameSelection(
      ripplePackagesEnv: Platform.environment[ripplePackagesEnvVar],
    );

    final filtered = filterPackages(
      packages,
      config: config,
      criteria: criteria,
      packagesForChangedMapping: packages,
    );

    final failFast = argResults!.flag(failFastFlagName);
    final quiet = resolveQuietMode(cliQuiet: argResults!.flag(quietFlagName));
    final concurrency = _resolveCliConcurrency();
    final forwardStdin = concurrency == 1;

    final firstFailure = await runWithBoundedConcurrency<RipplePackage>(
      items: filtered,
      concurrency: concurrency,
      failFast: failFast,
      run: (package) async {
        final vars = rippleEnvironment(
          rootPath: config.rootPath,
          package: package,
        );
        final resolvedCommand = resolveCommandReplacements(
          command,
          replacements: resolveReplacements(
            config: config,
            package: package,
            workspacePackages: packages,
          ),
          vars: vars,
        );

        if (quiet) {
          final result = await _runPackageCommand(
            resolvedCommand,
            workingDirectory: package.path,
            environment: rippleChildEnvironment(vars),
            inheritStdio: false,
          );
          if (result.exitCode != 0) {
            announcePackageScopeStart(package);
            announceCommandStart(resolvedCommand, scopeLabel: package.name);
            writeCapturedChildOutput(
              capturedStdout: result.stdout,
              capturedStderr: result.stderr,
            );
            announceCommandEnd(
              resolvedCommand,
              scopeLabel: package.name,
              exitCode: result.exitCode,
            );
            announcePackageScopeEnd(package, exitCode: result.exitCode);
          }
          return result.exitCode;
        }

        announcePackageScopeStart(package);
        announceCommandStart(resolvedCommand, scopeLabel: package.name);
        final result = await _runPackageCommand(
          resolvedCommand,
          workingDirectory: package.path,
          environment: rippleChildEnvironment(vars),
          forwardStdin: forwardStdin,
        );
        announceCommandEnd(
          resolvedCommand,
          scopeLabel: package.name,
          exitCode: result.exitCode,
        );
        announcePackageScopeEnd(package, exitCode: result.exitCode);
        return result.exitCode;
      },
    );

    if (firstFailure != 0) {
      exitCode = firstFailure;
    }
  }

  int _resolveCliConcurrency() {
    if (!argResults!.wasParsed(concurrencyOptionName)) {
      return resolveConcurrency();
    }
    final raw = argResults!.option(concurrencyOptionName)!;
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      usageException(
        'Invalid --$concurrencyOptionName: expected an integer, got "$raw"',
      );
    }
    if (parsed < 1) {
      usageException(
        'Invalid --$concurrencyOptionName: must be at least 1',
      );
    }
    return resolveConcurrency(cliConcurrency: parsed);
  }

  /// Exit code used when the child process cannot be started.
  static const spawnFailureExitCode = 127;

  Future<ProcessRunResult> _runPackageCommand(
    List<String> command, {
    required String workingDirectory,
    required Map<String, String> environment,
    bool inheritStdio = true,
    bool forwardStdin = true,
  }) async {
    try {
      return await runProcess(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
        inheritStdio: inheritStdio,
        forwardStdin: forwardStdin,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (error) {
      final executable = command.isEmpty ? '(empty)' : command.first;
      final message =
          'Failed to run "$executable" in $workingDirectory: ${error.message}';
      if (inheritStdio) {
        stderr.writeln(message);
        return const ProcessRunResult(
          exitCode: spawnFailureExitCode,
          stdout: '',
          stderr: '',
        );
      }
      return ProcessRunResult(
        exitCode: spawnFailureExitCode,
        stdout: '',
        stderr: '$message\n',
      );
    }
  }
}
