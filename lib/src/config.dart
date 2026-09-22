/// Load and validate `ripple.yaml` from a consumer repository.
library;

import 'dart:io';

import 'package:checked_yaml/checked_yaml.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;

import 'git_diff.dart';

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

/// Boolean package filter expression declared on an `exec:` script or preset.
///
/// YAML `filters` / preset bodies are a **list** of single-key maps. A
/// top-level list is an implicit [FilterAnd]. Nested `and` / `or` nodes and
/// [FilterPreset] references are allowed. Flat map
/// `filters: { dirExists: …, match: … }` is rejected.
sealed class FilterExpr {
  /// Creates a filter expression node.
  const FilterExpr();
}

/// Conjunction: every [children] expression must match.
final class FilterAnd extends FilterExpr {
  /// Creates an `and` node.
  const FilterAnd(this.children);

  /// Child expressions (all must match).
  final List<FilterExpr> children;

  @override
  bool operator ==(Object other) =>
      other is FilterAnd && _listEquals(children, other.children);

  @override
  int get hashCode => Object.hashAll(children);
}

/// Disjunction: at least one [children] expression must match.
final class FilterOr extends FilterExpr {
  /// Creates an `or` node.
  const FilterOr(this.children);

  /// Child expressions (any may match).
  final List<FilterExpr> children;

  @override
  bool operator ==(Object other) =>
      other is FilterOr && _listEquals(children, other.children);

  @override
  int get hashCode => Object.hashAll(children);
}

/// Relative directory paths that must all exist under the package root.
final class FilterDirExists extends FilterExpr {
  /// Creates a `dirExists` leaf.
  const FilterDirExists(this.paths);

  /// Relative directory paths (AND within the list).
  final List<String> paths;

  @override
  bool operator ==(Object other) =>
      other is FilterDirExists && _listEquals(paths, other.paths);

  @override
  int get hashCode => Object.hashAll(paths);
}

/// Relative file paths that must all exist under the package root.
final class FilterFileExists extends FilterExpr {
  /// Creates a `fileExists` leaf.
  const FilterFileExists(this.paths);

  /// Relative file paths (AND within the list).
  final List<String> paths;

  @override
  bool operator ==(Object other) =>
      other is FilterFileExists && _listEquals(paths, other.paths);

  @override
  int get hashCode => Object.hashAll(paths);
}

/// Relative directory paths that must all be absent under the package root.
final class FilterNoDirExists extends FilterExpr {
  /// Creates a `noDirExists` leaf.
  const FilterNoDirExists(this.paths);

  /// Relative directory paths (AND within the list).
  final List<String> paths;

  @override
  bool operator ==(Object other) =>
      other is FilterNoDirExists && _listEquals(paths, other.paths);

  @override
  int get hashCode => Object.hashAll(paths);
}

/// Relative file paths that must all be absent under the package root.
final class FilterNoFileExists extends FilterExpr {
  /// Creates a `noFileExists` leaf.
  const FilterNoFileExists(this.paths);

  /// Relative file paths (AND within the list).
  final List<String> paths;

  @override
  bool operator ==(Object other) =>
      other is FilterNoFileExists && _listEquals(paths, other.paths);

  @override
  int get hashCode => Object.hashAll(paths);
}

/// Direct dependency names that must all appear in the package pubspec.
final class FilterDependsOn extends FilterExpr {
  /// Creates a `dependsOn` leaf.
  const FilterDependsOn(this.names);

  /// Dependency names (AND within the list).
  final List<String> names;

  @override
  bool operator ==(Object other) =>
      other is FilterDependsOn && _listEquals(names, other.names);

  @override
  int get hashCode => Object.hashAll(names);
}

/// Named group from `packages.groups`; package must be a member.
final class FilterGroup extends FilterExpr {
  /// Creates a `group` leaf.
  const FilterGroup(this.name);

  /// Group name from `packages.groups`.
  final String name;

  @override
  bool operator ==(Object other) => other is FilterGroup && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// Package-name globs; package must match at least one when [globs] is
/// non-empty.
final class FilterMatch extends FilterExpr {
  /// Creates a `match` leaf.
  const FilterMatch(this.globs);

  /// Package-name globs (OR within the list).
  final List<String> globs;

  @override
  bool operator ==(Object other) =>
      other is FilterMatch && _listEquals(globs, other.globs);

  @override
  int get hashCode => Object.hashAll(globs);
}

/// Package-name globs; package must match none when [globs] is non-empty.
final class FilterNoMatch extends FilterExpr {
  /// Creates a `noMatch` leaf.
  const FilterNoMatch(this.globs);

  /// Package-name globs (OR exclude within the list).
  final List<String> globs;

  @override
  bool operator ==(Object other) =>
      other is FilterNoMatch && _listEquals(globs, other.globs);

  @override
  int get hashCode => Object.hashAll(globs);
}

/// Git `changed` descriptor leaf (`since:`, `range:`, `workdir:`, or bare
/// kinds such as `staged` / `since-latest-tag`).
///
/// [descriptors] is a non-empty list. A package matches when it owns a path
/// from the **union** of all descriptors (path sets merged, then longest-prefix
/// mapped). A YAML string or a single CLI `--changed` becomes a one-element
/// list; a YAML list or repeated `--changed` is the union.
final class FilterChanged extends FilterExpr {
  /// Creates a `changed` leaf from one or more descriptor strings.
  const FilterChanged(this.descriptors);

  /// Descriptor strings, for example `since:origin/main` or `workdir:HEAD`.
  final List<String> descriptors;

  @override
  bool operator ==(Object other) =>
      other is FilterChanged && _listEquals(descriptors, other.descriptors);

  @override
  int get hashCode => Object.hashAll(descriptors);
}

/// Allowed YAML / CLI `sdk` filter values (`dart` or `flutter`).
const packageSdkDart = 'dart';

/// Flutter SDK label when `environment.flutter` is present in pubspec.
const packageSdkFlutter = 'flutter';

/// Valid values for [FilterSdk] / `--sdk`.
const packageSdkValues = [packageSdkDart, packageSdkFlutter];

/// Package SDK kind from pubspec `environment` (`dart` or `flutter`).
///
/// Flutter means `environment.flutter` is set. A `flutter` SDK dependency
/// alone does **not** count — that remains a separate `dependsOn` leaf.
final class FilterSdk extends FilterExpr {
  /// Creates an `sdk` leaf. [sdk] must be [packageSdkDart] or
  /// [packageSdkFlutter].
  const FilterSdk(this.sdk);

  /// Target SDK label (`dart` or `flutter`).
  final String sdk;

  @override
  bool operator ==(Object other) => other is FilterSdk && other.sdk == sdk;

  @override
  int get hashCode => sdk.hashCode;
}

/// Whether the package's `dart pub get` output looks stale.
///
/// When [needsPubGet] is `true`, the package matches if
/// `.dart_tool/package_config.json` is missing or older than that package's
/// `pubspec.yaml` / `pubspec.lock`. When `false`, it matches the complement.
/// Comparison is per-package files only (no root workspace lock).
final class FilterNeedsPubGet extends FilterExpr {
  /// Creates a `needsPubGet` leaf.
  const FilterNeedsPubGet(this.needsPubGet);

  /// When `true`, match packages that need `pub get`; when `false`, match
  /// packages that do not.
  final bool needsPubGet;

  @override
  bool operator ==(Object other) =>
      other is FilterNeedsPubGet && other.needsPubGet == needsPubGet;

  @override
  int get hashCode => needsPubGet.hashCode;
}

/// Reference to a named expression under `packages.filtersPresets`.
///
/// Resolved (with cycle detection) before evaluation; see
/// [resolveFilterPresets] in `filters.dart`.
final class FilterPreset extends FilterExpr {
  /// Creates a `preset` node.
  const FilterPreset(this.name);

  /// Preset name from `packages.filtersPresets`.
  final String name;

  @override
  bool operator ==(Object other) => other is FilterPreset && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Expansion of a dependents or dependencies closure on an `exec:` script.
///
/// Constructed only when the YAML key (`dependentsFilters` /
/// `dependenciesFilters`) is **present**. A null [expression] means the key
/// was an empty list (`[]`) — take the full transitive closure. A non-null
/// [expression] keeps only packages from that closure that match the AST.
final class GraphExpansionFilters {
  /// Creates expansion filters; omit [expression] for an exhaustive closure.
  const GraphExpansionFilters({this.expression});

  /// Constraint on the closure, or `null` for an exhaustive (`[]`) expansion.
  final FilterExpr? expression;

  @override
  bool operator ==(Object other) =>
      other is GraphExpansionFilters && other.expression == expression;

  @override
  int get hashCode => expression.hashCode;
}

/// A named script from the `scripts` map in `ripple.yaml`.
///
/// Exactly one of `run:` or `exec:` is allowed per script (XOR). A `run:`
/// script must not declare `filters`, `dependentsFilters`, or
/// `dependenciesFilters`.
///
/// [commands] is one or more argv command strings run sequentially (fail-fast
/// between steps). A bare string in YAML is normalized to a single-element
/// list; a YAML list is multiple steps.
///
/// Optional [description] is documentation only; it is not used when running
/// the script.
///
/// Optional [quiet] omits banners and child stdio for successful packages
/// (`exec:`) or successful root steps (`run:`). CLI `--quiet` enables the same
/// behavior and wins when both are set.
///
/// Optional [concurrency] bounds how many packages run at once for `exec:`
/// scripts (`null` means absent → default 1 at run time). Invalid on `run:`
/// scripts. CLI `--concurrency` wins when both are set.
///
/// Optional [order] selects package scheduling for `exec:` (`null` means
/// absent → `path` at run time). Invalid on `run:` scripts. CLI `--order`
/// wins when both are set.
class RippleScript {
  /// Creates a validated script entry.
  const RippleScript({
    required this.name,
    required this.kind,
    required this.commands,
    this.filters,
    this.dependentsFilters,
    this.dependenciesFilters,
    this.description,
    this.quiet = false,
    this.concurrency,
    this.order,
  }) : assert(
          kind == ScriptKind.exec ||
              (filters == null &&
                  dependentsFilters == null &&
                  dependenciesFilters == null &&
                  concurrency == null &&
                  order == null),
          'run: scripts must not declare filters, expansion keys, '
          'concurrency, or order',
        );

  /// Key under `scripts:` (may contain dots, e.g. `format.ci`).
  final String name;

  /// Whether this script runs once at the root or once per package.
  final ScriptKind kind;

  /// Optional one-line summary from `description:` (ignored by `ripple run`).
  final String? description;

  /// When `true`, successful packages / root steps stay silent (see CLI
  /// `--quiet`). Failed packages / steps still print banners and child output.
  final bool quiet;

  /// Max in-flight packages for `exec:` (see CLI `--concurrency`).
  ///
  /// `null` means the YAML key is absent (default 1 at run time). Only valid
  /// for [ScriptKind.exec]; must be at least 1 when set.
  final int? concurrency;

  /// Package scheduling for `exec:` (see CLI `--order`).
  ///
  /// `null` means the YAML key is absent (default `path` at run time). Only
  /// valid for [ScriptKind.exec]. Allowed values: `path`, `layers`.
  final String? order;

  /// Command strings from `run:` or `exec:` (string or YAML list).
  ///
  /// Each entry is split into an executable plus arguments at execution time.
  /// Steps run in order and stop on the first non-zero exit.
  final List<String> commands;

  /// Optional seed filter expression; only valid when [kind] is
  /// [ScriptKind.exec].
  final FilterExpr? filters;

  /// Optional dependents expansion; only valid for [ScriptKind.exec].
  ///
  /// `null` means the YAML key is absent (do not expand). See
  /// [GraphExpansionFilters].
  final GraphExpansionFilters? dependentsFilters;

  /// Optional dependencies expansion; only valid for [ScriptKind.exec].
  ///
  /// `null` means the YAML key is absent (do not expand). See
  /// [GraphExpansionFilters].
  final GraphExpansionFilters? dependenciesFilters;
}

/// One `packages.include` entry: a path glob or a Dart workspace expansion.
sealed class PackageIncludeEntry {
  /// Creates an include entry.
  const PackageIncludeEntry();
}

/// Include directories matching a glob relative to the Ripple root.
final class PackageIncludeGlob extends PackageIncludeEntry {
  /// Creates a glob include entry.
  const PackageIncludeGlob(this.pattern);

  /// Glob pattern (posix `/` separators) relative to the Ripple root.
  final String pattern;

  @override
  bool operator ==(Object other) =>
      other is PackageIncludeGlob && other.pattern == pattern;

  @override
  int get hashCode => pattern.hashCode;
}

/// Include a Dart workspace root and all of its transitive members.
final class PackageIncludeWorkspace extends PackageIncludeEntry {
  /// Creates a workspace include entry for [path] (Ripple-root relative).
  const PackageIncludeWorkspace(this.path);

  /// Repo-relative path to the Dart workspace root directory.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is PackageIncludeWorkspace && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// Package discovery settings under `packages:`.
class RipplePackages {
  /// Creates package include/exclude/group/preset settings.
  const RipplePackages({
    this.include = const [],
    this.exclude = const [],
    this.groups = const {},
    this.filtersPresets = const {},
    this.changedIgnore = const [],
  });

  /// Include entries (globs and/or `workspace:` expansions) relative to the
  /// Ripple root.
  final List<PackageIncludeEntry> include;

  /// Glob patterns to subtract from include matches.
  final List<String> exclude;

  /// Named sets of path globs for group filtering.
  final Map<String, List<String>> groups;

  /// Named filter expression fragments for `preset:` nodes and `--preset`.
  ///
  /// Each value is a list-form filter expression (implicit [FilterAnd]).
  final Map<String, FilterExpr> filtersPresets;

  /// Repo-relative path globs ignored by `changed` path-to-package mapping.
  ///
  /// Matching changed files are dropped before longest-prefix ownership.
  final List<String> changedIgnore;
}

/// A filter-scoped overlay of [RippleConfig.replacements].
///
/// The first matching override wins. Unmentioned keys fall through to the
/// global map (shallow merge).
class ReplacementOverride {
  /// Creates a filter-scoped replacements overlay.
  const ReplacementOverride({
    required this.filters,
    required this.replacements,
  });

  /// Package filter expression (list-form AST, same as script `filters`).
  final FilterExpr filters;

  /// Replacement keys to overlay when [filters] matches.
  final Map<String, String> replacements;

  @override
  bool operator ==(Object other) =>
      other is ReplacementOverride &&
      other.filters == filters &&
      _mapEquals(other.replacements, replacements);

  @override
  int get hashCode => Object.hash(
        filters,
        Object.hashAll(
          replacements.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

/// Typed model for a loaded `ripple.yaml`.
class RippleConfig {
  /// Creates a config bound to the directory that contained `ripple.yaml`.
  const RippleConfig({
    required this.rootPath,
    this.name,
    this.packages = const RipplePackages(),
    this.scripts = const {},
    this.replacements = const {},
    this.replacementOverrides = const [],
  });

  /// Absolute path of the directory containing `ripple.yaml`.
  final String rootPath;

  /// Optional display name from the top-level `name` key.
  final String? name;

  /// Package include/exclude/group/preset settings.
  final RipplePackages packages;

  /// Named scripts keyed by script id.
  final Map<String, RippleScript> scripts;

  /// Named command aliases expanded from `{{key}}` placeholders.
  ///
  /// Values are command strings, parsed like `run:` / `exec:` steps (may be
  /// multiple tokens). Keys must not be empty or start with `RIPPLE_`.
  final Map<String, String> replacements;

  /// Filter-scoped overlays applied to [replacements] for `exec` / `exec:`.
  ///
  /// First matching entry wins. `run:` scripts ignore this list.
  final List<ReplacementOverride> replacementOverrides;
}

/// File name sought when discovering the Ripple config root.
const rippleYamlFileName = 'ripple.yaml';

/// Optional host overlay next to [rippleYamlFileName] (Ripple root only).
const rippleOverridesFileName = 'ripple_overrides.yaml';

/// Environment variable with the same grammar as `--override`.
const rippleOverrideEnvVar = 'RIPPLE_OVERRIDE';

/// CLI option name for `--override`.
const overrideOptionName = 'override';

/// How to pick at most one overlay file.
sealed class OverlayDescriptor {
  /// Creates an overlay descriptor.
  const OverlayDescriptor();
}

/// Load no overlay (`{{key}}` still comes from `ripple.yaml`).
final class OverlayNone extends OverlayDescriptor {
  /// Creates a `none` descriptor.
  const OverlayNone();
}

/// Load [rippleOverridesFileName] if it exists (absence is not an error).
final class OverlayDefault extends OverlayDescriptor {
  /// Creates a `default` descriptor.
  const OverlayDefault();
}

/// Load exactly this overlay file (missing file is an error).
final class OverlayFile extends OverlayDescriptor {
  /// Creates a `file:<path>` descriptor. [path] is the remainder after `file:`.
  const OverlayFile(this.path);

  /// Path from the descriptor (`file:` prefix already stripped).
  final String path;
}

/// Parses `none`, `default`, or `file:<path>`.
///
/// Unprefixed paths, unknown prefixes, and empty `file:` throw
/// [RippleConfigException].
OverlayDescriptor parseOverlayDescriptor(String raw) {
  final trimmed = raw.trim();
  if (trimmed == 'none') {
    return const OverlayNone();
  }
  if (trimmed == 'default') {
    return const OverlayDefault();
  }
  if (trimmed.startsWith('file:')) {
    final path = trimmed.substring('file:'.length);
    if (path.trim().isEmpty) {
      throw const RippleConfigException(
        'Overlay descriptor `file:` must include a path',
      );
    }
    return OverlayFile(path.trim());
  }
  throw RippleConfigException(
    'Invalid overlay descriptor "$raw". Expected `none`, `default`, or '
    '`file:<path>`',
  );
}

/// Resolves `--override` over [rippleOverrideEnvVar].
///
/// A missing CLI value falls through to a non-empty env value. An empty or
/// whitespace-only env string is treated as unset. Returns `null` when
/// neither is set (callers then use the default auto-load).
OverlayDescriptor? overlayDescriptorFromSources({
  String? cli,
  String? env,
}) {
  if (cli != null) {
    return parseOverlayDescriptor(cli);
  }
  if (env != null && env.trim().isNotEmpty) {
    return parseOverlayDescriptor(env);
  }
  return null;
}

/// Reads [rippleOverrideEnvVar] and optional CLI [cli] into a descriptor.
OverlayDescriptor? resolveOverlayDescriptor({String? cli}) {
  return overlayDescriptorFromSources(
    cli: cli,
    env: Platform.environment[rippleOverrideEnvVar],
  );
}

/// Overlay document that may contain only `replacements` and/or
/// `replacementOverrides`.
class RippleOverlay {
  /// Creates an overlay fragment.
  const RippleOverlay({
    this.replacements = const {},
    this.replacementOverrides = const [],
  });

  /// Keys that replace matching entries in [RippleConfig.replacements].
  final Map<String, String> replacements;

  /// Override entries prepended ahead of [RippleConfig.replacementOverrides].
  final List<ReplacementOverride> replacementOverrides;
}

/// Merges [overlay] onto [base] (replacement keys replace; overrides prepend).
RippleConfig applyRippleOverlay(RippleConfig base, RippleOverlay overlay) {
  return RippleConfig(
    rootPath: base.rootPath,
    name: base.name,
    packages: base.packages,
    scripts: base.scripts,
    replacements: Map<String, String>.unmodifiable({
      ...base.replacements,
      ...overlay.replacements,
    }),
    replacementOverrides: List<ReplacementOverride>.unmodifiable([
      ...overlay.replacementOverrides,
      ...base.replacementOverrides,
    ]),
  );
}

/// Loads [rippleOverridesFileName] from [config.rootPath] when it exists.
///
/// Missing file is not an error. A present file is parsed as an overlay and
/// merged via [applyRippleOverlay].
RippleConfig mergeDefaultRippleOverlay(RippleConfig config) {
  return _mergeOverlayFile(
    config,
    p.join(config.rootPath, rippleOverridesFileName),
    required: false,
  );
}

/// Applies [descriptor], defaulting to [OverlayDefault] when [descriptor] is
/// null.
RippleConfig applyOverlayDescriptor(
  RippleConfig config,
  OverlayDescriptor? descriptor,
) {
  final resolved = descriptor ?? const OverlayDefault();
  return switch (resolved) {
    OverlayNone() => config,
    OverlayDefault() => mergeDefaultRippleOverlay(config),
    OverlayFile(:final path) => _mergeOverlayFile(
        config,
        p.isAbsolute(path) ? path : p.join(config.rootPath, path),
        required: true,
      ),
  };
}

RippleConfig _mergeOverlayFile(
  RippleConfig config,
  String overlayPath, {
  required bool required,
}) {
  final file = File(overlayPath);
  if (!file.existsSync()) {
    if (required) {
      throw RippleConfigException(
        'Overlay file not found: $overlayPath',
      );
    }
    return config;
  }
  late final String contents;
  try {
    contents = file.readAsStringSync();
  } on FileSystemException catch (error) {
    throw RippleConfigException(
      'Failed to read $overlayPath: ${error.message}',
    );
  }
  return applyRippleOverlay(
    config,
    parseRippleOverridesYaml(
      contents,
      sourceUrl: p.toUri(overlayPath),
    ),
  );
}

/// Walks upward from [start] until a `ripple.yaml` is found.
///
/// Returns the absolute path of that file. Throws [RippleConfigException] if
/// none exists between [start] and the filesystem root.
String findRippleYamlPath({Directory? start}) {
  var dir = (start ?? Directory.current).absolute;
  while (true) {
    final candidate = File(p.join(dir.path, rippleYamlFileName));
    if (candidate.existsSync()) {
      return candidate.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw RippleConfigException(
        'No $rippleYamlFileName found from ${start?.path ?? Directory.current.path} '
        'up to the filesystem root.',
      );
    }
    dir = parent;
  }
}

/// Loads, parses, and validates the nearest ancestor `ripple.yaml`.
///
/// The returned [RippleConfig.rootPath] is the directory containing that file.
/// [overlay] selects which overlay file to merge; `null` uses [OverlayDefault].
RippleConfig loadRippleConfig({
  Directory? start,
  OverlayDescriptor? overlay,
}) {
  final yamlPath = findRippleYamlPath(start: start);
  final file = File(yamlPath);
  late final String contents;
  try {
    contents = file.readAsStringSync();
  } on FileSystemException catch (error) {
    throw RippleConfigException(
      'Failed to read $yamlPath: ${error.message}',
    );
  }
  return applyOverlayDescriptor(
    parseRippleYaml(
      contents,
      rootPath: p.dirname(yamlPath),
      sourceUrl: p.toUri(yamlPath),
    ),
    overlay,
  );
}

/// Parses and validates [yamlContent] as a `ripple.yaml` document.
///
/// [rootPath] is the directory that contains the config file (not the file
/// path itself). Throws [RippleConfigException] for invalid YAML or schema
/// violations (including script `run`/`exec` XOR and `filters` /
/// expansion keys on `run:`).
/// Parses an overlay YAML document (`replacements` / `replacementOverrides`).
///
/// Any other top-level key is rejected.
RippleOverlay parseRippleOverridesYaml(
  String yamlContent, {
  Uri? sourceUrl,
}) {
  try {
    return checkedYamlDecode(
      yamlContent,
      (Map<dynamic, dynamic>? map) {
        if (map == null) {
          throw CheckedFromJsonException(
            <String, dynamic>{},
            null,
            'RippleOverlay',
            'overlay YAML must be a non-null YAML map',
          );
        }
        return _overlayFromMap(map);
      },
      sourceUrl: sourceUrl,
    );
  } on ParsedYamlException catch (error) {
    throw RippleConfigException(_parsedYamlMessage(error));
  } on CheckedFromJsonException catch (error) {
    throw RippleConfigException(_checkedFromJsonMessage(error));
  }
}

RippleOverlay _overlayFromMap(Map<dynamic, dynamic> map) {
  for (final key in map.keys) {
    if (key != 'replacements' && key != 'replacementOverrides') {
      throw CheckedFromJsonException(
        map,
        key?.toString(),
        'RippleOverlay',
        'Overlay files may contain only `replacements` and/or '
            '`replacementOverrides`',
      );
    }
  }
  return RippleOverlay(
    replacements: _replacementsFromValue(map['replacements'], map),
    replacementOverrides:
        _replacementOverridesFromValue(map['replacementOverrides'], map),
  );
}

RippleConfig parseRippleYaml(
  String yamlContent, {
  required String rootPath,
  Uri? sourceUrl,
}) {
  try {
    return checkedYamlDecode(
      yamlContent,
      (Map<dynamic, dynamic>? map) {
        if (map == null) {
          throw CheckedFromJsonException(
            <String, dynamic>{},
            null,
            'RippleConfig',
            'ripple.yaml must be a non-null YAML map',
          );
        }
        return _configFromMap(map, rootPath: rootPath);
      },
      sourceUrl: sourceUrl,
    );
  } on ParsedYamlException catch (error) {
    throw RippleConfigException(_parsedYamlMessage(error));
  } on CheckedFromJsonException catch (error) {
    throw RippleConfigException(_checkedFromJsonMessage(error));
  }
}

RippleConfig _configFromMap(
  Map<dynamic, dynamic> map, {
  required String rootPath,
}) {
  final name = _optionalString(map, 'name', 'RippleConfig');
  final packages = _packagesFromValue(map['packages'], map);
  final scripts = _scriptsFromValue(map['scripts'], map);
  final replacements = _replacementsFromValue(map['replacements'], map);
  final replacementOverrides =
      _replacementOverridesFromValue(map['replacementOverrides'], map);
  return RippleConfig(
    rootPath: rootPath,
    name: name,
    packages: packages,
    scripts: scripts,
    replacements: replacements,
    replacementOverrides: replacementOverrides,
  );
}

List<ReplacementOverride> _replacementOverridesFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw CheckedFromJsonException(
      parent,
      'replacementOverrides',
      'RippleConfig',
      'Expected a list of filter-scoped replacement overlays',
    );
  }
  return List<ReplacementOverride>.unmodifiable([
    for (var i = 0; i < value.length; i++)
      _replacementOverrideFromValue(
        value[i],
        parent,
        index: i,
      ),
  ]);
}

ReplacementOverride _replacementOverrideFromValue(
  Object? value,
  Map<dynamic, dynamic> parent, {
  required int index,
}) {
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'replacementOverrides',
      'RippleConfig',
      'replacementOverrides[$index] must be a map with `filters` and '
          '`replacements`',
    );
  }
  final Map<dynamic, dynamic> map = value;
  if (!map.containsKey('filters')) {
    throw CheckedFromJsonException(
      map,
      'filters',
      'ReplacementOverride',
      'replacementOverrides[$index] must declare `filters`',
    );
  }
  if (!map.containsKey('replacements')) {
    throw CheckedFromJsonException(
      map,
      'replacements',
      'ReplacementOverride',
      'replacementOverrides[$index] must declare `replacements`',
    );
  }
  final filters = _filtersFromValue(
    map['filters'],
    map,
    keyName: 'filters',
    className: 'ReplacementOverride',
    emptyListMessage:
        'replacementOverrides[$index] `filters` must be a non-empty list of '
        'filter expressions',
  );
  if (filters == null) {
    throw CheckedFromJsonException(
      map,
      'filters',
      'ReplacementOverride',
      'replacementOverrides[$index] `filters` must be a non-empty list of '
          'filter expressions',
    );
  }
  return ReplacementOverride(
    filters: filters,
    replacements: _replacementsFromValue(map['replacements'], map),
  );
}

Map<String, String> _replacementsFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const {};
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'replacements',
      'RippleConfig',
      'Expected a map of replacement name to command string',
    );
  }
  final replacements = <String, String>{};
  final Map<dynamic, dynamic> map = value;
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw CheckedFromJsonException(
        map,
        key?.toString(),
        'RippleConfig',
        'Replacement names must be strings',
      );
    }
    final trimmedKey = key.trim();
    if (trimmedKey.isEmpty) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleConfig',
        'Replacement names must be non-empty strings',
      );
    }
    if (trimmedKey.startsWith('RIPPLE_')) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleConfig',
        'Replacement name "$trimmedKey" is reserved; keys must not start '
            'with RIPPLE_',
      );
    }
    if (replacements.containsKey(trimmedKey)) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleConfig',
        'Replacement name "$trimmedKey" is duplicated',
      );
    }
    final replacementValue = entry.value;
    if (replacementValue is! String) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleConfig',
        'Replacement "$trimmedKey" must be a command string',
      );
    }
    if (replacementValue.trim().isEmpty) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleConfig',
        'Replacement "$trimmedKey" must be a non-empty command string',
      );
    }
    if (_containsUnquotedAnd(replacementValue)) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleConfig',
        'Replacement "$trimmedKey" must not contain unquoted `&&`. '
            "Wrap shell compound commands in `sh -c '…'`.",
      );
    }
    replacements[trimmedKey] = replacementValue;
  }
  return Map<String, String>.unmodifiable(replacements);
}

RipplePackages _packagesFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const RipplePackages();
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'packages',
      'RippleConfig',
      'Expected a map',
    );
  }
  final Map<dynamic, dynamic> map = value;
  return RipplePackages(
    include: _includeEntriesFromValue(map['include'], map),
    exclude: _stringList(map, 'exclude', 'RipplePackages'),
    groups: _groupsFromValue(map['groups'], map),
    filtersPresets: _filtersPresetsFromValue(map['filtersPresets'], map),
    changedIgnore: _stringList(map, 'changedIgnore', 'RipplePackages'),
  );
}

List<PackageIncludeEntry> _includeEntriesFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw CheckedFromJsonException(
      parent,
      'include',
      'RipplePackages',
      'Expected a list of glob strings and/or `{ workspace: <path> }` maps',
    );
  }
  final entries = <PackageIncludeEntry>[];
  for (var i = 0; i < value.length; i++) {
    final element = value[i];
    if (element is String) {
      entries.add(PackageIncludeGlob(element));
      continue;
    }
    if (element is Map) {
      final Map<dynamic, dynamic> map = element;
      if (map.length != 1 || !map.containsKey('workspace')) {
        throw CheckedFromJsonException(
          parent,
          'include',
          'RipplePackages',
          'include[$i] map must be a single-key `{ workspace: <path> }`',
        );
      }
      final path = map['workspace'];
      if (path is! String || path.trim().isEmpty) {
        throw CheckedFromJsonException(
          parent,
          'include',
          'RipplePackages',
          'include[$i].workspace must be a non-empty string path',
        );
      }
      entries.add(PackageIncludeWorkspace(path.trim()));
      continue;
    }
    throw CheckedFromJsonException(
      parent,
      'include',
      'RipplePackages',
      'include[$i] must be a glob string or `{ workspace: <path> }`',
    );
  }
  return List<PackageIncludeEntry>.unmodifiable(entries);
}

Map<String, FilterExpr> _filtersPresetsFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const {};
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'filtersPresets',
      'RipplePackages',
      'Expected a map of preset name to filter expression lists',
    );
  }
  final presets = <String, FilterExpr>{};
  final Map<dynamic, dynamic> map = value;
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw CheckedFromJsonException(
        map,
        key?.toString(),
        'RipplePackages',
        'Filter preset names must be strings',
      );
    }
    final expression = _filtersFromValue(
      entry.value,
      map,
      keyName: key,
      className: 'RipplePackages.filtersPresets',
      emptyListMessage: 'Filter preset "$key" must be a non-empty list of '
          'filter expressions',
    );
    if (expression == null) {
      throw CheckedFromJsonException(
        map,
        key,
        'RipplePackages.filtersPresets',
        'Filter preset "$key" must be a non-empty list of filter expressions',
      );
    }
    presets[key] = expression;
  }
  return Map<String, FilterExpr>.unmodifiable(presets);
}

Map<String, List<String>> _groupsFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const {};
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'groups',
      'RipplePackages',
      'Expected a map of group name to path-glob lists',
    );
  }
  final groups = <String, List<String>>{};
  final Map<dynamic, dynamic> map = value;
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw CheckedFromJsonException(
        map,
        key?.toString(),
        'RipplePackages',
        'Group names must be strings',
      );
    }
    groups[key] = _stringListAt(
      map,
      key,
      entry.value,
      'RipplePackages.groups',
    );
  }
  return Map<String, List<String>>.unmodifiable(groups);
}

Map<String, RippleScript> _scriptsFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const {};
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'scripts',
      'RippleConfig',
      'Expected a map of script name to script definition',
    );
  }
  final scripts = <String, RippleScript>{};
  final Map<dynamic, dynamic> map = value;
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw CheckedFromJsonException(
        map,
        key?.toString(),
        'RippleConfig',
        'Script names must be strings',
      );
    }
    scripts[key] = _scriptFromValue(key, entry.value, map);
  }
  return Map<String, RippleScript>.unmodifiable(scripts);
}

RippleScript _scriptFromValue(
  String name,
  Object? value,
  Map<dynamic, dynamic> scriptsMap,
) {
  if (value is! Map) {
    throw CheckedFromJsonException(
      scriptsMap,
      name,
      'RippleScript',
      'Script "$name" must be a map',
    );
  }
  final Map<dynamic, dynamic> map = value;
  final hasRun = map['run'] != null;
  final hasExec = map['exec'] != null;

  if (hasRun == hasExec) {
    throw CheckedFromJsonException(
      map,
      hasRun ? 'run' : 'exec',
      'RippleScript',
      'Script "$name" must declare exactly one of `run:` or `exec:`',
    );
  }

  final filtersValue = map['filters'];
  final hasDependentsFilters = map.containsKey('dependentsFilters');
  final hasDependenciesFilters = map.containsKey('dependenciesFilters');
  final hasConcurrency = map.containsKey('concurrency');
  final hasOrder = map.containsKey('order');
  if (hasRun) {
    if (filtersValue != null) {
      throw CheckedFromJsonException(
        map,
        'filters',
        'RippleScript',
        'Script "$name" uses `run:` and must not declare `filters`',
      );
    }
    if (hasDependentsFilters) {
      throw CheckedFromJsonException(
        map,
        'dependentsFilters',
        'RippleScript',
        'Script "$name" uses `run:` and must not declare `dependentsFilters`',
      );
    }
    if (hasDependenciesFilters) {
      throw CheckedFromJsonException(
        map,
        'dependenciesFilters',
        'RippleScript',
        'Script "$name" uses `run:` and must not declare '
            '`dependenciesFilters`',
      );
    }
    if (hasConcurrency) {
      throw CheckedFromJsonException(
        map,
        'concurrency',
        'RippleScript',
        'Script "$name" uses `run:` and must not declare `concurrency`',
      );
    }
    if (hasOrder) {
      throw CheckedFromJsonException(
        map,
        'order',
        'RippleScript',
        'Script "$name" uses `run:` and must not declare `order`',
      );
    }
  }

  final kindKey = hasRun ? 'run' : 'exec';
  final commands = _commandsFromValue(
    map[kindKey],
    map: map,
    key: kindKey,
    scriptName: name,
  );
  final description = _scriptDescriptionFromValue(map, name);
  final quiet = _scriptQuietFromValue(map, name);
  final concurrency = hasExec ? _scriptConcurrencyFromValue(map, name) : null;
  final order = hasExec ? _scriptOrderFromValue(map, name) : null;

  return RippleScript(
    name: name,
    kind: hasRun ? ScriptKind.run : ScriptKind.exec,
    commands: commands,
    description: description,
    quiet: quiet,
    concurrency: concurrency,
    order: order,
    filters: hasExec
        ? _filtersFromValue(
            filtersValue,
            map,
            keyName: 'filters',
            className: 'RippleScript',
          )
        : null,
    dependentsFilters: hasExec
        ? _graphExpansionFromValue(
            map['dependentsFilters'],
            map,
            keyName: 'dependentsFilters',
            keyPresent: hasDependentsFilters,
            scriptName: name,
          )
        : null,
    dependenciesFilters: hasExec
        ? _graphExpansionFromValue(
            map['dependenciesFilters'],
            map,
            keyName: 'dependenciesFilters',
            keyPresent: hasDependenciesFilters,
            scriptName: name,
          )
        : null,
  );
}

/// Parses `dependentsFilters` / `dependenciesFilters` with absent / `[]` /
/// constrained semantics.
///
/// Returns `null` when [keyPresent] is false. An empty list yields
/// [GraphExpansionFilters] with a null expression (exhaustive closure).
GraphExpansionFilters? _graphExpansionFromValue(
  Object? value,
  Map<dynamic, dynamic> parent, {
  required String keyName,
  required bool keyPresent,
  required String scriptName,
}) {
  if (!keyPresent) {
    return null;
  }
  if (value == null) {
    throw CheckedFromJsonException(
      parent,
      keyName,
      'RippleScript',
      'Script "$scriptName" `$keyName` must be a list of filter expressions '
          '(use `[]` for an exhaustive closure)',
    );
  }
  if (value is Map) {
    throw CheckedFromJsonException(
      parent,
      keyName,
      'RippleScript',
      'Expected a list of filter expressions; map-form filters are not '
          'supported. Use a YAML list of single-key maps, or `[]` for an '
          'exhaustive closure',
    );
  }
  if (value is! List) {
    throw CheckedFromJsonException(
      parent,
      keyName,
      'RippleScript',
      'Expected a list of filter expressions',
    );
  }
  if (value.isEmpty) {
    return const GraphExpansionFilters();
  }
  return GraphExpansionFilters(
    expression: _filtersFromValue(
      value,
      parent,
      keyName: keyName,
      className: 'RippleScript',
    ),
  );
}

/// Parses optional `description:` as a non-empty single-line string.
String? _scriptDescriptionFromValue(
  Map<dynamic, dynamic> map,
  String scriptName,
) {
  final value = map['description'];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw CheckedFromJsonException(
      map,
      'description',
      'RippleScript',
      'Script "$scriptName" `description:` must be a string',
    );
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw CheckedFromJsonException(
      map,
      'description',
      'RippleScript',
      'Script "$scriptName" `description:` must be a non-empty string',
    );
  }
  if (RegExp(r'[\r\n]').hasMatch(trimmed)) {
    throw CheckedFromJsonException(
      map,
      'description',
      'RippleScript',
      'Script "$scriptName" `description:` must be a single line',
    );
  }
  return trimmed;
}

/// Parses optional `quiet:` as a boolean (absent → `false`).
bool _scriptQuietFromValue(
  Map<dynamic, dynamic> map,
  String scriptName,
) {
  final value = map['quiet'];
  if (value == null) {
    return false;
  }
  if (value is! bool) {
    throw CheckedFromJsonException(
      map,
      'quiet',
      'RippleScript',
      'Script "$scriptName" `quiet:` must be a boolean',
    );
  }
  return value;
}

/// Parses optional `concurrency:` as an int ≥ 1 (absent → `null`).
int? _scriptConcurrencyFromValue(
  Map<dynamic, dynamic> map,
  String scriptName,
) {
  if (!map.containsKey('concurrency')) {
    return null;
  }
  final value = map['concurrency'];
  if (value is! int) {
    throw CheckedFromJsonException(
      map,
      'concurrency',
      'RippleScript',
      'Script "$scriptName" `concurrency:` must be an integer',
    );
  }
  if (value < 1) {
    throw CheckedFromJsonException(
      map,
      'concurrency',
      'RippleScript',
      'Script "$scriptName" `concurrency:` must be at least 1',
    );
  }
  return value;
}

/// Parses optional `order:` as `path` or `layers` (absent → `null`).
String? _scriptOrderFromValue(
  Map<dynamic, dynamic> map,
  String scriptName,
) {
  if (!map.containsKey('order')) {
    return null;
  }
  final value = map['order'];
  if (value is! String) {
    throw CheckedFromJsonException(
      map,
      'order',
      'RippleScript',
      'Script "$scriptName" `order:` must be a string',
    );
  }
  final trimmed = value.trim();
  if (trimmed != 'path' && trimmed != 'layers') {
    throw CheckedFromJsonException(
      map,
      'order',
      'RippleScript',
      'Script "$scriptName" `order:` must be "path" or "layers"',
    );
  }
  return trimmed;
}

/// Parses a `run:` / `exec:` value as a non-empty string or list of strings.
///
/// Rejects empty lists, non-string items, blank command strings, and command
/// strings that contain unquoted `&&` (use a YAML list instead, or `sh -c`
/// when a real shell is required).
List<String> _commandsFromValue(
  Object? value, {
  required Map<dynamic, dynamic> map,
  required String key,
  required String scriptName,
}) {
  late final List<String> raw;
  if (value is String) {
    raw = [value];
  } else if (value is List) {
    if (value.isEmpty) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleScript',
        'Script "$scriptName" `$key:` must be a non-empty string or list',
      );
    }
    raw = <String>[];
    for (var i = 0; i < value.length; i++) {
      final element = value[i];
      if (element is! String) {
        throw CheckedFromJsonException(
          map,
          key,
          'RippleScript',
          'Script "$scriptName" `$key:` must be a string or list of strings '
              '(index $i)',
        );
      }
      raw.add(element);
    }
  } else {
    throw CheckedFromJsonException(
      map,
      key,
      'RippleScript',
      'Script "$scriptName" `$key:` must be a string or list of strings',
    );
  }

  final commands = <String>[];
  for (var i = 0; i < raw.length; i++) {
    final command = raw[i];
    if (command.trim().isEmpty) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleScript',
        raw.length == 1
            ? 'Script "$scriptName" command must be a non-empty string'
            : 'Script "$scriptName" `$key:` step ${i + 1} must be a non-empty '
                'string',
      );
    }
    if (_containsUnquotedAnd(command)) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleScript',
        'Script "$scriptName" command must not contain unquoted `&&`. '
            'Use a YAML list of steps under `$key:`, or wrap shell compound '
            "commands in `sh -c '…'`.",
      );
    }
    commands.add(command);
  }

  return List<String>.unmodifiable(commands);
}

/// Returns true when [command] contains `&&` outside of single/double quotes.
bool _containsUnquotedAnd(String command) {
  var inSingle = false;
  var inDouble = false;
  var escape = false;

  for (var i = 0; i < command.length; i++) {
    final char = command[i];

    if (escape) {
      escape = false;
      continue;
    }

    if (char == r'\' && !inSingle) {
      escape = true;
      continue;
    }

    if (char == "'" && !inDouble) {
      inSingle = !inSingle;
      continue;
    }

    if (char == '"' && !inSingle) {
      inDouble = !inDouble;
      continue;
    }

    if (!inSingle &&
        !inDouble &&
        char == '&' &&
        i + 1 < command.length &&
        command[i + 1] == '&') {
      return true;
    }
  }

  return false;
}

FilterExpr? _filtersFromValue(
  Object? value,
  Map<dynamic, dynamic> parent, {
  String keyName = 'filters',
  String className = 'RippleScript',
  String? emptyListMessage,
}) {
  if (value == null) {
    return null;
  }
  if (value is Map) {
    throw CheckedFromJsonException(
      parent,
      keyName,
      className,
      'Expected a list of filter expressions; map-form filters are not '
      'supported. Use a YAML list of single-key maps, e.g. '
      '`filters: [{ dirExists: [lib] }, { match: ["*_api"] }]`',
    );
  }
  if (value is! List) {
    throw CheckedFromJsonException(
      parent,
      keyName,
      className,
      'Expected a list of filter expressions',
    );
  }
  if (value.isEmpty) {
    if (emptyListMessage != null) {
      throw CheckedFromJsonException(
        parent,
        keyName,
        className,
        emptyListMessage,
      );
    }
    return null;
  }
  return FilterAnd(
    List<FilterExpr>.unmodifiable(
      [
        for (var i = 0; i < value.length; i++)
          _filterNodeFromValue(
            value[i],
            parent: parent,
            path: '$keyName[$i]',
          ),
      ],
    ),
  );
}

FilterExpr _filterNodeFromValue(
  Object? value, {
  required Map<dynamic, dynamic> parent,
  required String path,
}) {
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'filters',
      'FilterExpr',
      'Invalid filter at $path: expected a single-key map',
    );
  }
  final Map<dynamic, dynamic> map = value;
  if (map.length != 1) {
    throw CheckedFromJsonException(
      parent,
      'filters',
      'FilterExpr',
      'Invalid filter at $path: expected exactly one key '
          '(and, or, preset, changed, match, noMatch, group, dependsOn, '
          'dirExists, fileExists, noDirExists, noFileExists, sdk, '
          'needsPubGet), '
          'found ${map.length}',
    );
  }
  final entry = map.entries.single;
  final key = entry.key;
  if (key is! String) {
    throw CheckedFromJsonException(
      parent,
      'filters',
      'FilterExpr',
      'Invalid filter at $path: filter keys must be strings',
    );
  }

  switch (key) {
    case 'and':
      return FilterAnd(
          _filterChildrenFromValue(entry.value, parent, path, key));
    case 'or':
      return FilterOr(_filterChildrenFromValue(entry.value, parent, path, key));
    case 'dirExists':
      return FilterDirExists(_filterStringList(entry.value, parent, path, key));
    case 'fileExists':
      return FilterFileExists(
          _filterStringList(entry.value, parent, path, key));
    case 'noDirExists':
      return FilterNoDirExists(
          _filterStringList(entry.value, parent, path, key));
    case 'noFileExists':
      return FilterNoFileExists(
          _filterStringList(entry.value, parent, path, key));
    case 'dependsOn':
      return FilterDependsOn(_filterStringList(entry.value, parent, path, key));
    case 'match':
      return FilterMatch(_filterStringList(entry.value, parent, path, key));
    case 'noMatch':
      return FilterNoMatch(_filterStringList(entry.value, parent, path, key));
    case 'group':
      final groupValue = entry.value;
      if (groupValue is! String) {
        throw CheckedFromJsonException(
          parent,
          'filters',
          'FilterExpr',
          'Invalid filter at $path: `group` must be a string',
        );
      }
      return FilterGroup(groupValue);
    case 'preset':
      final presetValue = entry.value;
      if (presetValue is! String) {
        throw CheckedFromJsonException(
          parent,
          'filters',
          'FilterExpr',
          'Invalid filter at $path: `preset` must be a string',
        );
      }
      if (presetValue.trim().isEmpty) {
        throw CheckedFromJsonException(
          parent,
          'filters',
          'FilterExpr',
          'Invalid filter at $path: `preset` must be a non-empty string',
        );
      }
      return FilterPreset(presetValue);
    case 'changed':
      final changedValue = entry.value;
      if (changedValue is String) {
        if (changedValue.trim().isEmpty) {
          throw CheckedFromJsonException(
            parent,
            'filters',
            'FilterExpr',
            'Invalid filter at $path: `changed` must be a non-empty string',
          );
        }
        final descriptor = changedValue.trim();
        parseChangedDescriptor(descriptor);
        return FilterChanged([descriptor]);
      }
      if (changedValue is List) {
        if (changedValue.isEmpty) {
          throw CheckedFromJsonException(
            parent,
            'filters',
            'FilterExpr',
            'Invalid filter at $path: `changed` list must not be empty',
          );
        }
        final descriptors = <String>[];
        for (var i = 0; i < changedValue.length; i++) {
          final element = changedValue[i];
          if (element is! String) {
            throw CheckedFromJsonException(
              parent,
              'filters',
              'FilterExpr',
              'Invalid filter at $path: `changed` entries must be strings '
                  '(index $i)',
            );
          }
          if (element.trim().isEmpty) {
            throw CheckedFromJsonException(
              parent,
              'filters',
              'FilterExpr',
              'Invalid filter at $path: `changed` entries must be non-empty '
                  'strings (index $i)',
            );
          }
          final descriptor = element.trim();
          parseChangedDescriptor(descriptor);
          descriptors.add(descriptor);
        }
        return FilterChanged(List<String>.unmodifiable(descriptors));
      }
      throw CheckedFromJsonException(
        parent,
        'filters',
        'FilterExpr',
        'Invalid filter at $path: `changed` must be a descriptor string or '
            'a non-empty list of descriptor strings',
      );
    case 'sdk':
      final sdkValue = entry.value;
      if (sdkValue is Map || sdkValue is List) {
        throw CheckedFromJsonException(
          parent,
          'filters',
          'FilterExpr',
          'Invalid filter at $path: `sdk` must be a string '
              '(${packageSdkValues.join(' | ')}), not a map or list',
        );
      }
      if (sdkValue is! String) {
        throw CheckedFromJsonException(
          parent,
          'filters',
          'FilterExpr',
          'Invalid filter at $path: `sdk` must be a string',
        );
      }
      final sdk = sdkValue.trim();
      if (!packageSdkValues.contains(sdk)) {
        throw CheckedFromJsonException(
          parent,
          'filters',
          'FilterExpr',
          'Invalid filter at $path: `sdk` must be one of: '
              '${packageSdkValues.join(', ')}',
        );
      }
      return FilterSdk(sdk);
    case 'needsPubGet':
      final needsValue = entry.value;
      if (needsValue is! bool) {
        throw CheckedFromJsonException(
          parent,
          'filters',
          'FilterExpr',
          'Invalid filter at $path: `needsPubGet` must be a boolean',
        );
      }
      return FilterNeedsPubGet(needsValue);
    default:
      throw CheckedFromJsonException(
        parent,
        'filters',
        'FilterExpr',
        'Invalid filter at $path: unknown key "$key". Expected one of: '
            'and, or, preset, changed, match, noMatch, group, dependsOn, '
            'dirExists, fileExists, noDirExists, noFileExists, sdk, '
            'needsPubGet',
      );
  }
}

List<FilterExpr> _filterChildrenFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
  String path,
  String key,
) {
  if (value is! List) {
    throw CheckedFromJsonException(
      parent,
      'filters',
      'FilterExpr',
      'Invalid filter at $path: `$key` must be a list of filter expressions',
    );
  }
  if (value.isEmpty) {
    throw CheckedFromJsonException(
      parent,
      'filters',
      'FilterExpr',
      'Invalid filter at $path: `$key` must be a non-empty list',
    );
  }
  return List<FilterExpr>.unmodifiable([
    for (var i = 0; i < value.length; i++)
      _filterNodeFromValue(
        value[i],
        parent: parent,
        path: '$path.$key[$i]',
      ),
  ]);
}

List<String> _filterStringList(
  Object? value,
  Map<dynamic, dynamic> parent,
  String path,
  String key,
) {
  if (value is! List) {
    throw CheckedFromJsonException(
      parent,
      'filters',
      'FilterExpr',
      'Invalid filter at $path: `$key` must be a list of strings',
    );
  }
  final result = <String>[];
  for (var i = 0; i < value.length; i++) {
    final element = value[i];
    if (element is! String) {
      throw CheckedFromJsonException(
        parent,
        'filters',
        'FilterExpr',
        'Invalid filter at $path: `$key` must be a list of strings '
            '(index $i)',
      );
    }
    result.add(element);
  }
  return List<String>.unmodifiable(result);
}

String? _optionalString(
  Map<dynamic, dynamic> map,
  String key,
  String className,
) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw CheckedFromJsonException(
      map,
      key,
      className,
      'Expected a string',
    );
  }
  return value;
}

List<String> _stringList(
  Map<dynamic, dynamic> map,
  String key,
  String className,
) {
  return _stringListAt(map, key, map[key], className);
}

List<String> _stringListAt(
  Map<dynamic, dynamic> map,
  String key,
  Object? value,
  String className,
) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw CheckedFromJsonException(
      map,
      key,
      className,
      'Expected a list of strings',
    );
  }
  final result = <String>[];
  for (var i = 0; i < value.length; i++) {
    final element = value[i];
    if (element is! String) {
      throw CheckedFromJsonException(
        map,
        key,
        className,
        'Expected a list of strings (index $i)',
      );
    }
    result.add(element);
  }
  return List<String>.unmodifiable(result);
}

String _parsedYamlMessage(ParsedYamlException error) {
  final formatted = error.formattedMessage;
  if (formatted != null && formatted.isNotEmpty) {
    return formatted;
  }
  if (error.message.isNotEmpty) {
    return error.message;
  }
  return error.toString();
}

String _checkedFromJsonMessage(CheckedFromJsonException error) {
  final key = error.key;
  final message = error.message;
  if (key != null && message != null) {
    return 'Invalid `$key`: $message';
  }
  if (message != null) {
    return message;
  }
  return error.toString();
}
