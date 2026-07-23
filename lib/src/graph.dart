/// Workspace package dependency graph and transitive closures.
library;

import 'dart:collection';

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

  /// Builds a graph from [packages] using each package's declared deps.
  ///
  /// Uses [RipplePackage.pubspec] when present; otherwise reads `pubspec.yaml`
  /// from disk. Throws [RippleConfigException] when a pubspec cannot be read
  /// or parsed.
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
  final pubspec = resolvePackagePubspec(package);
  return {
    ...pubspec.dependencies.keys,
    ...pubspec.devDependencies.keys,
  };
}
