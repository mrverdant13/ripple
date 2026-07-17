/// Load and validate `ripple.yaml` from a consumer repository.
library;

/// Thrown when `ripple.yaml` cannot be found, read, parsed, or validated.
class RippleConfigException implements Exception {
  /// Creates a config error with a human-readable [message].
  const RippleConfigException(this.message);

  /// Description of what went wrong.
  final String message;

  @override
  String toString() => 'RippleConfigException: $message';
}

/// How a named script executes.
///
/// - [ScriptKind.run]: execute once with cwd = the Ripple config root
///   (the directory that contains `ripple.yaml`).
/// - [ScriptKind.exec]: execute once per matching package with cwd = that
///   package's directory.
enum ScriptKind {
  /// Run once at the Ripple config root.
  run,

  /// Run once per matching package.
  exec,
}

/// Filters declared on an `exec:` script.
///
/// Stored as data in this layer; filter application happens separately.
class ScriptFilters {
  /// Creates script filters from config.
  const ScriptFilters({
    this.dirExists = const [],
    this.fileExists = const [],
    this.dependsOn = const [],
    this.group,
  });

  /// Relative directory paths that must exist under each package root.
  final List<String> dirExists;

  /// Relative file paths that must exist under each package root.
  final List<String> fileExists;

  /// Direct dependency names that must appear in the package pubspec.
  final List<String> dependsOn;

  /// Named group from `packages.groups`; package must be a member.
  final String? group;
}

/// A named script from the `scripts` map in `ripple.yaml`.
///
/// Exactly one of `run:` or `exec:` is allowed per script (XOR). A `run:`
/// script must not declare `filters`.
class RippleScript {
  /// Creates a validated script entry.
  const RippleScript({
    required this.name,
    required this.kind,
    required this.command,
    this.filters,
  }) : assert(
          kind == ScriptKind.exec || filters == null,
          'run: scripts must not declare filters',
        );

  /// Key under `scripts:` (may contain dots, e.g. `format.ci`).
  final String name;

  /// Whether this script runs once at the root or once per package.
  final ScriptKind kind;

  /// Shell command string from `run:` or `exec:`.
  final String command;

  /// Optional filters; only valid when [kind] is [ScriptKind.exec].
  final ScriptFilters? filters;
}

/// Package discovery settings under `packages:`.
class RipplePackages {
  /// Creates package include/exclude/group settings.
  const RipplePackages({
    this.include = const [],
    this.exclude = const [],
    this.groups = const {},
  });

  /// Glob patterns (relative to the Ripple root) for candidate package dirs.
  final List<String> include;

  /// Glob patterns to subtract from include matches.
  final List<String> exclude;

  /// Named sets of path globs for later group filtering.
  final Map<String, List<String>> groups;
}

/// Typed model for a loaded `ripple.yaml`.
class RippleConfig {
  /// Creates a config bound to the directory that contained `ripple.yaml`.
  const RippleConfig({
    required this.rootPath,
    this.name,
    this.packages = const RipplePackages(),
    this.scripts = const {},
  });

  /// Absolute path of the directory containing `ripple.yaml`.
  final String rootPath;

  /// Optional display name from the top-level `name` key.
  final String? name;

  /// Package include/exclude/group settings.
  final RipplePackages packages;

  /// Named scripts keyed by script id.
  final Map<String, RippleScript> scripts;
}
