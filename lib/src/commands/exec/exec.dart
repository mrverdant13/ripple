import 'package:ripple_cli/src/commands/commands.dart';

/// {@template ripple_cli.exec_command}
/// `ripple exec` — run an ad-hoc command once per matching package.
/// {@endtemplate}
class ExecCommand extends RippleCommand {
  /// {@macro ripple_cli.exec_command}
  ExecCommand();

  @override
  String get name => 'exec';

  @override
  String get description => 'Run an ad-hoc command once per matching package.';
}
