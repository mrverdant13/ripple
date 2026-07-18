import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/exec.dart';

/// Runs the Ripple CLI with the given [args].
Future<void> ripple({
  required List<String> args,
}) async {
  try {
    await RippleCommandRunner().run(args);
  } finally {
    // Cancel shared stdin forwarding started by inheritStdio child runs so an
    // interactive terminal does not keep the isolate alive after the command.
    await detachSharedStdin();
  }
}
