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

    test('executionLayers matches dependency depth among selected packages',
        () {
      List<List<String>> layerNames(List<List<RipplePackage>> layers) => [
            for (final layer in layers)
              [for (final package in layer) package.name],
          ];

      expect(
        layerNames(graph.executionLayers(packages)),
        [
          ['core', 'tool_pkg'],
          ['ui'],
          ['app'],
        ],
      );
      expect(
        layerNames(graph.executionLayers([app, ui, core])),
        [
          ['core'],
          ['ui'],
          ['app'],
        ],
      );
      expect(
        layerNames(graph.executionLayers([app, core])),
        [
          // No selected edge app→core (path goes through ui), so both are
          // free in layer 0 — sorted by relativePath.
          ['app', 'core'],
        ],
      );
      expect(
        layerNames(graph.executionLayers([app, ui])),
        [
          ['ui'],
          ['app'],
        ],
      );
      expect(
        layerNames(graph.executionLayers([core, tool])),
        [
          ['core', 'tool_pkg'],
        ],
      );
    });

    test('executionLayers sorts siblings by relativePath', () {
      final layers = graph.executionLayers(packages);
      expect(
        layers.first.map((package) => package.relativePath).toList(),
        ['packages/core', 'tool'],
      );
    });

    test('executionLayers fails on a dependency cycle', () {
      final temp = Directory.systemTemp.createTempSync('ripple_cycle_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
name: cycle
packages:
  include:
    - packages/*
''');
      Directory(p.join(temp.path, 'packages', 'alpha')).createSync(
        recursive: true,
      );
      Directory(p.join(temp.path, 'packages', 'beta')).createSync(
        recursive: true,
      );
      File(p.join(temp.path, 'packages', 'alpha', 'pubspec.yaml'))
          .writeAsStringSync('''
name: alpha
dependencies:
  beta:
    path: ../beta
''');
      File(p.join(temp.path, 'packages', 'beta', 'pubspec.yaml'))
          .writeAsStringSync('''
name: beta
dependencies:
  alpha:
    path: ../alpha
''');

      final cycleConfig = loadRippleConfig(start: Directory(temp.path));
      final cyclePackages = discoverPackages(cycleConfig);
      final cycleGraph = WorkspaceGraph.fromPackages(cyclePackages);

      expect(
        () => cycleGraph.executionLayers(cyclePackages),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            allOf(contains('Dependency cycle detected'), contains('alpha'),
                contains('beta')),
          ),
        ),
      );
    });
  });
}
