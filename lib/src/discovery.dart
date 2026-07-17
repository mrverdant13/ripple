/// Resolve include/exclude globs to package directories with a pubspec.
library;

import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

import 'config.dart';

/// A Dart package discovered under a Ripple root.
///
/// A directory is a package if and only if it contains a `pubspec.yaml`.
class RipplePackage {
  /// Creates a discovered package.
  const RipplePackage({
    required this.name,
    required this.path,
    required this.relativePath,
  });

  /// Package name from `pubspec.yaml`.
  final String name;

  /// Absolute path to the package directory.
  final String path;

  /// Path relative to the Ripple root (posix-style separators).
  final String relativePath;

  @override
  String toString() => 'RipplePackage($name @ $relativePath)';

  @override
  bool operator ==(Object other) {
    return other is RipplePackage &&
        other.name == name &&
        other.path == path &&
        other.relativePath == relativePath;
  }

  @override
  int get hashCode => Object.hash(name, path, relativePath);
}

/// Expands [RipplePackages.include] globs under [config.rootPath], keeps
/// directories that contain `pubspec.yaml`, then subtracts
/// [RipplePackages.exclude] matches.
///
/// Returns an empty list when include is empty or nothing matches. Order is
/// stable by [RipplePackage.relativePath] (filesystem / glob order is not
/// relied upon for v1 dependency scheduling).
List<RipplePackage> discoverPackages(RippleConfig config) {
  final rootPath = p.normalize(config.rootPath);
  final include = config.packages.include;
  if (include.isEmpty) {
    return const [];
  }

  final context = p.Context(style: p.Style.posix, current: rootPath);
  final candidates = <String, RipplePackage>{};

  for (final pattern in include) {
    final glob = Glob(pattern, context: context);
    for (final entity in glob.listSync(root: rootPath, followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final packageDir = p.normalize(entity.path);
      final pubspecFile = File(p.join(packageDir, 'pubspec.yaml'));
      if (!pubspecFile.existsSync()) {
        continue;
      }

      final relativePath = _posixRelative(rootPath, packageDir);
      if (candidates.containsKey(relativePath)) {
        continue;
      }

      final name = _readPackageName(pubspecFile);
      candidates[relativePath] = RipplePackage(
        name: name,
        path: packageDir,
        relativePath: relativePath,
      );
    }
  }

  final excludeGlobs = [
    for (final pattern in config.packages.exclude)
      Glob(pattern, context: context),
  ];

  final packages = candidates.values
      .where((package) => !_isExcluded(package.relativePath, excludeGlobs))
      .toList()
    ..sort((a, b) => a.relativePath.compareTo(b.relativePath));

  return List<RipplePackage>.unmodifiable(packages);
}

/// Resolves [RipplePackages.groups] path globs to discovered package sets.
///
/// Each group name maps to the packages from [packages] whose
/// [RipplePackage.relativePath] matches any of that group's globs. Membership
/// is stored for later filtering; this does not invent packages outside
/// [packages].
///
/// When [packages] is omitted, packages are discovered via [discoverPackages].
Map<String, List<RipplePackage>> resolvePackageGroups(
  RippleConfig config, {
  List<RipplePackage>? packages,
}) {
  final discovered = packages ?? discoverPackages(config);
  if (config.packages.groups.isEmpty) {
    return const {};
  }

  final context = p.Context(
    style: p.Style.posix,
    current: p.normalize(config.rootPath),
  );
  final groups = <String, List<RipplePackage>>{};

  for (final entry in config.packages.groups.entries) {
    final globs = [
      for (final pattern in entry.value) Glob(pattern, context: context),
    ];
    final members = discovered
        .where((package) => _matchesAny(package.relativePath, globs))
        .toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    groups[entry.key] = List<RipplePackage>.unmodifiable(members);
  }

  return Map<String, List<RipplePackage>>.unmodifiable(groups);
}

String _posixRelative(String rootPath, String absolutePath) {
  final relative = p.relative(absolutePath, from: rootPath);
  return p.posix.joinAll(p.split(relative));
}

bool _isExcluded(String relativePath, List<Glob> excludeGlobs) {
  if (excludeGlobs.isEmpty) {
    return false;
  }
  return _matchesAny(relativePath, excludeGlobs);
}

bool _matchesAny(String relativePath, List<Glob> globs) {
  for (final glob in globs) {
    if (glob.matches(relativePath)) {
      return true;
    }
  }
  return false;
}

String _readPackageName(File pubspecFile) {
  late final String contents;
  try {
    contents = pubspecFile.readAsStringSync();
  } on FileSystemException catch (error) {
    throw RippleConfigException(
      'Failed to read ${pubspecFile.path}: ${error.message}',
    );
  }

  try {
    final pubspec = Pubspec.parse(
      contents,
      sourceUrl: p.toUri(pubspecFile.path),
    );
    return pubspec.name;
  } on Object catch (error) {
    throw RippleConfigException(
      'Invalid pubspec at ${pubspecFile.path}: $error',
    );
  }
}
