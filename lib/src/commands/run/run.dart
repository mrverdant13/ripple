import 'package:ripple_cli/src/commands/commands.dart';

/// {@template ripple_cli.run_command}
/// `ripple run` — execute a named script from ripple.yaml.
/// {@endtemplate}
class RunCommand extends RippleCommand {
  /// {@macro ripple_cli.run_command}
  RunCommand();

  @override
  String get name => 'run';

  @override
  String get description => 'Execute a named script from ripple.yaml.';
}
