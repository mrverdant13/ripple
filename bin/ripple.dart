import 'dart:io';

import 'package:args/command_runner.dart';

/// Entrypoint for the `ripple` executable.
Future<void> main(List<String> args) async {
  final runner = CommandRunner<void>(
    'ripple',
    'Repo-agnostic runner for Dart package repos via ripple.yaml.\n'
        '\n'
        'Planned commands:\n'
        '  list   List packages matching include/exclude and filters\n'
        '  exec   Run an ad-hoc command once per matching package\n'
        '  run    Execute a named script from ripple.yaml',
  )..argParser.addFlag(
      'version',
      abbr: 'v',
      negatable: false,
      help: 'Print the ripple_cli version.',
    );

  try {
    final argResults = runner.parse(args);
    if (argResults['version'] == true) {
      stdout.writeln('ripple_cli 0.0.1-dev.1');
      return;
    }

    await runner.run(args);
  } on UsageException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(error.usage);
    exitCode = 64;
  }
}
