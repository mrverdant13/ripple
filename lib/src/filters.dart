/// Narrow discovered packages by path, deps, groups, and name selection.
library;

import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

import 'config.dart';
import 'discovery.dart';

/// Environment variable for comma-separated package name selection.
///
/// When set, names are intersected with [PackageFilterCriteria.match] /
/// [PackageFilterCriteria.noMatch] globs and every other active filter
/// criterion. Values are exact package names, not globs.
const ripplePackagesEnvVar = 'RIPPLE_PACKAGES';

/// Criteria used to narrow a discovered package list.
///
/// All non-empty criteria are applied with **intersection** semantics: a
/// package must satisfy every active criterion. Within a single list such as
/// [dirExists], every entry must match (AND). Within one [match] OR-group, a
/// package matches if its name matches **any** glob; when [match] holds
/// multiple groups (after [intersect]), the package must satisfy every group.
/// Within [noMatch], a package is excluded if its name matches **any** glob.
/// Within [packageNames], a package matches if its name is one of the selected
/// names (OR / exact).
class PackageFilterCriteria {
  /// Creates filter criteria.
  ///
  /// [match] is a list of OR-groups of package-name globs. Pass a single group
  /// for one filter source, e.g. `match: [['ui', '*_pkg']]`. [intersect]
  /// concatenates groups so each source's OR-list must be satisfied (AND).
  ///
  /// [packageNames] is `null` when no exact name allowlist is active. An empty
  /// list means an allowlist is active and matches no packages (for example
  /// after an empty intersection involving `RIPPLE_PACKAGES`).
  const PackageFilterCriteria({
    this.dirExists = const [],
    this.fileExists = const [],
    this.dependsOn = const [],
    this.groups = const [],
    this.match = const [],
    this.noMatch = const [],
    this.packageNames,
  });

  /// Builds criteria from a single filter source's name-glob OR-list.
  ///
  /// Empty [match] / [noMatch] leave those criteria inactive. Non-empty
  /// [match] becomes one OR-group.
  factory PackageFilterCriteria.fromNameGlobs({
    List<String> match = const [],
    List<String> noMatch = const [],
    List<String> dirExists = const [],
    List<String> fileExists = const [],
    List<String> dependsOn = const [],
    List<String> groups = const [],
    List<String>? packageNames,
  }) {
    return PackageFilterCriteria(
      dirExists: dirExists,
      fileExists: fileExists,
      dependsOn: dependsOn,
      groups: groups,
      match: match.isEmpty ? const [] : [List<String>.unmodifiable(match)],
      noMatch: noMatch,
      packageNames: packageNames,
    );
  }

  /// Builds criteria from script-declared [filters].
  ///
  /// Optional [packageNames] are applied as an additional exact-name
  /// intersection. An empty [packageNames] iterable leaves name selection
  /// unset.
  factory PackageFilterCriteria.fromScriptFilters(
    ScriptFilters? filters, {
    Iterable<String> packageNames = const [],
  }) {
    final names =
        packageNames.isEmpty ? null : List<String>.unmodifiable(packageNames);
    if (filters == null) {
      return PackageFilterCriteria(packageNames: names);
    }
    return PackageFilterCriteria(
      dirExists: filters.dirExists,
      fileExists: filters.fileExists,
      dependsOn: filters.dependsOn,
      groups: filters.group == null
          ? const []
          : List<String>.unmodifiable([filters.group!]),
      match: filters.match.isEmpty
          ? const []
          : [List<String>.unmodifiable(filters.match)],
      noMatch: filters.noMatch,
      packageNames: names,
    );
  }

  /// Relative directory paths that must exist under each package root.
  final List<String> dirExists;

  /// Relative file paths that must exist under each package root.
  final List<String> fileExists;

  /// Direct dependency names that must appear in the package pubspec
  /// (`dependencies` or `dev_dependencies`).
  final List<String> dependsOn;

  /// Named groups from `packages.groups`; the package must be a member of
  /// every listed group (intersection when more than one is set).
  final List<String> groups;

  /// Package-name glob OR-groups. A package must match every group; within a
  /// group, matching any pattern is enough.
  final List<List<String>> match;

  /// Package-name globs; when non-empty, [RipplePackage.name] must not match
  /// any pattern.
  final List<String> noMatch;

  /// Exact selected package names, or `null` when no allowlist is active.
  ///
  /// When non-null (including empty), [RipplePackage.name] must be one of
  /// these names. An empty list matches no packages.
  final List<String>? packageNames;

  /// Whether any criterion is active.
  bool get isEmpty =>
      dirExists.isEmpty &&
      fileExists.isEmpty &&
      dependsOn.isEmpty &&
      groups.isEmpty &&
      match.isEmpty &&
      noMatch.isEmpty &&
      packageNames == null;

  /// Returns a copy with [packageNames] replaced by the intersection of the
  /// current names (if any) and names parsed from [ripplePackagesEnv].
  ///
  /// Empty env values are ignored (they do not clear an existing selection).
  /// An empty intersection yields an empty [packageNames] list (match
  /// nothing), not `null`.
  PackageFilterCriteria withPackageNameSelection({
    String? ripplePackagesEnv,
  }) {
    final fromEnvList = parsePackageNameList(ripplePackagesEnv);
    final fromEnv = fromEnvList.isEmpty ? null : fromEnvList;
    final selected = resolvePackageNameFilter(
      packageNames,
      fromEnv,
    );
    return PackageFilterCriteria(
      dirExists: dirExists,
      fileExists: fileExists,
      dependsOn: dependsOn,
      groups: groups,
      match: match,
      noMatch: noMatch,
      packageNames: selected,
    );
  }

  /// Combines this criteria with [other].
  ///
  /// Path and dependency lists (`dirExists`, `fileExists`, `dependsOn`),
  /// [groups], and [noMatch] are concatenated so every list entry must be
  /// satisfied under that criterion's rules. [match] OR-groups are
  /// concatenated so every group must match (AND across sources). Exact name
  /// selections intersect when either side has an active [packageNames]
  /// filter (`null` means unset).
  PackageFilterCriteria intersect(PackageFilterCriteria other) {
    return PackageFilterCriteria(
      dirExists: List<String>.unmodifiable([...dirExists, ...other.dirExists]),
      fileExists:
          List<String>.unmodifiable([...fileExists, ...other.fileExists]),
      dependsOn: List<String>.unmodifiable([...dependsOn, ...other.dependsOn]),
      groups: List<String>.unmodifiable([...groups, ...other.groups]),
      match: List<List<String>>.unmodifiable([...match, ...other.match]),
      noMatch: List<String>.unmodifiable([...noMatch, ...other.noMatch]),
      packageNames: resolvePackageNameFilter(packageNames, other.packageNames),
    );
  }
}

/// Parses a comma-separated package name list from [ripplePackagesEnvVar].
List<String> parsePackageNameList(String? value) {
  if (value == null) {
    return const [];
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return const [];
  }
  return [
    for (final part in trimmed.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

/// Intersects provided package-name lists.
///
/// Null arguments are ignored. When every argument is null, returns null
/// (meaning "no name filter"). When at least one argument is non-null,
/// returns their intersection, which may be empty (match nothing).
List<String>? resolvePackageNameFilter(
  Iterable<String>? first, [
  Iterable<String>? second,
  Iterable<String>? third,
]) {
  final lists = <List<String>>[
    if (first != null) List<String>.of(first),
    if (second != null) List<String>.of(second),
    if (third != null) List<String>.of(third),
  ];

  if (lists.isEmpty) {
    return null;
  }

  var result = lists.first;
  for (var i = 1; i < lists.length; i++) {
    final allowed = lists[i].toSet();
    result = result.where(allowed.contains).toList();
  }
  return List<String>.unmodifiable(result);
}

/// Filters [packages] according to [criteria].
///
/// Group membership is resolved via [groupMembership] when provided; otherwise
/// [resolvePackageGroups] is used. Throws [RippleConfigException] when a
/// requested group name is not defined in [config], when a provided
/// [groupMembership] map omits a requested group, or when a [match] /
/// [noMatch] pattern is not a valid glob.
///
/// Order of [packages] is preserved.
List<RipplePackage> filterPackages(
  List<RipplePackage> packages, {
  required RippleConfig config,
  PackageFilterCriteria criteria = const PackageFilterCriteria(),
  Map<String, List<RipplePackage>>? groupMembership,
}) {
  if (criteria.isEmpty) {
    return List<RipplePackage>.unmodifiable(packages);
  }

  for (final groupName in criteria.groups) {
    if (!config.packages.groups.containsKey(groupName)) {
      final known = config.packages.groups.keys;
      final knownList = known.isEmpty ? '(none)' : known.join(', ');
      throw RippleConfigException(
        'Unknown package group "$groupName". Known groups: $knownList',
      );
    }
  }

  final groups =
      groupMembership ?? resolvePackageGroups(config, packages: packages);
  final groupMemberPaths = <String>{};
  if (criteria.groups.isNotEmpty) {
    List<RipplePackage> membersFor(String groupName) {
      final members = groups[groupName];
      if (members == null) {
        throw RippleConfigException(
          'Missing group membership for "$groupName". '
          'Provide a complete groupMembership map or omit it to resolve '
          'groups from config.',
        );
      }
      return members;
    }

    // Start from the first group, then intersect with each additional group.
    var memberPaths = membersFor(criteria.groups.first)
        .map((package) => package.relativePath)
        .toSet();
    for (var i = 1; i < criteria.groups.length; i++) {
      final next = membersFor(criteria.groups[i])
          .map((package) => package.relativePath)
          .toSet();
      memberPaths = memberPaths.intersection(next);
    }
    groupMemberPaths.addAll(memberPaths);
  }

  final selectedNames = criteria.packageNames;
  final nameSet = selectedNames?.toSet();
  final matchGroups = [
    for (final group in criteria.match)
      [for (final pattern in group) _nameGlob(pattern)],
  ];
  final noMatchGlobs = [
    for (final pattern in criteria.noMatch) _nameGlob(pattern),
  ];

  final filtered = <RipplePackage>[];
  for (final package in packages) {
    if (!_matchesAllNameGroups(package.name, matchGroups)) {
      continue;
    }
    if (noMatchGlobs.isNotEmpty &&
        _matchesAnyName(package.name, noMatchGlobs)) {
      continue;
    }
    if (nameSet != null && !nameSet.contains(package.name)) {
      continue;
    }
    if (criteria.groups.isNotEmpty &&
        !groupMemberPaths.contains(package.relativePath)) {
      continue;
    }
    if (!_matchesPathFilters(package, criteria)) {
      continue;
    }
    if (!_matchesDependsOn(package, criteria.dependsOn)) {
      continue;
    }
    filtered.add(package);
  }

  return List<RipplePackage>.unmodifiable(filtered);
}

/// Context for matching package-name globs (POSIX-style, no filesystem walk).
final _nameMatchContext = p.Context(style: p.Style.posix);

Glob _nameGlob(String pattern) {
  try {
    return Glob(pattern, context: _nameMatchContext);
  } on FormatException catch (error) {
    throw RippleConfigException(
      'Invalid package-name glob "$pattern": ${error.message}',
    );
  }
}

bool _matchesAllNameGroups(String name, List<List<Glob>> groups) {
  for (final group in groups) {
    if (group.isEmpty) {
      continue;
    }
    if (!_matchesAnyName(name, group)) {
      return false;
    }
  }
  return true;
}

bool _matchesAnyName(String name, List<Glob> globs) {
  for (final glob in globs) {
    if (glob.matches(name)) {
      return true;
    }
  }
  return false;
}

bool _matchesPathFilters(
  RipplePackage package,
  PackageFilterCriteria criteria,
) {
  for (final relativeDir in criteria.dirExists) {
    final dir = Directory(p.join(package.path, relativeDir));
    if (!dir.existsSync()) {
      return false;
    }
  }
  for (final relativeFile in criteria.fileExists) {
    final file = File(p.join(package.path, relativeFile));
    if (!file.existsSync()) {
      return false;
    }
  }
  return true;
}

bool _matchesDependsOn(RipplePackage package, List<String> dependsOn) {
  if (dependsOn.isEmpty) {
    return true;
  }

  final pubspecFile = File(p.join(package.path, 'pubspec.yaml'));
  late final String contents;
  try {
    contents = pubspecFile.readAsStringSync();
  } on FileSystemException catch (error) {
    throw RippleConfigException(
      'Failed to read ${pubspecFile.path}: ${error.message}',
    );
  }

  late final Pubspec pubspec;
  try {
    pubspec = Pubspec.parse(
      contents,
      sourceUrl: p.toUri(pubspecFile.path),
    );
  } on Object catch (error) {
    throw RippleConfigException(
      'Invalid pubspec at ${pubspecFile.path}: $error',
    );
  }

  final declared = <String>{
    ...pubspec.dependencies.keys,
    ...pubspec.devDependencies.keys,
  };

  for (final name in dependsOn) {
    if (!declared.contains(name)) {
      return false;
    }
  }
  return true;
}
