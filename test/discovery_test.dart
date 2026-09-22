import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:test/test.dart';

void main() {
  final fixtureRoot = Directory(
    p.join('test', 'fixtures', 'discovery_workspace'),
  ).absolute.path;

  RippleConfig loadFixtureConfig() => loadRippleConfig(
        start: Directory(fixtureRoot),
      );

  group('discoverPackages', () {
    test('include globs return only directories with pubspec.yaml', () {
      final config = RippleConfig(
        rootPath: fixtureRoot,
        packages: const RipplePackages(
          include: [PackageIncludeGlob('packages/**'), PackageIncludeGlob('tool')],
        ),
      );

      final packages = discoverPackages(config);
      expect(
        packages.map((package) => package.relativePath).toList(),
        [
          'packages/app',
          'packages/app/fixtures/decoy',
          'packages/app/mold/decoy',
          'packages/core',
          'packages/core/example',
          'packages/ui',
          'tool',
        ],
      );
      expect(
        packages.map((package) => package.name).toList(),
        [
          'app',
          'fixtures_decoy',
          'mold_decoy',
          'core',
          'core_example',
          'ui',
          'tool_pkg',
        ],
      );
      for (final package in packages) {
        expect(p.isAbsolute(package.path), isTrue);
        expect(File(p.join(package.path, 'pubspec.yaml')).existsSync(), isTrue);
      }
    });

    test('exclude globs remove decoys under example, fixtures, and mold', () {
      final config = loadFixtureConfig();
      final packages = discoverPackages(config);

      expect(
        packages.map((package) => package.relativePath).toList(),
        ['packages/app', 'packages/core', 'packages/ui', 'tool'],
      );
      expect(
        packages.map((package) => package.name).toList(),
        ['app', 'core', 'ui', 'tool_pkg'],
      );
    });

    test('empty include yields an empty package list', () {
      final config = RippleConfig(
        rootPath: fixtureRoot,
        packages: const RipplePackages(include: []),
      );

      expect(discoverPackages(config), isEmpty);
    });

    test('include with no matches yields an empty package list', () {
      final config = RippleConfig(
        rootPath: fixtureRoot,
        packages: const RipplePackages(include: [PackageIncludeGlob('does-not-exist/*')]),
      );

      expect(discoverPackages(config), isEmpty);
    });

    test('include packages/* selects only immediate package dirs with pubspec',
        () {
      final config = RippleConfig(
        rootPath: fixtureRoot,
        packages: const RipplePackages(include: [PackageIncludeGlob('packages/*')]),
      );

      final packages = discoverPackages(config);
      expect(
        packages.map((package) => package.relativePath).toList(),
        ['packages/app', 'packages/core', 'packages/ui'],
      );
      expect(
        packages.any(
          (package) => package.relativePath == 'packages/app/fixtures/decoy',
        ),
        isFalse,
      );
    });

    group('root package with pubspec.yaml', () {
      late Directory tempRoot;

      setUp(() {
        tempRoot = Directory.systemTemp.createTempSync('ripple_discovery_');
        File(p.join(tempRoot.path, 'pubspec.yaml')).writeAsStringSync('''
name: root_pkg
environment:
  sdk: ^3.5.0
''');
        final nested = Directory(p.join(tempRoot.path, 'packages', 'child'))
          ..createSync(recursive: true);
        File(p.join(nested.path, 'pubspec.yaml')).writeAsStringSync('''
name: child_pkg
environment:
  sdk: ^3.5.0
''');
      });

      tearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      test("include '**' selects the Ripple root package", () {
        final config = RippleConfig(
          rootPath: tempRoot.path,
          packages: const RipplePackages(include: [PackageIncludeGlob('**')]),
        );

        final packages = discoverPackages(config);
        expect(
          packages.map((package) => package.relativePath).toList(),
          ['.', 'packages/child'],
        );
        expect(
          packages.map((package) => package.name).toList(),
          ['root_pkg', 'child_pkg'],
        );
        expect(packages.first.path, p.normalize(tempRoot.path));
      });

      test("include '.' selects only the Ripple root package", () {
        final config = RippleConfig(
          rootPath: tempRoot.path,
          packages: const RipplePackages(include: [PackageIncludeGlob('.')]),
        );

        final packages = discoverPackages(config);
        expect(
          packages.map((package) => package.relativePath).toList(),
          ['.'],
        );
        expect(packages.single.name, 'root_pkg');
      });

      test("include 'packages/**' does not invent a root package", () {
        final config = RippleConfig(
          rootPath: tempRoot.path,
          packages: const RipplePackages(include: [PackageIncludeGlob('packages/**')]),
        );

        final packages = discoverPackages(config);
        expect(
          packages.map((package) => package.relativePath).toList(),
          ['packages/child'],
        );
        expect(
          packages.any((package) => package.relativePath == '.'),
          isFalse,
        );
      });

      test('exclude matching . removes the root package', () {
        final config = RippleConfig(
          rootPath: tempRoot.path,
          packages: const RipplePackages(
            include: [PackageIncludeGlob('**')],
            exclude: ['.'],
          ),
        );

        final packages = discoverPackages(config);
        expect(
          packages.map((package) => package.relativePath).toList(),
          ['packages/child'],
        );
      });
    });
  });

  group('resolvePackageGroups', () {
    test('resolves group globs to expected package path sets', () {
      final config = loadFixtureConfig();
      final packages = discoverPackages(config);
      final groups = resolvePackageGroups(config, packages: packages);

      expect(
        groups['core']!.map((package) => package.relativePath).toList(),
        ['packages/core'],
      );
      expect(
        groups['libs']!.map((package) => package.relativePath).toList(),
        ['packages/app', 'packages/core', 'packages/ui'],
      );
      expect(
        groups['tooling']!.map((package) => package.relativePath).toList(),
        ['tool'],
      );
    });

    test('group membership is drawn only from discovered packages', () {
      final config = loadFixtureConfig();
      final groups = resolvePackageGroups(config);

      final allMembers = groups.values.expand((packages) => packages);
      for (final package in allMembers) {
        expect(
          ['packages/app', 'packages/core', 'packages/ui', 'tool'],
          contains(package.relativePath),
        );
      }
      expect(
        allMembers.any(
          (package) => package.relativePath == 'packages/core/example',
        ),
        isFalse,
      );
    });

    test('empty groups map returns an empty result', () {
      final config = RippleConfig(
        rootPath: fixtureRoot,
        packages: const RipplePackages(
          include: [PackageIncludeGlob('tool')],
        ),
      );
      final packages = discoverPackages(config);

      expect(resolvePackageGroups(config, packages: packages), isEmpty);
    });
  });

  group('discoverPackages — Dart workspaces', () {
    Directory createTempDir(String prefix) {
      final temp = Directory.systemTemp.createTempSync(prefix);
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      return temp;
    }

    void writeFile(String path, String contents) {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    test('workspace include expands root and members', () {
      final temp = createTempDir('ripple_disc_ws_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/alone
    - workspace: packages/app_ws
''');
      writeFile(
        p.join(temp.path, 'packages', 'alone', 'pubspec.yaml'),
        'name: alone\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(p.join(temp.path, 'packages', 'app_ws', 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/core
  - packages/ui
''');
      writeFile(
        p.join(temp.path, 'packages', 'app_ws', 'packages', 'core', 'pubspec.yaml'),
        'name: core\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'app_ws', 'packages', 'ui', 'pubspec.yaml'),
        'name: ui\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );
      // Standalone under member — not included by workspace: entry.
      writeFile(
        p.join(
          temp.path,
          'packages',
          'app_ws',
          'packages',
          'ui',
          'example',
          'pubspec.yaml',
        ),
        'name: ui_example\nenvironment:\n  sdk: ^3.6.0\n',
      );

      final packages = discoverPackages(loadRippleConfig(start: temp));
      expect(
        packages.map((p) => p.relativePath).toList(),
        [
          'packages/alone',
          'packages/app_ws',
          'packages/app_ws/packages/core',
          'packages/app_ws/packages/ui',
        ],
      );
    });

    test('hard-fails on intermediate standalone under a workspace', () {
      final temp = createTempDir('ripple_disc_bad_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(p.join(temp.path, 'packages', 'app_ws', 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - nested/child
''');
      writeFile(
        p.join(temp.path, 'packages', 'app_ws', 'nested', 'pubspec.yaml'),
        'name: nested\nenvironment:\n  sdk: ^3.6.0\n',
      );
      writeFile(
        p.join(
          temp.path,
          'packages',
          'app_ws',
          'nested',
          'child',
          'pubspec.yaml',
        ),
        'name: child\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );

      expect(
        () => discoverPackages(loadRippleConfig(start: temp)),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('intermediate standalone'),
          ),
        ),
      );
    });
  });
}
