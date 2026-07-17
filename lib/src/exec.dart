/// Run a child process with cwd, environment, and exit-code capture.
library;

import 'dart:io';

import 'discovery.dart';

/// Environment variable for the absolute Ripple config root path.
const rippleRootPathEnvVar = 'RIPPLE_ROOT_PATH';

/// Environment variable for the absolute path of the current package.
const ripplePackagePathEnvVar = 'RIPPLE_PACKAGE_PATH';

/// Environment variable for the current package's pubspec name.
const ripplePackageNameEnvVar = 'RIPPLE_PACKAGE_NAME';

/// Builds the `RIPPLE_*` environment map for a package-scoped invocation.
///
/// Always includes [rippleRootPathEnvVar]. When [package] is non-null, also
/// sets [ripplePackagePathEnvVar] and [ripplePackageNameEnvVar].
Map<String, String> rippleEnvironment({
  required String rootPath,
  RipplePackage? package,
}) {
  return {
    rippleRootPathEnvVar: rootPath,
    if (package != null) ...{
      ripplePackagePathEnvVar: package.path,
      ripplePackageNameEnvVar: package.name,
    },
  };
}

/// Substitutes `$RIPPLE_*` / `${RIPPLE_*}` placeholders in [command] args.
///
/// Only the known Ripple variables present in [vars] are replaced. Unknown
/// `$…` tokens are left unchanged.
List<String> substituteRippleVars(
  List<String> command, {
  required Map<String, String> vars,
}) {
  return [
    for (final arg in command) _substituteArg(arg, vars),
  ];
}

String _substituteArg(String arg, Map<String, String> vars) {
  var result = arg;
  for (final entry in vars.entries) {
    final name = entry.key;
    final value = entry.value;
    // Exact `${VAR}` match, then `$VAR` only when not a longer identifier prefix.
    result = result.replaceAll('\${$name}', value);
    result = result.replaceAllMapped(
      RegExp('\\\$${RegExp.escape(name)}(?![A-Za-z0-9_])'),
      (_) => value,
    );
  }
  return result;
}

/// Result of running a child process via [runProcess].
class ProcessRunResult {
  /// Creates a process run result.
  const ProcessRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// Exit code from the child process.
  final int exitCode;

  /// Captured standard output (empty when [inheritStdio] was used).
  final String stdout;

  /// Captured standard error (empty when [inheritStdio] was used).
  final String stderr;
}

/// Runs [command] as an executable plus arguments.
///
/// [command] must be non-empty; the first element is the executable and the
/// remainder are arguments. Does not invoke a shell.
///
/// When [inheritStdio] is `true` (default), the child's stdout/stderr are
/// inherited by this process and [ProcessRunResult.stdout] /
/// [ProcessRunResult.stderr] are empty. When `false`, output is captured and
/// returned on the result (useful for unit tests of the helper itself).
///
/// When [includeParentEnvironment] is `true` (default), [environment] is
/// merged on top of the inherited parent environment. When `false`, the child
/// receives only [environment] (or an empty environment when [environment] is
/// null), so callers can omit variables that would otherwise leak from the
/// parent.
Future<ProcessRunResult> runProcess(
  List<String> command, {
  required String workingDirectory,
  Map<String, String>? environment,
  bool inheritStdio = true,
  bool includeParentEnvironment = true,
}) async {
  if (command.isEmpty) {
    throw ArgumentError.value(command, 'command', 'must not be empty');
  }

  final executable = command.first;
  final arguments = command.length > 1 ? command.sublist(1) : const <String>[];

  if (inheritStdio) {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      mode: ProcessStartMode.inheritStdio,
    );
    final exitCode = await process.exitCode;
    return ProcessRunResult(
      exitCode: exitCode,
      stdout: '',
      stderr: '',
    );
  }

  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
  return ProcessRunResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}
