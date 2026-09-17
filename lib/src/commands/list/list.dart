import 'dart:io';

import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/filters.dart';
import 'package:ripple_cli/src/git_diff.dart';
import 'package:ripple_cli/src/graph.dart';
import 'package:ripple_cli/src/list_format.dart';

/// {@template ripple_cli.list_command}
/// `ripple list` — print packages matching discovery and filter criteria.
/// {@endtemplate}
class ListCommand extends RippleCommand {
  /// {@macro ripple_cli.list_command}
  ListCommand() {
    argParser
      ..addOption(
        formatOptionName,
        allowed: listFormatValues,
        defaultsTo: listFormatPaths,
        help: 'Output format: paths (default, one relative path per line), '
            'json (array of package objects), or mermaid (workspace '
            'dependency flowchart).',
        valueHelp: 'format',
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
      ..addFlag(
        dependentsFlagName,
        help: 'Include transitive workspace dependents of the seed packages '
            '(exhaustive reverse closure).',
        negatable: false,
      )
      ..addFlag(
        dependenciesFlagName,
        help: 'Include transitive workspace dependencies of the seed '
            'packages (exhaustive forward closure).',
        negatable: false,
      );
  }

  /// Option name for `--format`.
  static const formatOptionName = 'format';

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

  /// Flag name for `--dependents`.
  static const dependentsFlagName = 'dependents';

  /// Flag name for `--dependencies`.
  static const dependenciesFlagName = 'dependencies';

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
    final format = argResults!.option(formatOptionName) ?? listFormatPaths;
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

    final expandDependents = argResults!.flag(dependentsFlagName);
    final expandDependencies = argResults!.flag(dependenciesFlagName);
    final filtered = selectPackages(
      packages,
      config: config,
      criteria: criteria,
      dependentsFilters:
          expandDependents ? const GraphExpansionFilters() : null,
      dependenciesFilters:
          expandDependencies ? const GraphExpansionFilters() : null,
    ).packages;

    switch (format) {
      case listFormatPaths:
        for (final package in filtered) {
          stdout.writeln(package.relativePath);
        }
      case listFormatJson:
        final graph = WorkspaceGraph.fromPackages(packages);
        stdout.writeln(formatPackageListJson(filtered, graph));
      case listFormatMermaid:
        final graph = WorkspaceGraph.fromPackages(packages);
        stdout.write(formatPackageListMermaid(filtered, graph));
      default:
        usageException(
          'Invalid --$formatOptionName: "$format". '
          'Allowed: ${listFormatValues.join(', ')}',
        );
    }
  }
}
