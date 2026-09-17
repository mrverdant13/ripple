/// Workspace package dependency graph and transitive closures.
library;

import 'dart:collection';

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

  /// Groups [selected] into dependency layers for ordered execution.
  ///
  /// Only edges where **both** ends are in [selected] count. Layer 0 is every
  /// selected package with no selected workspace dependencies (including
  /// isolates). A package enters the next layer only after all of its selected
  /// dependencies have been placed in earlier layers. Within a layer, packages
  /// are sorted by [RipplePackage.relativePath].
  ///
  /// Throws [RippleConfigException] when the selected subgraph contains a
  /// cycle (no commands should run).
  List<List<RipplePackage>> executionLayers(List<RipplePackage> selected) {
    if (selected.isEmpty) {
      return const [];
    }

    final byPath = <String, RipplePackage>{
      for (final package in selected) package.relativePath: package,
    };
    final selectedPaths = byPath.keys.toSet();
    final remainingIndegree = <String, int>{
      for (final path in selectedPaths) path: 0,
    };
    // dependency path → packages that depend on it (among [selected])
    final dependentsAmongSelected = <String, List<String>>{
      for (final path in selectedPaths) path: <String>[],
    };
    // package path → selected workspace dependencies (for cycle messages)
    final dependenciesAmongSelected = <String, List<String>>{
      for (final path in selectedPaths) path: <String>[],
    };

    for (final package in selected) {
      for (final dep in dependenciesOf(package)) {
        if (!selectedPaths.contains(dep.relativePath)) {
          continue;
        }
        remainingIndegree[package.relativePath] =
            remainingIndegree[package.relativePath]! + 1;
        dependentsAmongSelected[dep.relativePath]!.add(package.relativePath);
        dependenciesAmongSelected[package.relativePath]!.add(dep.relativePath);
      }
    }

    for (final entry in dependentsAmongSelected.entries) {
      entry.value.sort();
    }
    for (final entry in dependenciesAmongSelected.entries) {
      entry.value.sort();
    }

    final layers = <List<RipplePackage>>[];
    while (remainingIndegree.isNotEmpty) {
      final readyPaths = remainingIndegree.entries
          .where((entry) => entry.value == 0)
          .map((entry) => entry.key)
          .toList()
        ..sort();
      if (readyPaths.isEmpty) {
        throw RippleConfigException(
          _formatDependencyCycle(
            remainingIndegree.keys,
            dependenciesAmongSelected,
            byPath,
          ),
        );
      }

      layers.add([
        for (final path in readyPaths) byPath[path]!,
      ]);

      for (final path in readyPaths) {
        remainingIndegree.remove(path);
        for (final dependent in dependentsAmongSelected[path]!) {
          final current = remainingIndegree[dependent];
          if (current == null) {
            continue;
          }
          remainingIndegree[dependent] = current - 1;
        }
      }
    }

    return layers;
  }

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

/// Builds a human-readable cycle error for the remaining subgraph.
///
/// [dependenciesAmongSelected] maps each package path to the selected packages
/// it depends on (`A → B` means A depends on B). Cycle nodes are shown as
/// pubspec names from [byPath].
String _formatDependencyCycle(
  Iterable<String> remainingPaths,
  Map<String, List<String>> dependenciesAmongSelected,
  Map<String, RipplePackage> byPath,
) {
  final remaining = remainingPaths.toSet();
  final cycle = _findCyclePath(remaining, dependenciesAmongSelected);
  String label(String path) => byPath[path]?.name ?? path;
  if (cycle == null || cycle.length < 2) {
    final names = remaining.map(label).toList()..sort();
    return 'Dependency cycle detected among packages: ${names.join(', ')}';
  }
  return 'Dependency cycle detected: ${cycle.map(label).join(' → ')}';
}

/// Returns a path `A → … → A` among [remaining], or `null` if none is found.
List<String>? _findCyclePath(
  Set<String> remaining,
  Map<String, List<String>> dependenciesAmongSelected,
) {
  final visiting = <String>{};
  final visited = <String>{};
  final stack = <String>[];

  List<String>? dfs(String node) {
    if (visited.contains(node)) {
      return null;
    }
    if (visiting.contains(node)) {
      final start = stack.indexOf(node);
      if (start < 0) {
        return [node, node];
      }
      return [...stack.sublist(start), node];
    }
    visiting.add(node);
    stack.add(node);
    for (final next in dependenciesAmongSelected[node] ?? const <String>[]) {
      if (!remaining.contains(next)) {
        continue;
      }
      final cycle = dfs(next);
      if (cycle != null) {
        return cycle;
      }
    }
    stack.removeLast();
    visiting.remove(node);
    visited.add(node);
    return null;
  }

  final seeds = remaining.toList()..sort();
  for (final seed in seeds) {
    final cycle = dfs(seed);
    if (cycle != null) {
      return cycle;
    }
  }
  return null;
}
