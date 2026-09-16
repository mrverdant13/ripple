import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/graph.dart';
import 'package:ripple_cli/src/list_format.dart';
import 'package:test/test.dart';

void main() {
  final fixtureRoot = Directory(
    p.join('test', 'fixtures', 'discovery_workspace'),
  ).absolute.path;

  late List<RipplePackage> packages;
  late WorkspaceGraph graph;
  late RipplePackage core;
  late RipplePackage ui;
  late RipplePackage tool;

  setUp(() {
    final config = loadRippleConfig(start: Directory(fixtureRoot));
    packages = discoverPackages(config);
    graph = WorkspaceGraph.fromPackages(packages);
    core = packages.singleWhere((package) => package.name == 'core');
    ui = packages.singleWhere((package) => package.name == 'ui');
    tool = packages.singleWhere((package) => package.name == 'tool_pkg');
  });

  group('packageSdkLabel', () {
    test('is dart when environment.flutter is absent', () {
      expect(
        packageSdkLabel(Pubspec('plain', environment: const {})),
        'dart',
      );
    });

    test('is flutter when environment.flutter is present', () {
      final pubspec = Pubspec.parse('''
name: flutter_pkg
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''');
      expect(packageSdkLabel(pubspec), 'flutter');
    });
  });

  group('packageListEntry', () {
    test('maps version, dart sdk, and workspace edges', () {
      expect(packageListEntry(ui, graph), {
        'name': 'ui',
        'path': 'packages/ui',
        'version': '1.2.3',
        'sdk': 'dart',
        'workspaceDependencies': ['core'],
        'workspaceDependents': ['app'],
      });
    });

    test('omits hosted deps and nulls missing version', () {
      expect(packageListEntry(core, graph), {
        'name': 'core',
        'path': 'packages/core',
        'version': null,
        'sdk': 'dart',
        'workspaceDependencies': <String>[],
        'workspaceDependents': ['ui'],
      });
    });

    test('lists isolates with empty edge arrays', () {
      expect(packageListEntry(tool, graph), {
        'name': 'tool_pkg',
        'path': 'tool',
        'version': null,
        'sdk': 'dart',
        'workspaceDependencies': <String>[],
        'workspaceDependents': <String>[],
      });
    });
  });

  group('formatPackageListJson', () {
    test('encodes a stable JSON array by package path order', () {
      final encoded = formatPackageListJson([core, ui], graph);
      final decoded = jsonDecode(encoded) as List<dynamic>;

      expect(decoded, hasLength(2));
      expect((decoded[0] as Map)['path'], 'packages/core');
      expect((decoded[1] as Map)['path'], 'packages/ui');
      expect((decoded[1] as Map)['workspaceDependencies'], ['core']);
      // Hosted `path` on core must not appear.
      expect((decoded[0] as Map)['workspaceDependencies'], isEmpty);
    });
  });

  group('formatPackageListMermaid', () {
    test('emits nodes and workspace edges only', () {
      final mermaid = formatPackageListMermaid(packages, graph);

      expect(mermaid, startsWith('flowchart TD\n'));
      expect(mermaid, contains('  app --> ui\n'));
      expect(mermaid, contains('  ui --> core\n'));
      expect(mermaid, contains('  tool_pkg\n'));
      expect(mermaid, isNot(contains('path')));
      expect(mermaid, isNot(contains('test')));
    });

    test('drops edges whose target is outside the selection', () {
      final app = packages.singleWhere((package) => package.name == 'app');
      final mermaid = formatPackageListMermaid([app, ui], graph);

      expect(mermaid, contains('  app --> ui\n'));
      expect(mermaid, isNot(contains('ui --> core')));
      expect(mermaid, isNot(contains('core')));
    });
  });
}
