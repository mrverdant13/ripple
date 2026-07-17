import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:ripple_cli/src/commands/commands.dart';

/// {@template ripple_cli.ripple_command_runner}
/// The runner for the `ripple` command.
/// {@endtemplate}
class RippleCommandRunner extends CommandRunner<void> {
  /// {@macro ripple_cli.ripple_command_runner}
  RippleCommandRunner()
      : super(
          'ripple',
          'Repo-agnostic runner for Dart package repos via ripple.yaml.\n'
              '\n'
              'Available commands:\n'
              '  list   List packages matching include/exclude and filters\n'
              '\n'
              'Planned commands:\n'
              '  exec   Run an ad-hoc command once per matching package\n'
              '  run    Execute a named script from ripple.yaml',
        ) {
    addCommand(ListCommand());
    argParser.addFlag(
      versionFlagName,
      abbr: 'v',
      negatable: false,
      help: 'Print the ripple_cli version.',
    );
  }

  /// Flag name for printing the package version.
  static const versionFlagName = 'version';

  /// The package version printed by `--version`.
  static const packageVersion = '0.0.1-dev.1';

  /// The commands that encapsulate actual functionality.
  Iterable<RippleCommand> get featureCommands => {
        for (final MapEntry(:value) in super.commands.entries)
          if (value is RippleCommand) value,
      };

  @override
  Future<void> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults.flag(versionFlagName)) {
      stdout.writeln('ripple_cli $packageVersion');
      return;
    }

    await super.runCommand(topLevelResults);
  }
}
