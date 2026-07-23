/// Workspace package dependency graph and transitive closures.
library;

import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

import 'config.dart';
import 'discovery.dart';

/// Directed dependency graph over [discovered] workspace packages.
///
/// An edge `A → B` exists when package `A` declares `B` in `dependencies` or
/// `dev_dependencies` **and** `B` is among the discovered packages (by
/// [RipplePackage.name]). Hosted / path deps whose target name is not in the
/// workspace are ignored.
class WorkspaceGraph {
  WorkspaceGraph._({
    required Map<String, List<RipplePackage>> forward,
    required Map<String, List<RipplePackage>> reverse,
  })  : _forward = forward,
        _reverse = reverse;

  /// Builds a graph from [packages] by reading each package's pubspec.
  ///
  /// Throws [RippleConfigException] when a pubspec cannot be read or parsed.
  factory WorkspaceGraph.fromPackages(List<RipplePackage> packages) {
    final byName = <String, RipplePackage>{
      for (final package in packages) package.name: package,
    };
    final forward = <String, List<RipplePackage>>{};
    final reverse = <String, List<RipplePackage>>{};

    for (final package in packages) {
      final deps = <RipplePackage>[];
      for (final name in _declaredDependencyNames(package)) {
        final target = byName[name];
        if (target == null || target.relativePath == package.relativePath) {
          continue;
        }
        deps.add(target);
        reverse
            .putIfAbsent(target.relativePath, () => <RipplePackage>[])
            .add(package);
      }
      deps.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      forward[package.relativePath] = List<RipplePackage>.unmodifiable(deps);
    }

    for (final entry in reverse.entries) {
      entry.value.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      reverse[entry.key] = List<RipplePackage>.unmodifiable(entry.value);
    }

    return WorkspaceGraph._(
      forward: Map<String, List<RipplePackage>>.unmodifiable(forward),
      reverse: Map<String, List<RipplePackage>>.unmodifiable(reverse),
    );
  }

  final Map<String, List<RipplePackage>> _forward;
  final Map<String, List<RipplePackage>> _reverse;

  /// Direct workspace dependencies of [package] (stable by relative path).
  List<RipplePackage> dependenciesOf(RipplePackage package) =>
      _forward[package.relativePath] ?? const [];

  /// Direct workspace dependents of [package] (stable by relative path).
  List<RipplePackage> dependentsOf(RipplePackage package) =>
      _reverse[package.relativePath] ?? const [];

  /// Transitive workspace dependencies of [seeds], excluding the seeds
  /// themselves.
  Set<RipplePackage> transitiveDependencies(Iterable<RipplePackage> seeds) =>
      _closure(seeds, _forward);

  /// Transitive workspace dependents of [seeds], excluding the seeds
  /// themselves.
  Set<RipplePackage> transitiveDependents(Iterable<RipplePackage> seeds) =>
      _closure(seeds, _reverse);

  Set<RipplePackage> _closure(
    Iterable<RipplePackage> seeds,
    Map<String, List<RipplePackage>> adjacency,
  ) {
    // Pre-seed visited with seeds so closures exclude seeds themselves:
    // a successful visited.add below can never re-admit a seed path.
    final visited = {
      for (final seed in seeds) seed.relativePath,
    };
    final result = <String, RipplePackage>{};
    final queue = Queue<RipplePackage>.of(seeds);

    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      for (final next
          in adjacency[current.relativePath] ?? const <RipplePackage>[]) {
        if (!visited.add(next.relativePath)) {
          continue;
        }
        result[next.relativePath] = next;
        queue.add(next);
      }
    }

    return result.values.toSet();
  }
}

Set<String> _declaredDependencyNames(RipplePackage package) {
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

  return {
    ...pubspec.dependencies.keys,
    ...pubspec.devDependencies.keys,
  };
}
