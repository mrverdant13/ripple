import 'package:ripple_cli/src/commands/commands.dart';

/// {@template ripple_cli.list_command}
/// `ripple list` — print packages matching discovery and filter criteria.
/// {@endtemplate}
class ListCommand extends RippleCommand {
  /// {@macro ripple_cli.list_command}
  ListCommand();

  @override
  String get name => 'list';

  @override
  String get description =>
      'List packages matching include/exclude and filters.';
}
