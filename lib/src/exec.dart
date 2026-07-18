/// Run a child process with cwd, environment, and exit-code capture.
library;

import 'dart:async';
import 'dart:io';

import 'discovery.dart';

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

/// Formats the start-of-package banner line (no trailing newline).
String formatPackageScopeStart(
  String relativePath, {
  required bool color,
}) {
  final body = '[ripple] ▶ $relativePath';
  if (!color) {
    return body;
  }
  return '$_ansiBold$_ansiCyan$body$_ansiReset';
}

/// Formats the end-of-package banner line (no trailing newline).
String formatPackageScopeEnd(
  String relativePath, {
  required int exitCode,
  required bool color,
}) {
  final body = '[ripple] ■ $relativePath  (exit $exitCode)';
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

/// Writes the start banner for a package command block.
///
/// Uses [package.relativePath] (same form as `ripple list`). Written to
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
  final out = sink ?? stderr;
  final color = packageScopeBannersUseColor(
    forceColor: forceColor,
    hasTerminal: resolveBannerHasTerminal(out, hasTerminal: hasTerminal),
    environment: environment,
  );
  _writePackageScopeBanner(
    formatPackageScopeStart(package.relativePath, color: color),
    sink: out,
    ensureLineStart: shouldEnsureBannerLineStart(
      out,
      forceEnsureLineStart: forceEnsureLineStart,
    ),
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
  final out = sink ?? stderr;
  final color = packageScopeBannersUseColor(
    forceColor: forceColor,
    hasTerminal: resolveBannerHasTerminal(out, hasTerminal: hasTerminal),
    environment: environment,
  );
  _writePackageScopeBanner(
    formatPackageScopeEnd(
      package.relativePath,
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

/// Runs [command] as an executable plus arguments.
///
/// [command] must be non-empty; the first element is the executable and the
/// remainder are arguments. Does not invoke a shell.
///
/// When [inheritStdio] is `true` (default), the child's stdin/stdout/stderr
/// are connected to this process: stdout/stderr are forwarded (and tracked for
/// [terminalLineState]), and parent stdin is forwarded to the child. Result
/// stdout/stderr strings are empty. Forwarding (instead of OS inherit) lets
/// Ripple keep package banners on their own line after mid-line child output.
/// When `false`, output is captured and returned on the result (useful for
/// unit tests of the helper itself).
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
    );
    final stdoutDone = _forwardAndTrack(process.stdout, stdout);
    final stderrDone = _forwardAndTrack(process.stderr, stderr);
    // Parent stdin is a single-subscription stream; share it across sequential
    // child runs (multi-step scripts / multi-package exec).
    final stdinSub = _forwardStdin(_sharedStdin(), process.stdin);
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
      await stdinSub.cancel();
      await process.stdin.close().catchError((_) {});
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
