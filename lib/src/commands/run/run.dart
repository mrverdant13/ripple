import 'dart:io';

import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/exec.dart';
import 'package:ripple_cli/src/filters.dart';
import 'package:ripple_cli/src/git_diff.dart';
import 'package:ripple_cli/src/graph.dart';
import 'package:ripple_cli/src/replacements.dart';
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
      ..addFlag(
        quietFlagName,
        help: 'Omit banners and child stdout/stderr for successful packages '
            '(exec:) or successful root steps (run:). Failed packages or '
            'steps still print banners and output. Overrides script quiet: '
            'when both are set.',
        negatable: false,
      )
      ..addOption(
        concurrencyOptionName,
        help: 'For exec: scripts, max packages to run at once (default: 1). '
            'Must be at least 1. Overrides script concurrency: when both are '
            'set. Rejected for run: scripts.',
        valueHelp: 'n',
      )
      ..addOption(
        orderOptionName,
        help: 'For exec: scripts, package scheduling: path (default) or '
            'layers. Overrides script order: when both are set. Rejected for '
            'run: scripts.',
        valueHelp: 'path|layers',
        allowed: packageExecOrderValues.keys,
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
        noDirExistsOptionName,
        help: 'Only packages that do not contain this relative directory. '
            'May be passed multiple times (AND). Valid only for exec: scripts.',
        valueHelp: 'path',
      )
      ..addMultiOption(
        noFileExistsOptionName,
        help: 'Only packages that do not contain this relative file. '
            'May be passed multiple times (AND). Valid only for exec: scripts.',
        valueHelp: 'path',
      )
      ..addMultiOption(
        dependsOnOptionName,
        help: 'Only packages that declare this direct dependency '
            '(dependencies or dev_dependencies). May be passed multiple '
            'times (AND). Valid only for exec: scripts.',
        valueHelp: 'package',
      )
      ..addMultiOption(
        presetOptionName,
        help: 'AND a named packages.filtersPresets expression into the '
            'seed filters. May be passed multiple times. Valid only for '
            'exec: scripts.',
        valueHelp: 'name',
      )
      ..addMultiOption(
        changedOptionName,
        help: 'Only packages changed per a git descriptor: since:<ref>, '
            'range:<A..B>, workdir:<tree-ish>, or bare since-latest-tag / '
            'staged / unstaged / untracked. May be passed multiple times '
            '(union of path sets). Valid only for exec: scripts.',
        valueHelp: 'descriptor',
      )
      ..addOption(
        sdkOptionName,
        help: 'Only packages whose pubspec environment matches this SDK. '
            'flutter means environment.flutter is set; dart means it is '
            'absent. Pass at most once. Valid only for exec: scripts.',
        valueHelp: 'dart|flutter',
        allowed: packageSdkValues,
      )
      ..addOption(
        pubGetOptionName,
        help: 'Only packages whose dart pub get status matches: '
            'start-missing, start-resolved, live-missing, or live-resolved. '
            'Valid only for exec: scripts.',
        valueHelp: 'value',
        allowed: pubGetCliValues,
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

  /// Option name for `--order`.
  static const orderOptionName = 'order';

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

  /// Option name for `--no-dir-exists`.
  static const noDirExistsOptionName = 'no-dir-exists';

  /// Option name for `--no-file-exists`.
  static const noFileExistsOptionName = 'no-file-exists';

  /// Option name for `--depends-on`.
  static const dependsOnOptionName = 'depends-on';

  /// Option name for `--preset`.
  static const presetOptionName = 'preset';

  /// Option name for `--changed`.
  static const changedOptionName = 'changed';

  /// Option name for `--sdk`.
  static const sdkOptionName = 'sdk';

  /// Option name for `--pub-get`.
  static const pubGetOptionName = 'pub-get';

  /// Exit code used when the child process cannot be started.
  static const spawnFailureExitCode = 127;

  @override
  String get name => 'run';

  @override
  String get description => 'Execute a named script from ripple.yaml.';

  @override
  String get invocation =>
      '${runner.executableName} $name <script> [filters…] [--fail-fast] '
      '[--quiet] [--concurrency <n>] [--order path|layers]';

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
        'Usage: ripple run <script> [filters…] [--fail-fast] [--quiet] '
        '[--concurrency <n>] [--order path|layers]',
      );
    }

    final scriptName = rest.first;
    final config = loadRippleConfig(
      overlay: resolveOverlayDescriptor(
        cli: argResults!.wasParsed(overrideOptionName)
            ? argResults!.option(overrideOptionName)
            : null,
      ),
    );
    final script = resolveScript(config, scriptName);

    final group = argResults!.option(groupOptionName);
    final changed = <String>[];
    for (final raw in argResults!.multiOption(changedOptionName)) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        usageException(
          'Invalid --$changedOptionName: value must be a non-empty descriptor',
        );
      }
      parseChangedDescriptor(trimmed);
      changed.add(trimmed);
    }

    final pubGetRaw = argResults!.option(pubGetOptionName);
    FilterPubGet? pubGet;
    if (pubGetRaw != null) {
      final parsed = parsePubGetCliValue(pubGetRaw);
      pubGet = FilterPubGet(state: parsed.state, asOf: parsed.asOf);
    }

    final cliCriteria = PackageFilterCriteria.fromNameGlobs(
      match: argResults!.multiOption(matchOptionName),
      noMatch: argResults!.multiOption(noMatchOptionName),
      dirExists: argResults!.multiOption(dirExistsOptionName),
      fileExists: argResults!.multiOption(fileExistsOptionName),
      noDirExists: argResults!.multiOption(noDirExistsOptionName),
      noFileExists: argResults!.multiOption(noFileExistsOptionName),
      dependsOn: argResults!.multiOption(dependsOnOptionName),
      groups: group == null ? const [] : [group],
      presets: argResults!.multiOption(presetOptionName),
      changed: changed,
      sdk: argResults!.option(sdkOptionName),
      pubGet: pubGet,
    ).withPackageNameSelection(
      ripplePackagesEnv: Platform.environment[ripplePackagesEnvVar],
    );

    final quiet = resolveQuietMode(
      cliQuiet: argResults!.flag(quietFlagName),
      scriptQuiet: script.quiet,
    );
    final cliConcurrencyParsed = argResults!.wasParsed(concurrencyOptionName);
    final cliOrderParsed = argResults!.wasParsed(orderOptionName);

    if (script.kind == ScriptKind.run) {
      if (cliConcurrencyParsed) {
        usageException(
          'Script "$scriptName" is a run: script and does not accept '
          '--$concurrencyOptionName.\n'
          'Remove --$concurrencyOptionName.',
        );
      }
      if (cliOrderParsed) {
        usageException(
          'Script "$scriptName" is a run: script and does not accept '
          '--$orderOptionName.\n'
          'Remove --$orderOptionName.',
        );
      }
      if (!cliCriteria.isEmpty) {
        usageException(
          'Script "$scriptName" is a run: script and does not accept package '
          'filters.\n'
          'Remove --group, --match, --no-match, --dir-exists, --file-exists, '
          '--no-dir-exists, --no-file-exists, --depends-on, --preset, '
          '--changed, --sdk, --pub-get, and unset '
          '$ripplePackagesEnvVar.',
        );
      }

      final vars = rippleEnvironment(rootPath: config.rootPath);
      // run: scripts must not observe package-scoped RIPPLE_* vars, even when
      // those are present in the parent environment.
      final environment = rippleChildEnvironment(vars);
      if (!quiet) {
        announceRootScopeStart();
      }
      for (final commandString in script.commands) {
        final command = parseScriptCommand(commandString);
        final resolvedCommand = resolveCommandReplacements(
          command,
          replacements: resolveReplacements(config: config),
          vars: vars,
        );
        if (quiet) {
          final result = await _runCommand(
            resolvedCommand,
            workingDirectory: config.rootPath,
            environment: environment,
            includeParentEnvironment: false,
            inheritStdio: false,
          );
          if (result.exitCode != 0) {
            announceRootScopeStart();
            announceCommandStart(resolvedCommand, scopeLabel: rootScopeLabel);
            writeCapturedChildOutput(
              capturedStdout: result.stdout,
              capturedStderr: result.stderr,
            );
            announceCommandEnd(
              resolvedCommand,
              scopeLabel: rootScopeLabel,
              exitCode: result.exitCode,
            );
            announceRootScopeEnd(exitCode: result.exitCode);
            exitCode = result.exitCode;
            return;
          }
          continue;
        }

        announceCommandStart(resolvedCommand, scopeLabel: rootScopeLabel);
        final result = await _runCommand(
          resolvedCommand,
          workingDirectory: config.rootPath,
          environment: environment,
          includeParentEnvironment: false,
        );
        announceCommandEnd(
          resolvedCommand,
          scopeLabel: rootScopeLabel,
          exitCode: result.exitCode,
        );
        if (result.exitCode != 0) {
          announceRootScopeEnd(exitCode: result.exitCode);
          exitCode = result.exitCode;
          return;
        }
      }
      if (!quiet) {
        announceRootScopeEnd(exitCode: 0);
      }
      return;
    }

    final scriptCriteria =
        PackageFilterCriteria.fromScriptFilters(script.filters);
    final criteria = scriptCriteria.intersect(cliCriteria);
    final discovered = discoverPackages(config);
    final pubGetContext = buildPubGetMatchContext(
      rippleRootPath: config.rootPath,
      packages: discovered,
    );
    final recheckLivePubGet =
        filterExpressionHasLivePubGet(criteria.expression) ||
            filterExpressionHasLivePubGet(
              script.dependentsFilters?.expression,
            ) ||
            filterExpressionHasLivePubGet(
              script.dependenciesFilters?.expression,
            );
    final selection = selectPackages(
      discovered,
      config: config,
      criteria: criteria,
      dependentsFilters: script.dependentsFilters,
      dependenciesFilters: script.dependenciesFilters,
      pubGetContext: pubGetContext,
    );
    final packages = selection.packages;

    final failFast = argResults!.flag(failFastFlagName);
    final concurrency = _resolveCliConcurrency(script.concurrency);
    final order = _resolveCliOrder(script.order);
    final forwardStdin = concurrency == 1;
    final graph = WorkspaceGraph.fromPackages(discovered);

    final firstFailure = await runPackagesInOrder(
      packages: packages,
      order: order,
      graph: graph,
      concurrency: concurrency,
      failFast: failFast,
      run: (package) async {
        if (recheckLivePubGet &&
            !packageStillMatchesLivePubGet(
              package: package,
              config: config,
              seedCriteria: criteria,
              selection: selection,
              dependentsFilters: script.dependentsFilters,
              dependenciesFilters: script.dependenciesFilters,
              pubGetContext: pubGetContext,
              packagesForChangedMapping: discovered,
            )) {
          return 0;
        }

        final vars = rippleEnvironment(
          rootPath: config.rootPath,
          package: package,
        );
        if (quiet) {
          final stepRecords = <_QuietStepRecord>[];
          var packageExitCode = 0;

          for (final commandString in script.commands) {
            final command = parseScriptCommand(commandString);
            final resolvedCommand = resolveCommandReplacements(
              command,
              replacements: resolveReplacements(
                config: config,
                package: package,
                workspacePackages: discovered,
              ),
              vars: vars,
            );
            final result = await _runCommand(
              resolvedCommand,
              workingDirectory: package.path,
              environment: rippleChildEnvironment(vars),
              includeParentEnvironment: false,
              inheritStdio: false,
            );
            stepRecords.add(
              _QuietStepRecord(
                command: resolvedCommand,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
              ),
            );
            if (result.exitCode != 0) {
              packageExitCode = result.exitCode;
              break;
            }
          }

          if (packageExitCode != 0) {
            announcePackageScopeStart(package);
            for (final step in stepRecords) {
              announceCommandStart(step.command, scopeLabel: package.name);
              writeCapturedChildOutput(
                capturedStdout: step.stdout,
                capturedStderr: step.stderr,
              );
              announceCommandEnd(
                step.command,
                scopeLabel: package.name,
                exitCode: step.exitCode,
              );
            }
            announcePackageScopeEnd(package, exitCode: packageExitCode);
          }
          return packageExitCode;
        }

        announcePackageScopeStart(package);
        var packageExitCode = 0;
        for (final commandString in script.commands) {
          final command = parseScriptCommand(commandString);
          final resolvedCommand = resolveCommandReplacements(
            command,
            replacements: resolveReplacements(
              config: config,
              package: package,
              workspacePackages: discovered,
            ),
            vars: vars,
          );
          announceCommandStart(resolvedCommand, scopeLabel: package.name);
          final result = await _runCommand(
            resolvedCommand,
            workingDirectory: package.path,
            environment: rippleChildEnvironment(vars),
            includeParentEnvironment: false,
            forwardStdin: forwardStdin,
          );
          announceCommandEnd(
            resolvedCommand,
            scopeLabel: package.name,
            exitCode: result.exitCode,
          );

          if (result.exitCode != 0) {
            packageExitCode = result.exitCode;
            break;
          }
        }
        announcePackageScopeEnd(package, exitCode: packageExitCode);
        return packageExitCode;
      },
    );

    if (firstFailure != 0) {
      exitCode = firstFailure;
    }
  }

  int _resolveCliConcurrency(int? scriptConcurrency) {
    if (!argResults!.wasParsed(concurrencyOptionName)) {
      return resolveConcurrency(scriptConcurrency: scriptConcurrency);
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
    return resolveConcurrency(
      cliConcurrency: parsed,
      scriptConcurrency: scriptConcurrency,
    );
  }

  PackageExecOrder _resolveCliOrder(String? scriptOrderRaw) {
    final scriptOrder = scriptOrderRaw == null
        ? null
        : tryParsePackageExecOrder(scriptOrderRaw);
    if (!argResults!.wasParsed(orderOptionName)) {
      return resolvePackageExecOrder(scriptOrder: scriptOrder);
    }
    final raw = argResults!.option(orderOptionName)!;
    final parsed = tryParsePackageExecOrder(raw);
    if (parsed == null) {
      usageException(
        'Invalid --$orderOptionName: expected path or layers, got "$raw"',
      );
    }
    return resolvePackageExecOrder(
      cliOrder: parsed,
      scriptOrder: scriptOrder,
    );
  }

  Future<ProcessRunResult> _runCommand(
    List<String> command, {
    required String workingDirectory,
    required Map<String, String> environment,
    bool includeParentEnvironment = true,
    bool inheritStdio = true,
    bool forwardStdin = true,
  }) async {
    try {
      return await runProcess(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        inheritStdio: inheritStdio,
        forwardStdin: forwardStdin,
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

class _QuietStepRecord {
  const _QuietStepRecord({
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final List<String> command;
  final int exitCode;
  final String stdout;
  final String stderr;
}
