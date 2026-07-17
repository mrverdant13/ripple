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
          include: ['packages/**', 'tool'],
        ),
      );

      final packages = discoverPackages(config);
      expect(
        packages.map((package) => package.relativePath).toList(),
        [
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
        ['packages/core', 'packages/ui', 'tool'],
      );
      expect(
        packages.map((package) => package.name).toList(),
        ['core', 'ui', 'tool_pkg'],
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
        packages: const RipplePackages(include: ['does-not-exist/*']),
      );

      expect(discoverPackages(config), isEmpty);
    });

    test('directories without pubspec.yaml are not packages', () {
      final config = RippleConfig(
        rootPath: fixtureRoot,
        packages: const RipplePackages(include: ['packages/*']),
      );

      final packages = discoverPackages(config);
      expect(
        packages.map((package) => package.relativePath).toList(),
        ['packages/core', 'packages/ui'],
      );
      expect(
        packages.any((package) => package.relativePath == 'packages/app'),
        isFalse,
      );
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
        ['packages/core', 'packages/ui'],
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
          ['packages/core', 'packages/ui', 'tool'],
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
          include: ['tool'],
        ),
      );
      final packages = discoverPackages(config);

      expect(resolvePackageGroups(config, packages: packages), isEmpty);
    });
  });
}
