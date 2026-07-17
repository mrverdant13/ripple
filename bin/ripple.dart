import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:ripple_cli/ripple_cli.dart';

/// Entrypoint for the `ripple` executable.
Future<void> main(List<String> args) async {
  try {
    await ripple(args: args);
  } on UsageException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(error.usage);
    exitCode = 64;
  }
}
