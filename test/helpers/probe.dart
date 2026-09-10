/// Portable subprocess used by CLI tests instead of `sh` / `printenv` / `pwd`.
///
/// Not a `*_test.dart` file, so coverde optimize-tests does not pick it up.
library;

import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: probe <command> ...');
    exit(64);
  }

  switch (args.first) {
    case 'cwd':
      stdout.writeln(Directory.current.path);
    case 'env':
      _printEnv(args.skip(1).toList());
    case 'env-root-only':
      _printRootOnly();
    case 'write':
      stdout.write(args.skip(1).join(' '));
    case 'echo':
      stdout.writeln(args.skip(1).join(' '));
    case 'exit':
      if (args.length < 2) {
        stderr.writeln('probe exit: missing code');
        exit(64);
      }
      exit(int.parse(args[1]));
    case 'write-then-exit':
      if (args.length < 3) {
        stderr.writeln('probe write-then-exit: missing TEXT or N');
        exit(64);
      }
      stdout.write(args[1]);
      exit(int.parse(args[2]));
    case 'fail-if':
      _failIf(args.skip(1).toList());
    case 'stdin':
      stdout.write(stdin.readLineSync() ?? '');
    case 'write-file':
      if (args.length < 3) {
        stderr.writeln('probe write-file: missing PATH or TEXT');
        exit(64);
      }
      File(args[1]).writeAsStringSync(args[2]);
    default:
      stderr.writeln('probe: unknown command "${args.first}"');
      exit(64);
  }
}

void _printEnv(List<String> names) {
  if (names.isEmpty) {
    stderr.writeln('probe env: missing NAME');
    exit(64);
  }
  for (final name in names) {
    final value = Platform.environment[name];
    if (value == null) {
      exit(1);
    }
    stdout.writeln(value);
  }
}

void _printRootOnly() {
  if (Platform.environment.containsKey('RIPPLE_PACKAGE_PATH') ||
      Platform.environment.containsKey('RIPPLE_PACKAGE_NAME')) {
    exit(11);
  }
  final root = Platform.environment['RIPPLE_ROOT_PATH'];
  if (root == null) {
    exit(1);
  }
  stdout.writeln(root);
}

void _failIf(List<String> args) {
  if (args.isEmpty || !args.first.contains('=')) {
    stderr.writeln('probe fail-if: expected NAME=value');
    exit(64);
  }
  final eq = args.first.indexOf('=');
  final name = args.first.substring(0, eq);
  final expected = args.first.substring(eq + 1);
  var exitCode = 1;
  String? printEnv;
  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--exit' && i + 1 < args.length) {
      exitCode = int.parse(args[++i]);
      continue;
    }
    if (arg == '--print-env' && i + 1 < args.length) {
      printEnv = args[++i];
      continue;
    }
    stderr.writeln('probe fail-if: unexpected $arg');
    exit(64);
  }
  if (printEnv != null) {
    final value = Platform.environment[printEnv];
    if (value == null) {
      exit(1);
    }
    stdout.writeln(value);
  }
  if (Platform.environment[name] == expected) {
    exit(exitCode);
  }
}
