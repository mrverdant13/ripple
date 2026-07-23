import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/graph.dart';
import 'package:test/test.dart';

void main() {
  final fixtureRoot = Directory(
    p.join('test', 'fixtures', 'discovery_workspace'),
  ).absolute.path;

  late List<RipplePackage> packages;
  late WorkspaceGraph graph;
  late RipplePackage app;
  late RipplePackage core;
  late RipplePackage ui;
  late RipplePackage tool;

  setUp(() {
    final config = loadRippleConfig(start: Directory(fixtureRoot));
    packages = discoverPackages(config);
    graph = WorkspaceGraph.fromPackages(packages);
    app = packages.singleWhere((package) => package.name == 'app');
    core = packages.singleWhere((package) => package.name == 'core');
    ui = packages.singleWhere((package) => package.name == 'ui');
    tool = packages.singleWhere((package) => package.name == 'tool_pkg');
  });

  List<String> names(Iterable<RipplePackage> value) =>
      (value.map((package) => package.name).toList()..sort());

  group('WorkspaceGraph', () {
    test('builds workspace edges from pubspec deps only', () {
      expect(names(graph.dependenciesOf(app)), ['ui']);
      expect(names(graph.dependenciesOf(ui)), ['core']);
      expect(graph.dependenciesOf(core), isEmpty);
      expect(graph.dependenciesOf(tool), isEmpty);

      // Hosted `path` / `test` are not workspace edges.
      expect(names(graph.dependentsOf(core)), ['ui']);
      expect(names(graph.dependentsOf(ui)), ['app']);
      expect(graph.dependentsOf(app), isEmpty);
      expect(graph.dependentsOf(tool), isEmpty);
    });

    test('transitiveDependencies walks the forward closure', () {
      expect(names(graph.transitiveDependencies([app])), ['core', 'ui']);
      expect(names(graph.transitiveDependencies([ui])), ['core']);
      expect(graph.transitiveDependencies([core]), isEmpty);
      expect(names(graph.transitiveDependencies([app, ui])), ['core']);
    });

    test('transitiveDependents walks the reverse closure', () {
      expect(names(graph.transitiveDependents([core])), ['app', 'ui']);
      expect(names(graph.transitiveDependents([ui])), ['app']);
      expect(graph.transitiveDependents([app]), isEmpty);
      expect(names(graph.transitiveDependents([core, ui])), ['app']);
    });

    test('closures exclude seeds and ignore unrelated packages', () {
      expect(
          names(graph.transitiveDependents([core])), isNot(contains('core')));
      expect(
          names(graph.transitiveDependencies([app])), isNot(contains('app')));
      expect(names(graph.transitiveDependents([core])),
          isNot(contains('tool_pkg')));
      expect(
        names(graph.transitiveDependencies([app])),
        isNot(contains('tool_pkg')),
      );
    });
  });
}
