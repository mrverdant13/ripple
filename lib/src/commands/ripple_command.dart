import 'package:args/command_runner.dart';
import 'package:ripple_cli/src/commands/commands.dart';

/// {@template ripple_cli.ripple_command}
/// A base Ripple command.
/// {@endtemplate}
abstract class RippleCommand extends Command<void> {
  /// {@macro ripple_cli.ripple_command}
  RippleCommand();

  @override
  RippleCommandRunner get runner => super.runner! as RippleCommandRunner;
}
