/// Run a child process with cwd, environment, and exit-code capture.
library;

import 'dart:async';
import 'dart:io';

import 'discovery.dart';
import 'graph.dart';

/// Tracks whether the shared terminal cursor should be at the start of a line.
///
/// Child processes that inherit / share the terminal can end mid-line (for
/// example `printf` without a trailing newline). Package-scope banners are
/// written to stderr; when stdout and stderr both point at a TTY they share
/// one cursor, so banners must insert a newline first when this is `false`.
class TerminalLineState {
  /// Whether the next write is expected to start at column 0.
  bool atLineStart = true;

  /// Updates [atLineStart] from forwarded child (or banner) bytes.
  void observeBytes(List<int> data) {
    if (data.isEmpty) {
      return;
    }
    final last = data.last;
    // LF or CR both return the cursor to the start of a line on typical TTYs.
    atLineStart = last == 0x0A || last == 0x0D;
  }

  /// Updates [atLineStart] from text about to be / just written.
  void observeText(String text) {
    if (text.isEmpty) {
      return;
    }
    final unit = text.codeUnitAt(text.length - 1);
    atLineStart = unit == 0x0A || unit == 0x0D;
  }

  /// Writes a newline to [sink] when the cursor is not at line start.
  void ensureLineStart(StringSink sink) {
    if (atLineStart) {
      return;
    }
    sink.write('\n');
    atLineStart = true;
  }
}

/// Process-wide line state for forwarded child stdio and Ripple banners.
final terminalLineState = TerminalLineState();

/// Environment variable for the absolute Ripple config root path.
const rippleRootPathEnvVar = 'RIPPLE_ROOT_PATH';

/// Environment variable for the absolute path of the current package.
const ripplePackagePathEnvVar = 'RIPPLE_PACKAGE_PATH';

/// Environment variable for the current package's pubspec name.
const ripplePackageNameEnvVar = 'RIPPLE_PACKAGE_NAME';

/// Environment variable for the current package's pubspec version.
const ripplePackageVersionEnvVar = 'RIPPLE_PACKAGE_VERSION';

/// Builds the `RIPPLE_*` environment map for a package-scoped invocation.
///
/// Always includes [rippleRootPathEnvVar]. When [package] is non-null, also
/// sets [ripplePackagePathEnvVar] and [ripplePackageNameEnvVar]. Sets
/// [ripplePackageVersionEnvVar] only when that package's pubspec declares a
/// version; the variable is omitted when the version is absent.
Map<String, String> rippleEnvironment({
  required String rootPath,
  RipplePackage? package,
}) {
  final version = package?.pubspec?.version;
  return {
    rippleRootPathEnvVar: rootPath,
    if (package != null) ...{
      ripplePackagePathEnvVar: package.path,
      ripplePackageNameEnvVar: package.name,
      if (version != null) ripplePackageVersionEnvVar: '$version',
    },
  };
}

/// Merges [vars] onto [parent] (default: [Platform.environment]) for a child.
///
/// Parent keys that start with `RIPPLE_PACKAGE_` and are not present in [vars]
/// are removed so omit-if-absent variables (such as
/// [ripplePackageVersionEnvVar]) cannot leak from a parent Ripple invocation.
Map<String, String> rippleChildEnvironment(
  Map<String, String> vars, {
  Map<String, String>? parent,
}) {
  return Map<String, String>.from(parent ?? Platform.environment)
    ..removeWhere(
      (key, _) => key.startsWith('RIPPLE_PACKAGE_') && !vars.containsKey(key),
    )
    ..addAll(vars);
}

/// ANSI helpers for package-scope banners (TTY + color-enabled only).
const _ansiReset = '\x1B[0m';
const _ansiBold = '\x1B[1m';
const _ansiCyan = '\x1B[36m';
const _ansiGreen = '\x1B[32m';
const _ansiRed = '\x1B[31m';

/// Whether [sink] should be treated as a terminal for banner color defaults.
///
/// Explicit [hasTerminal] wins. Otherwise a [Stdout] sink uses its own
/// `hasTerminal`; non-Stdout sinks (buffers, files) default to `false`.
bool resolveBannerHasTerminal(
  StringSink sink, {
  bool? hasTerminal,
}) {
  if (hasTerminal != null) {
    return hasTerminal;
  }
  if (sink is Stdout) {
    return sink.hasTerminal;
  }
  return false;
}

/// Whether package-scope banners should include ANSI color.
///
/// Color is off when [forceColor] is `false`, when `NO_COLOR` is set, when
/// `TERM` is `dumb`, or when [hasTerminal] is `false`. [forceColor] `true`
/// overrides those checks (useful in tests).
bool packageScopeBannersUseColor({
  bool? forceColor,
  bool? hasTerminal,
  Map<String, String>? environment,
}) {
  if (forceColor != null) {
    return forceColor;
  }
  final env = environment ?? Platform.environment;
  if (env.containsKey('NO_COLOR')) {
    return false;
  }
  if (env['TERM'] == 'dumb') {
    return false;
  }
  return hasTerminal ?? false;
}

/// Scope label used for root `run:` banners (cwd identity, not a package).
const rootScopeLabel = '(root)';

/// Package scope label for banners: `{pubspec.name} @ {relativePath}`.
String formatPackageScopeLabel(RipplePackage package) =>
    '${package.name} @ ${package.relativePath}';

/// Formats the start-of-package banner line (no trailing newline).
String formatPackageScopeStart(
  String scopeLabel, {
  required bool color,
}) {
  final body = '[ripple] ▶ $scopeLabel';
  if (!color) {
    return body;
  }
  return '$_ansiBold$_ansiCyan$body$_ansiReset';
}

/// Formats the end-of-package banner line (no trailing newline).
String formatPackageScopeEnd(
  String scopeLabel, {
  required int exitCode,
  required bool color,
}) {
  final body = '[ripple] ■ $scopeLabel  (exit $exitCode)';
  if (!color) {
    return body;
  }
  final tone = exitCode == 0 ? _ansiGreen : _ansiRed;
  return '$_ansiBold$tone$body$_ansiReset';
}

/// Whether banner writes to [sink] should insert a newline when mid-line.
///
/// Only relevant when banners share a terminal cursor with child stdout
/// (interactive runs). Piped captures keep stdout/stderr separate, so no
/// leading newline is inserted there.
bool shouldEnsureBannerLineStart(
  StringSink sink, {
  bool? forceEnsureLineStart,
  bool? stdoutIsTerminal,
  bool? stderrIsTerminal,
}) {
  if (forceEnsureLineStart != null) {
    return forceEnsureLineStart;
  }
  if (!identical(sink, stderr)) {
    return false;
  }
  return (stdoutIsTerminal ?? stdout.hasTerminal) &&
      (stderrIsTerminal ?? stderr.hasTerminal);
}

void _writePackageScopeBanner(
  String line, {
  required StringSink sink,
  required bool ensureLineStart,
}) {
  if (ensureLineStart) {
    terminalLineState.ensureLineStart(sink);
  }
  sink.writeln(line);
  terminalLineState.atLineStart = true;
}

void _announceScopeStart(
  String scopeLabel, {
  StringSink? sink,
  bool? forceColor,
  bool? hasTerminal,
  bool? forceEnsureLineStart,
  Map<String, String>? environment,
}) {
  final out = sink ?? stderr;
  final color = packageScopeBannersUseColor(
    forceColor: forceColor,
    hasTerminal: resolveBannerHasTerminal(out, hasTerminal: hasTerminal),
    environment: environment,
  );
  _writePackageScopeBanner(
    formatPackageScopeStart(scopeLabel, color: color),
    sink: out,
    ensureLineStart: shouldEnsureBannerLineStart(
      out,
      forceEnsureLineStart: forceEnsureLineStart,
    ),
  );
}

void _announceScopeEnd(
  String scopeLabel, {
  required int exitCode,
  StringSink? sink,
  bool? forceColor,
  bool? hasTerminal,
  bool? forceEnsureLineStart,
  Map<String, String>? environment,
}) {
  final out = sink ?? stderr;
  final color = packageScopeBannersUseColor(
    forceColor: forceColor,
    hasTerminal: resolveBannerHasTerminal(out, hasTerminal: hasTerminal),
    environment: environment,
  );
  _writePackageScopeBanner(
    formatPackageScopeEnd(
      scopeLabel,
      exitCode: exitCode,
      color: color,
    ),
    sink: out,
    ensureLineStart: shouldEnsureBannerLineStart(
      out,
      forceEnsureLineStart: forceEnsureLineStart,
    ),
  );
}

/// Writes the start banner for a package command block.
///
/// Uses [formatPackageScopeLabel] (`name @ relativePath`). Written to
/// [sink] (stderr by default) so banners do not mix into child stdout.
///
/// When stdout and stderr share a TTY, inserts a newline first if the previous
/// child output did not end the line (see [terminalLineState]).
void announcePackageScopeStart(
  RipplePackage package, {
  StringSink? sink,
  bool? forceColor,
  bool? hasTerminal,
  bool? forceEnsureLineStart,
  Map<String, String>? environment,
}) {
  _announceScopeStart(
    formatPackageScopeLabel(package),
    sink: sink,
    forceColor: forceColor,
    hasTerminal: hasTerminal,
    forceEnsureLineStart: forceEnsureLineStart,
    environment: environment,
  );
}

/// Writes the end banner for a package command block, including [exitCode].
void announcePackageScopeEnd(
  RipplePackage package, {
  required int exitCode,
  StringSink? sink,
  bool? forceColor,
  bool? hasTerminal,
  bool? forceEnsureLineStart,
  Map<String, String>? environment,
}) {
  _announceScopeEnd(
    formatPackageScopeLabel(package),
    exitCode: exitCode,
    sink: sink,
    forceColor: forceColor,
    hasTerminal: hasTerminal,
    forceEnsureLineStart: forceEnsureLineStart,
    environment: environment,
  );
}

/// Writes the start banner for a root `run:` script block ([rootScopeLabel]).
void announceRootScopeStart({
  StringSink? sink,
  bool? forceColor,
  bool? hasTerminal,
  bool? forceEnsureLineStart,
  Map<String, String>? environment,
}) {
  _announceScopeStart(
    rootScopeLabel,
    sink: sink,
    forceColor: forceColor,
    hasTerminal: hasTerminal,
    forceEnsureLineStart: forceEnsureLineStart,
    environment: environment,
  );
}

/// Writes the end banner for a root `run:` script block, including [exitCode].
void announceRootScopeEnd({
  required int exitCode,
  StringSink? sink,
  bool? forceColor,
  bool? hasTerminal,
  bool? forceEnsureLineStart,
  Map<String, String>? environment,
}) {
  _announceScopeEnd(
    rootScopeLabel,
    exitCode: exitCode,
    sink: sink,
    forceColor: forceColor,
    hasTerminal: hasTerminal,
    forceEnsureLineStart: forceEnsureLineStart,
    environment: environment,
  );
}

/// Formats [command] as a shell-like argv line for banners.
///
/// Arguments that are empty or contain whitespace / shell metacharacters are
/// single-quoted (with embedded `'` escaped as `'\''`).
String formatCommandLine(List<String> command) {
  return command.map(_quoteCommandArg).join(' ');
}

String _quoteCommandArg(String arg) {
  if (arg.isEmpty) {
    return "''";
  }
  if (_safeCommandArg.hasMatch(arg)) {
    return arg;
  }
  return "'${arg.replaceAll("'", "'\\''")}'";
}

/// Characters that are safe unquoted in a display-only shell-like argv line.
final _safeCommandArg = RegExp(r'^[A-Za-z0-9_./:=+@%,-]+$');

/// Formats the start-of-command banner line (no trailing newline).
///
/// [scopeLabel] is the pubspec name for package commands, or [rootScopeLabel]
/// for root `run:` scripts.
String formatCommandStart(
  List<String> command, {
  required String scopeLabel,
  required bool color,
}) {
  final body = '[ripple][$scopeLabel] \$ ${formatCommandLine(command)}';
  if (!color) {
    return body;
  }
  return '$_ansiBold$_ansiCyan$body$_ansiReset';
}

/// Formats the end-of-command banner line (no trailing newline).
///
/// [scopeLabel] is the pubspec name for package commands, or [rootScopeLabel]
/// for root `run:` scripts.
String formatCommandEnd(
  List<String> command, {
  required String scopeLabel,
  required int exitCode,
  required bool color,
}) {
  final body =
      '[ripple][$scopeLabel] \$ ${formatCommandLine(command)}  (exit $exitCode)';
  if (!color) {
    return body;
  }
  final tone = exitCode == 0 ? _ansiGreen : _ansiRed;
  return '$_ansiBold$tone$body$_ansiReset';
}

/// Writes the start banner for a single command invocation.
///
/// Printed to [sink] (stderr by default) immediately before [runProcess] so
/// users can match each command to its following child output.
///
/// [scopeLabel] stamps the active package name or [rootScopeLabel] onto the
/// banner line.
void announceCommandStart(
  List<String> command, {
  required String scopeLabel,
  StringSink? sink,
  bool? forceColor,
  bool? hasTerminal,
  bool? forceEnsureLineStart,
  Map<String, String>? environment,
}) {
  final out = sink ?? stderr;
  final color = packageScopeBannersUseColor(
    forceColor: forceColor,
    hasTerminal: resolveBannerHasTerminal(out, hasTerminal: hasTerminal),
    environment: environment,
  );
  _writePackageScopeBanner(
    formatCommandStart(command, scopeLabel: scopeLabel, color: color),
    sink: out,
    ensureLineStart: shouldEnsureBannerLineStart(
      out,
      forceEnsureLineStart: forceEnsureLineStart,
    ),
  );
}

/// Writes the end banner for a single command invocation, including [exitCode].
///
/// [scopeLabel] stamps the active package name or [rootScopeLabel] onto the
/// banner line.
void announceCommandEnd(
  List<String> command, {
  required String scopeLabel,
  required int exitCode,
  StringSink? sink,
  bool? forceColor,
  bool? hasTerminal,
  bool? forceEnsureLineStart,
  Map<String, String>? environment,
}) {
  final out = sink ?? stderr;
  final color = packageScopeBannersUseColor(
    forceColor: forceColor,
    hasTerminal: resolveBannerHasTerminal(out, hasTerminal: hasTerminal),
    environment: environment,
  );
  _writePackageScopeBanner(
    formatCommandEnd(
      command,
      scopeLabel: scopeLabel,
      exitCode: exitCode,
      color: color,
    ),
    sink: out,
    ensureLineStart: shouldEnsureBannerLineStart(
      out,
      forceEnsureLineStart: forceEnsureLineStart,
    ),
  );
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

/// Writes captured child stdout/stderr to the parent process sinks.
///
/// Used after a quiet run fails so banners can frame the buffered output.
/// Updates [terminalLineState] the same way live forwarding does.
void writeCapturedChildOutput({
  required String capturedStdout,
  required String capturedStderr,
  StringSink? stdoutSink,
  StringSink? stderrSink,
}) {
  final out = stdoutSink ?? stdout;
  final err = stderrSink ?? stderr;
  if (capturedStdout.isNotEmpty) {
    out.write(capturedStdout);
    terminalLineState.observeText(capturedStdout);
  }
  if (capturedStderr.isNotEmpty) {
    err.write(capturedStderr);
    terminalLineState.observeText(capturedStderr);
  }
}

/// Resolves whether quiet mode is active.
///
/// CLI `--quiet` enables quiet whenever present. Otherwise [scriptQuiet] from
/// YAML `quiet:` is used. When both are set, the CLI flag wins (both true).
bool resolveQuietMode({
  required bool cliQuiet,
  bool scriptQuiet = false,
}) {
  return cliQuiet || scriptQuiet;
}

/// Default package concurrency when neither CLI nor YAML sets a value.
const defaultPackageConcurrency = 1;

/// Resolves package concurrency for `exec` / `exec:` runs.
///
/// [cliConcurrency] wins when non-null (CLI `--concurrency` was passed).
/// Otherwise [scriptConcurrency] from YAML `concurrency:` is used. When both
/// are absent, returns [defaultPackageConcurrency] (`1`).
///
/// Throws [ArgumentError] when the resolved value is less than 1.
int resolveConcurrency({
  int? cliConcurrency,
  int? scriptConcurrency,
}) {
  final value =
      cliConcurrency ?? scriptConcurrency ?? defaultPackageConcurrency;
  if (value < 1) {
    throw ArgumentError.value(value, 'concurrency', 'must be at least 1');
  }
  return value;
}

/// Runs [run] for each item with at most [concurrency] invocations in flight.
///
/// Items are claimed in list order. With [concurrency] `1`, start order matches
/// the input list (today’s sequential `relativePath` behavior). With
/// [failFast], no further items are started after a non-zero exit; in-flight
/// work may still finish.
///
/// Returns `0` when every invocation exits 0; otherwise the exit code of the
/// earliest failing item in list order (stable vs concurrent completion order).
Future<int> runWithBoundedConcurrency<T>({
  required List<T> items,
  required int concurrency,
  required bool failFast,
  required Future<int> Function(T item) run,
}) async {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'must be at least 1');
  }
  if (items.isEmpty) {
    return 0;
  }

  final workerCount = concurrency > items.length ? items.length : concurrency;
  var nextIndex = 0;
  var stopStarting = false;
  var earliestFailureIndex = -1;
  var earliestFailureExitCode = 0;

  Future<void> worker() async {
    while (true) {
      if (stopStarting) {
        return;
      }
      final index = nextIndex;
      if (index >= items.length) {
        return;
      }
      nextIndex++;
      final exitCode = await run(items[index]);
      if (exitCode == 0) {
        continue;
      }
      if (earliestFailureIndex < 0 || index < earliestFailureIndex) {
        earliestFailureIndex = index;
        earliestFailureExitCode = exitCode;
      }
      if (failFast) {
        stopStarting = true;
      }
    }
  }

  await Future.wait<void>([
    for (var i = 0; i < workerCount; i++) worker(),
  ]);
  return earliestFailureExitCode;
}

/// How packages are ordered for `exec` / `exec:` runs.
enum PackageExecOrder {
  /// Stable sort by [RipplePackage.relativePath] (default).
  path,

  /// Dependency layers: workspace deps finish before dependents; siblings in a
  /// layer may run in parallel up to `--concurrency`.
  layers,
}

/// Default package order when neither CLI nor YAML sets a value.
const defaultPackageExecOrder = PackageExecOrder.path;

/// Allowed `--order` / YAML `order:` values.
const packageExecOrderValues = {
  'path': PackageExecOrder.path,
  'layers': PackageExecOrder.layers,
};

/// Parses an `--order` / `order:` token, or returns `null` when unknown.
PackageExecOrder? tryParsePackageExecOrder(String raw) =>
    packageExecOrderValues[raw.trim()];

/// Resolves package order for `exec` / `exec:` runs.
///
/// [cliOrder] wins when non-null (CLI `--order` was passed). Otherwise
/// [scriptOrder] from YAML `order:` is used. When both are absent, returns
/// [defaultPackageExecOrder] (`path`).
PackageExecOrder resolvePackageExecOrder({
  PackageExecOrder? cliOrder,
  PackageExecOrder? scriptOrder,
}) {
  return cliOrder ?? scriptOrder ?? defaultPackageExecOrder;
}

/// Runs [run] over [layers] with at most [concurrency] invocations in flight
/// **within** each layer. The next layer starts only after the previous layer
/// has fully finished.
///
/// With [failFast], no further items are started after a non-zero exit
/// (remaining packages in the current layer and later layers). In-flight work
/// in the current layer may still finish.
///
/// Returns `0` when every invocation exits 0; otherwise the exit code of the
/// earliest failing item in flattened layer order (layer 0, then layer 1, …
/// and within a layer the input list order).
Future<int> runWithLayeredConcurrency<T>({
  required List<List<T>> layers,
  required int concurrency,
  required bool failFast,
  required Future<int> Function(T item) run,
}) async {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'must be at least 1');
  }

  var earliestFailureFlatIndex = -1;
  var earliestFailureExitCode = 0;
  var flatOffset = 0;
  var stopStarting = false;

  for (final layer in layers) {
    if (stopStarting) {
      break;
    }
    if (layer.isEmpty) {
      continue;
    }

    final layerExits = List<int?>.filled(layer.length, null);
    await runWithBoundedConcurrency<int>(
      items: List<int>.generate(layer.length, (index) => index),
      concurrency: concurrency,
      failFast: failFast,
      run: (index) async {
        final exitCode = await run(layer[index]);
        layerExits[index] = exitCode;
        return exitCode;
      },
    );

    for (var index = 0; index < layer.length; index++) {
      final exitCode = layerExits[index];
      if (exitCode == null || exitCode == 0) {
        continue;
      }
      final flatIndex = flatOffset + index;
      if (earliestFailureFlatIndex < 0 ||
          flatIndex < earliestFailureFlatIndex) {
        earliestFailureFlatIndex = flatIndex;
        earliestFailureExitCode = exitCode;
      }
    }

    if (failFast && earliestFailureExitCode != 0) {
      stopStarting = true;
    }
    flatOffset += layer.length;
  }

  return earliestFailureExitCode;
}

/// Runs [run] for each selected package using [order].
///
/// [PackageExecOrder.path] claims packages in list order (today’s
/// `relativePath` behavior). [PackageExecOrder.layers] runs
/// [WorkspaceGraph.executionLayers] with layer barriers; cycle errors from the
/// graph propagate to the caller.
Future<int> runPackagesInOrder({
  required List<RipplePackage> packages,
  required PackageExecOrder order,
  required WorkspaceGraph graph,
  required int concurrency,
  required bool failFast,
  required Future<int> Function(RipplePackage package) run,
}) {
  if (order == PackageExecOrder.path) {
    return runWithBoundedConcurrency(
      items: packages,
      concurrency: concurrency,
      failFast: failFast,
      run: run,
    );
  }
  return runWithLayeredConcurrency(
    layers: graph.executionLayers(packages),
    concurrency: concurrency,
    failFast: failFast,
    run: run,
  );
}

/// Runs [command] as an executable plus arguments.
///
/// [command] must be non-empty; the first element is the executable and the
/// remainder are arguments. Does not invoke a shell.
///
/// When [inheritStdio] is `true` (default), the child's stdin/stdout/stderr
/// are connected to this process: stdout/stderr are forwarded (and tracked for
/// [terminalLineState]), and parent stdin is forwarded to the child when
/// [forwardStdin] is `true` (default). Result stdout/stderr strings are empty.
/// Forwarding (instead of OS inherit) lets Ripple keep package banners on their
/// own line after mid-line child output. When `false`, output is captured and
/// returned on the result (useful for unit tests of the helper itself).
///
/// Set [forwardStdin] to `false` for concurrent package runs so a single parent
/// stdin stream is not fan-out to multiple children.
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
  bool forwardStdin = true,
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
    );
    final stdoutDone = _forwardAndTrack(process.stdout, stdout);
    final stderrDone = _forwardAndTrack(process.stderr, stderr);
    // Parent stdin is a single-subscription stream; share it across sequential
    // child runs (multi-step scripts / multi-package exec). Concurrent package
    // runs skip stdin forwarding ([forwardStdin] false).
    final stdinSub =
        forwardStdin ? _forwardStdin(_sharedStdin(), process.stdin) : null;
    if (!forwardStdin) {
      await process.stdin.close().catchError((_) {});
    }
    try {
      final exitCode = await process.exitCode;
      await Future.wait<void>([stdoutDone, stderrDone]);
      await Future.wait<dynamic>([stdout.flush(), stderr.flush()]);
      return ProcessRunResult(
        exitCode: exitCode,
        stdout: '',
        stderr: '',
      );
    } finally {
      await stdinSub?.cancel();
      if (forwardStdin) {
        await process.stdin.close().catchError((_) {});
      }
    }
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

Future<void> _forwardAndTrack(Stream<List<int>> stream, IOSink sink) {
  final done = Completer<void>();
  stream.listen(
    (data) {
      sink.add(data);
      terminalLineState.observeBytes(data);
    },
    onDone: done.complete,
    onError: done.completeError,
    cancelOnError: true,
  );
  return done.future;
}

StreamController<List<int>>? _stdinFanout;
StreamSubscription<List<int>>? _stdinSourceSub;
bool _stdinFanoutClosed = false;

/// Broadcast view of parent [stdin] for repeated child process subscriptions.
Stream<List<int>> _sharedStdin() {
  if (_stdinFanoutClosed) {
    return const Stream<List<int>>.empty();
  }
  if (_stdinFanout == null) {
    final fanout = StreamController<List<int>>.broadcast(sync: true);
    _stdinFanout = fanout;
    // Keep listening across sequential children; [detachSharedStdin] cancels
    // this so an interactive TTY does not keep the isolate alive after the CLI
    // finishes.
    _stdinSourceSub = stdin.listen(
      fanout.add,
      onError: fanout.addError,
      onDone: () {
        _stdinFanoutClosed = true;
        _stdinSourceSub = null;
        fanout.close();
      },
      cancelOnError: false,
    );
  }
  return _stdinFanout!.stream;
}

/// Stops shared parent-stdin forwarding so the isolate can exit.
///
/// Safe to call when forwarding was never started. After this, later
/// [runProcess] inheritStdio runs see a closed stdin (immediate EOF).
Future<void> detachSharedStdin() async {
  final sourceSub = _stdinSourceSub;
  _stdinSourceSub = null;
  if (sourceSub != null) {
    await sourceSub.cancel();
  }

  final fanout = _stdinFanout;
  _stdinFanout = null;
  _stdinFanoutClosed = true;
  if (fanout != null && !fanout.isClosed) {
    await fanout.close();
  }
}

/// Forwards [source] to [childStdin], closing [childStdin] when [source] ends.
StreamSubscription<List<int>> _forwardStdin(
  Stream<List<int>> source,
  IOSink childStdin,
) {
  return source.listen(
    (data) {
      try {
        childStdin.add(data);
      } on StateError {
        // Child stdin already closed.
      }
    },
    onDone: () {
      childStdin.close().catchError((_) {});
    },
    onError: (_) {
      childStdin.close().catchError((_) {});
    },
    cancelOnError: true,
  );
}
