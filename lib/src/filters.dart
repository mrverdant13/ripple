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
/// When set, names are intersected with [PackageFilterCriteria.expression]
/// and every other active filter criterion. Values are exact package names,
/// not globs.
const ripplePackagesEnvVar = 'RIPPLE_PACKAGES';

/// Criteria used to narrow a discovered package list.
///
/// [expression] is a boolean [FilterExpr] (CLI flags compile to an in-memory
/// `and` of leaves). [packageNames] is an exact-name allowlist from
/// `RIPPLE_PACKAGES` (or tests). A package must satisfy both when set.
class PackageFilterCriteria {
  /// Creates filter criteria.
  ///
  /// [packageNames] is `null` when no exact name allowlist is active. An empty
  /// list means an allowlist is active and matches no packages (for example
  /// after an empty intersection involving `RIPPLE_PACKAGES`).
  const PackageFilterCriteria({
    this.expression,
    this.packageNames,
  });

  /// Builds criteria from CLI flat flags as an `and` of leaf predicates.
  ///
  /// Empty flag lists leave those leaves out. Non-empty [match] becomes one
  /// [FilterMatch] leaf (OR within the list). Multiple [groups] become
  /// separate [FilterGroup] leaves AND'd together.
  factory PackageFilterCriteria.fromNameGlobs({
    List<String> match = const [],
    List<String> noMatch = const [],
    List<String> dirExists = const [],
    List<String> fileExists = const [],
    List<String> dependsOn = const [],
    List<String> groups = const [],
    List<String>? packageNames,
  }) {
    final leaves = <FilterExpr>[
      if (dirExists.isNotEmpty) FilterDirExists(dirExists),
      if (fileExists.isNotEmpty) FilterFileExists(fileExists),
      if (dependsOn.isNotEmpty) FilterDependsOn(dependsOn),
      for (final group in groups) FilterGroup(group),
      if (match.isNotEmpty) FilterMatch(match),
      if (noMatch.isNotEmpty) FilterNoMatch(noMatch),
    ];
    return PackageFilterCriteria(
      expression: _andLeaves(leaves),
      packageNames: packageNames,
    );
  }

  /// Builds criteria from a script-declared [filters] expression.
  ///
  /// Optional [packageNames] are applied as an additional exact-name
  /// intersection. An empty [packageNames] iterable leaves name selection
  /// unset.
  factory PackageFilterCriteria.fromScriptFilters(
    FilterExpr? filters, {
    Iterable<String> packageNames = const [],
  }) {
    final names =
        packageNames.isEmpty ? null : List<String>.unmodifiable(packageNames);
    return PackageFilterCriteria(expression: filters, packageNames: names);
  }

  /// Boolean filter expression, or `null` when no expression filter is set.
  final FilterExpr? expression;

  /// Exact selected package names, or `null` when no allowlist is active.
  ///
  /// When non-null (including empty), [RipplePackage.name] must be one of
  /// these names. An empty list matches no packages.
  final List<String>? packageNames;

  /// Whether any criterion is active.
  bool get isEmpty => expression == null && packageNames == null;

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
      expression: expression,
      packageNames: selected,
    );
  }

  /// Combines this criteria with [other].
  ///
  /// Expressions are AND'd. Exact name selections intersect when either side
  /// has an active [packageNames] filter (`null` means unset).
  PackageFilterCriteria intersect(PackageFilterCriteria other) {
    return PackageFilterCriteria(
      expression: andFilterExprs(expression, other.expression),
      packageNames: resolvePackageNameFilter(packageNames, other.packageNames),
    );
  }
}

/// Returns an `and` of [a] and [b], omitting null sides.
FilterExpr? andFilterExprs(FilterExpr? a, FilterExpr? b) {
  if (a == null) {
    return b;
  }
  if (b == null) {
    return a;
  }
  return FilterAnd([a, b]);
}

FilterExpr? _andLeaves(List<FilterExpr> leaves) {
  if (leaves.isEmpty) {
    return null;
  }
  if (leaves.length == 1) {
    return leaves.single;
  }
  return FilterAnd(List<FilterExpr>.unmodifiable(leaves));
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
/// [groupMembership] map omits a requested group, or when a [FilterMatch] /
/// [FilterNoMatch] pattern is not a valid glob.
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

  final expression = criteria.expression;
  final referencedGroups =
      expression == null ? const <String>{} : _collectGroupNames(expression);

  for (final groupName in referencedGroups) {
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
  final groupMemberPaths = <String, Set<String>>{};
  for (final groupName in referencedGroups) {
    final members = groups[groupName];
    if (members == null) {
      throw RippleConfigException(
        'Missing group membership for "$groupName". '
        'Provide a complete groupMembership map or omit it to resolve '
        'groups from config.',
      );
    }
    groupMemberPaths[groupName] = {
      for (final package in members) package.relativePath,
    };
  }

  final selectedNames = criteria.packageNames;
  final nameSet = selectedNames?.toSet();
  final globCache = <String, Glob>{};
  final pubspecCache = <String, Pubspec>{};

  final filtered = <RipplePackage>[];
  for (final package in packages) {
    if (nameSet != null && !nameSet.contains(package.name)) {
      continue;
    }
    if (expression != null &&
        !_matchesExpression(
          expression,
          package: package,
          groupMemberPaths: groupMemberPaths,
          globCache: globCache,
          pubspecCache: pubspecCache,
        )) {
      continue;
    }
    filtered.add(package);
  }

  return List<RipplePackage>.unmodifiable(filtered);
}

Set<String> _collectGroupNames(FilterExpr expression) {
  return switch (expression) {
    FilterAnd(:final children) || FilterOr(:final children) => {
        for (final child in children) ..._collectGroupNames(child),
      },
    FilterGroup(:final name) => {name},
    FilterDirExists() ||
    FilterFileExists() ||
    FilterDependsOn() ||
    FilterMatch() ||
    FilterNoMatch() =>
      const {},
  };
}

bool _matchesExpression(
  FilterExpr expression, {
  required RipplePackage package,
  required Map<String, Set<String>> groupMemberPaths,
  required Map<String, Glob> globCache,
  required Map<String, Pubspec> pubspecCache,
}) {
  return switch (expression) {
    FilterAnd(:final children) => children.every(
        (child) => _matchesExpression(
          child,
          package: package,
          groupMemberPaths: groupMemberPaths,
          globCache: globCache,
          pubspecCache: pubspecCache,
        ),
      ),
    FilterOr(:final children) => children.any(
        (child) => _matchesExpression(
          child,
          package: package,
          groupMemberPaths: groupMemberPaths,
          globCache: globCache,
          pubspecCache: pubspecCache,
        ),
      ),
    FilterDirExists(:final paths) => _matchesDirExists(package, paths),
    FilterFileExists(:final paths) => _matchesFileExists(package, paths),
    FilterDependsOn(:final names) =>
      _matchesDependsOn(package, names, pubspecCache),
    FilterGroup(:final name) =>
      groupMemberPaths[name]!.contains(package.relativePath),
    FilterMatch(:final globs) =>
      globs.isEmpty || _matchesAnyName(package.name, globs, globCache),
    FilterNoMatch(:final globs) =>
      globs.isEmpty || !_matchesAnyName(package.name, globs, globCache),
  };
}

/// Context for matching package-name globs (POSIX-style, no filesystem walk).
final _nameMatchContext = p.Context(style: p.Style.posix);

Glob _cachedNameGlob(String pattern, Map<String, Glob> cache) {
  final cached = cache[pattern];
  if (cached != null) {
    return cached;
  }
  try {
    final glob = Glob(pattern, context: _nameMatchContext);
    cache[pattern] = glob;
    return glob;
  } on FormatException catch (error) {
    throw RippleConfigException(
      'Invalid package-name glob "$pattern": ${error.message}',
    );
  }
}

bool _matchesAnyName(
  String name,
  List<String> patterns,
  Map<String, Glob> cache,
) {
  for (final pattern in patterns) {
    if (_cachedNameGlob(pattern, cache).matches(name)) {
      return true;
    }
  }
  return false;
}

bool _matchesDirExists(RipplePackage package, List<String> relativeDirs) {
  for (final relativeDir in relativeDirs) {
    final dir = Directory(p.join(package.path, relativeDir));
    if (!dir.existsSync()) {
      return false;
    }
  }
  return true;
}

bool _matchesFileExists(RipplePackage package, List<String> relativeFiles) {
  for (final relativeFile in relativeFiles) {
    final file = File(p.join(package.path, relativeFile));
    if (!file.existsSync()) {
      return false;
    }
  }
  return true;
}

bool _matchesDependsOn(
  RipplePackage package,
  List<String> dependsOn,
  Map<String, Pubspec> pubspecCache,
) {
  if (dependsOn.isEmpty) {
    return true;
  }

  final pubspec = _cachedPubspec(package, pubspecCache);
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

Pubspec _cachedPubspec(
  RipplePackage package,
  Map<String, Pubspec> cache,
) {
  final cached = cache[package.path];
  if (cached != null) {
    return cached;
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

  cache[package.path] = pubspec;
  return pubspec;
}
