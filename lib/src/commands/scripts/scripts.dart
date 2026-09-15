import 'dart:io';

import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/scripts.dart';

/// {@template ripple_cli.scripts_command}
/// `ripple scripts` — print named scripts from ripple.yaml.
/// {@endtemplate}
class ScriptsCommand extends RippleCommand {
  /// {@macro ripple_cli.scripts_command}
  ScriptsCommand();

  @override
  String get name => 'scripts';

  @override
  String get description => 'List named scripts from ripple.yaml.';

  @override
  bool get takesArguments => false;

  @override
  Future<void> run() async {
    final config = loadRippleConfig();
    for (final script in sortedScripts(config)) {
      stdout.writeln(formatScriptListLine(script));
    }
  }
}
