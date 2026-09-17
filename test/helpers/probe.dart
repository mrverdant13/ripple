/// Portable subprocess used by CLI tests instead of `sh` / `printenv` / `pwd`.
///
/// Not a `*_test.dart` file, so coverde optimize-tests does not pick it up.
library;

import 'dart:io';

Future<void> main(List<String> args) async {
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
    case 'env-absent':
      _assertEnvAbsent(args.skip(1).toList());
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
    case 'sleep-ms':
      if (args.length < 2) {
        stderr.writeln('probe sleep-ms: missing milliseconds');
        exit(64);
      }
      final ms = int.tryParse(args[1]);
      if (ms == null || ms < 0) {
        stderr.writeln('probe sleep-ms: invalid milliseconds');
        exit(64);
      }
      await Future<void>.delayed(Duration(milliseconds: ms));
      final name = Platform.environment['RIPPLE_PACKAGE_NAME'];
      if (name != null) {
        stdout.writeln(name);
      }
    case 'sleep-ms-append':
      if (args.length < 3) {
        stderr.writeln('probe sleep-ms-append: missing PATH or milliseconds');
        exit(64);
      }
      final appendPath = args[1];
      final sleepMs = int.tryParse(args[2]);
      if (sleepMs == null || sleepMs < 0) {
        stderr.writeln('probe sleep-ms-append: invalid milliseconds');
        exit(64);
      }
      await Future<void>.delayed(Duration(milliseconds: sleepMs));
      final packageName = Platform.environment['RIPPLE_PACKAGE_NAME'];
      if (packageName == null) {
        exit(1);
      }
      // Per-package stamp file avoids concurrent append interleaving.
      File('$appendPath.$packageName').writeAsStringSync('ok\n');
    case 'timed-log':
      if (args.length < 3) {
        stderr.writeln('probe timed-log: missing PATH or milliseconds');
        exit(64);
      }
      final logPath = args[1];
      final sleepMs = int.tryParse(args[2]);
      if (sleepMs == null || sleepMs < 0) {
        stderr.writeln('probe timed-log: invalid milliseconds');
        exit(64);
      }
      final packageName = Platform.environment['RIPPLE_PACKAGE_NAME'];
      if (packageName == null) {
        exit(1);
      }
      final start = DateTime.now().microsecondsSinceEpoch;
      await Future<void>.delayed(Duration(milliseconds: sleepMs));
      final end = DateTime.now().microsecondsSinceEpoch;
      // Per-package stamp avoids concurrent append interleaving.
      File('$logPath.$packageName')
          .writeAsStringSync('start $start\nend $end\n');
    case 'append-file':
      if (args.length < 3) {
        stderr.writeln('probe append-file: missing PATH or TEXT');
        exit(64);
      }
      File(args[1]).writeAsStringSync(
        '${args.skip(2).join(' ')}\n',
        mode: FileMode.append,
      );
    case 'stamp-and-fail-if':
      _stampAndFailIf(args.skip(1).toList());
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
  if (Platform.environment.keys.any(
    (key) => key.startsWith('RIPPLE_PACKAGE_'),
  )) {
    exit(11);
  }
  final root = Platform.environment['RIPPLE_ROOT_PATH'];
  if (root == null) {
    exit(1);
  }
  stdout.writeln(root);
}

void _assertEnvAbsent(List<String> names) {
  if (names.isEmpty) {
    stderr.writeln('probe env-absent: missing NAME');
    exit(64);
  }
  for (final name in names) {
    if (Platform.environment.containsKey(name)) {
      exit(1);
    }
  }
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

/// Appends nothing; writes `RIPPLE_PACKAGE_NAME` as a sibling stamp file, then
/// fails when NAME=value matches.
///
/// [path] is treated as a stamp directory prefix: creates `$path.$packageName`
/// so concurrent packages do not interleave writes.
void _stampAndFailIf(List<String> args) {
  if (args.length < 2 || !args[1].contains('=')) {
    stderr.writeln('probe stamp-and-fail-if: expected PATH NAME=value');
    exit(64);
  }
  final path = args[0];
  final eq = args[1].indexOf('=');
  final name = args[1].substring(0, eq);
  final expected = args[1].substring(eq + 1);
  var exitCode = 1;
  for (var i = 2; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--exit' && i + 1 < args.length) {
      exitCode = int.parse(args[++i]);
      continue;
    }
    stderr.writeln('probe stamp-and-fail-if: unexpected $arg');
    exit(64);
  }
  final packageName = Platform.environment['RIPPLE_PACKAGE_NAME'];
  if (packageName == null) {
    exit(1);
  }
  File('$path.$packageName').writeAsStringSync('ok\n');
  if (Platform.environment[name] == expected) {
    exit(exitCode);
  }
}
