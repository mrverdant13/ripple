/// Narrow discovered packages by path, deps, groups, and name selection.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

import 'config.dart';
import 'discovery.dart';

/// Environment variable for comma-separated package name selection.
///
/// When set, names are intersected with `--packages` (if any) and with every
/// other active filter criterion.
const ripplePackagesEnvVar = 'RIPPLE_PACKAGES';

/// Criteria used to narrow a discovered package list.
///
/// All non-empty criteria are applied with **intersection** semantics: a
/// package must satisfy every active criterion. Within a single list such as
/// [dirExists], every entry must match (AND). Within [packageNames], a package
/// matches if its name is one of the selected names (OR).
class PackageFilterCriteria {
  /// Creates filter criteria.
  const PackageFilterCriteria({
    this.dirExists = const [],
    this.fileExists = const [],
    this.dependsOn = const [],
    this.groups = const [],
    this.packageNames = const [],
  });

  /// Builds criteria from script-declared [filters].
  ///
  /// Optional [packageNames] are applied as an additional name intersection.
  factory PackageFilterCriteria.fromScriptFilters(
    ScriptFilters? filters, {
    Iterable<String> packageNames = const [],
  }) {
    if (filters == null) {
      return PackageFilterCriteria(
        packageNames: List<String>.unmodifiable(packageNames),
      );
    }
    return PackageFilterCriteria(
      dirExists: filters.dirExists,
      fileExists: filters.fileExists,
      dependsOn: filters.dependsOn,
      groups: filters.group == null
          ? const []
          : List<String>.unmodifiable([filters.group!]),
      packageNames: List<String>.unmodifiable(packageNames),
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

  /// When non-empty, [RipplePackage.name] must be one of these names.
  final List<String> packageNames;

  /// Whether any criterion is active.
  bool get isEmpty =>
      dirExists.isEmpty &&
      fileExists.isEmpty &&
      dependsOn.isEmpty &&
      groups.isEmpty &&
      packageNames.isEmpty;

  /// Returns a copy with [packageNames] replaced by the intersection of the
  /// current names (if any), [packages], and names parsed from
  /// [ripplePackagesEnv].
  ///
  /// Empty inputs are ignored (they do not clear an existing selection).
  PackageFilterCriteria withPackageNameSelection({
    Iterable<String>? packages,
    String? ripplePackagesEnv,
  }) {
    final selected = resolvePackageNameFilter(
      packageNames,
      packages ?? const <String>[],
      parsePackageNameList(ripplePackagesEnv),
    );
    return PackageFilterCriteria(
      dirExists: dirExists,
      fileExists: fileExists,
      dependsOn: dependsOn,
      groups: groups,
      packageNames: selected,
    );
  }

  /// Intersects this criteria with [other] (union of path/dep lists; group and
  /// name lists intersect when both sides are non-empty).
  PackageFilterCriteria intersect(PackageFilterCriteria other) {
    return PackageFilterCriteria(
      dirExists: List<String>.unmodifiable([...dirExists, ...other.dirExists]),
      fileExists:
          List<String>.unmodifiable([...fileExists, ...other.fileExists]),
      dependsOn: List<String>.unmodifiable([...dependsOn, ...other.dependsOn]),
      groups: List<String>.unmodifiable([...groups, ...other.groups]),
      packageNames: resolvePackageNameFilter(packageNames, other.packageNames),
    );
  }
}

/// Parses a comma-separated package name list from `--packages` or
/// [ripplePackagesEnvVar].
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

/// Intersects non-empty package-name lists.
///
/// Empty lists are ignored. When every argument is empty, returns an empty
/// list (meaning "no name filter").
List<String> resolvePackageNameFilter(Iterable<String> first,
    [Iterable<String>? second, Iterable<String>? third]) {
  final lists = <List<String>>[
    List<String>.of(first),
    if (second != null) List<String>.of(second),
    if (third != null) List<String>.of(third),
  ].where((list) => list.isNotEmpty).toList();

  if (lists.isEmpty) {
    return const [];
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
/// requested group name is not defined in [config].
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
    // Start from the first group, then intersect with each additional group.
    var memberPaths = groups[criteria.groups.first]!
        .map((package) => package.relativePath)
        .toSet();
    for (var i = 1; i < criteria.groups.length; i++) {
      final next = groups[criteria.groups[i]]!
          .map((package) => package.relativePath)
          .toSet();
      memberPaths = memberPaths.intersection(next);
    }
    groupMemberPaths.addAll(memberPaths);
  }

  final nameSet =
      criteria.packageNames.isEmpty ? null : criteria.packageNames.toSet();

  final filtered = <RipplePackage>[];
  for (final package in packages) {
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
