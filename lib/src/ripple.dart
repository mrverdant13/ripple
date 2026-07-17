import 'package:ripple_cli/src/commands/commands.dart';

/// Runs the Ripple CLI with the given [args].
Future<void> ripple({
  required List<String> args,
}) async {
  await RippleCommandRunner().run(args);
}
