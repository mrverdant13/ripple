import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/filters.dart';
import 'package:test/test.dart';

void main() {
  final fixtureRoot = Directory(
    p.join('test', 'fixtures', 'discovery_workspace'),
  ).absolute.path;

  late RippleConfig config;
  late List<RipplePackage> packages;
  late Map<String, List<RipplePackage>> groups;

  setUp(() {
    config = loadRippleConfig(start: Directory(fixtureRoot));
    packages = discoverPackages(config);
    groups = resolvePackageGroups(config, packages: packages);
  });

  List<String> names(List<RipplePackage> value) =>
      value.map((package) => package.name).toList();

  group('filterPackages — single criteria', () {
    test('dirExists narrows to packages with that directory', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(dirExists: ['test']),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('fileExists narrows to packages with that file', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(fileExists: ['README.md']),
        groupMembership: groups,
      );

      expect(names(filtered), ['ui']);
    });

    test('dependsOn matches direct dependencies and dev_dependencies', () {
      final byPathDep = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(dependsOn: ['core']),
        groupMembership: groups,
      );
      expect(names(byPathDep), ['ui']);

      final byDevDep = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(dependsOn: ['path']),
        groupMembership: groups,
      );
      expect(names(byDevDep), ['core', 'tool_pkg']);

      final byHostedDevDep = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(dependsOn: ['test']),
        groupMembership: groups,
      );
      expect(names(byHostedDevDep), ['ui']);
    });

    test('group intersects with named group membership', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(groups: ['libs']),
        groupMembership: groups,
      );

      expect(names(filtered), ['core', 'ui']);
    });

    test('packageNames selects by RipplePackage.name', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(packageNames: ['ui', 'tool_pkg']),
        groupMembership: groups,
      );

      expect(names(filtered), ['ui', 'tool_pkg']);
    });

    test('match selects by package-name globs (OR)', () {
      final exact = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(match: [
          ['ui'],
        ]),
        groupMembership: groups,
      );
      expect(names(exact), ['ui']);

      final glob = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(match: [
          ['*_pkg', 'core'],
        ]),
        groupMembership: groups,
      );
      expect(names(glob), ['core', 'tool_pkg']);
    });

    test('noMatch excludes by package-name globs', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(noMatch: ['*_pkg', 'ui']),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('empty criteria returns the full discovered set', () {
      final filtered = filterPackages(
        packages,
        config: config,
        groupMembership: groups,
      );

      expect(names(filtered), ['core', 'ui', 'tool_pkg']);
    });
  });

  group('filterPackages — intersection', () {
    test('combining filters uses intersection semantics', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(
          dirExists: ['lib'],
          dependsOn: ['path'],
          groups: ['libs'],
        ),
        groupMembership: groups,
      );

      // core: has lib + path dep + in libs
      // ui: has lib + in libs, but depends on core/test — not path
      // tool_pkg: has path (dev) but no lib/ and not in libs
      expect(names(filtered), ['core']);
    });

    test('multiple groups require membership in every group', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(groups: ['libs', 'core']),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('PackageFilterCriteria.intersect merges script and CLI filters', () {
      final script = PackageFilterCriteria.fromScriptFilters(
        const ScriptFilters(dependsOn: ['path'], group: 'libs'),
      );
      final cli = const PackageFilterCriteria(dirExists: ['lib']);
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: script.intersect(cli),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('match and noMatch compose with other filters', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(
          groups: ['libs'],
          match: [
            ['*'],
          ],
          noMatch: ['ui'],
        ),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('intersect ANDs match OR-groups and concatenates noMatch', () {
      final left = PackageFilterCriteria.fromNameGlobs(
        match: ['*'],
        noMatch: ['tool_pkg'],
      );
      final right = PackageFilterCriteria.fromNameGlobs(
        match: ['*ore'],
        noMatch: ['ui'],
      );
      final merged = left.intersect(right);

      expect(merged.match, [
        ['*'],
        ['*ore'],
      ]);
      expect(merged.noMatch, ['tool_pkg', 'ui']);

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: merged,
        groupMembership: groups,
      );
      expect(names(filtered), ['core']);
    });
  });

  group('package name selection', () {
    test('RIPPLE_PACKAGES intersects with other filters', () {
      final criteria = const PackageFilterCriteria(
        groups: ['libs'],
      ).withPackageNameSelection(ripplePackagesEnv: 'ui,tool_pkg');

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria,
        groupMembership: groups,
      );

      expect(names(filtered), ['ui']);
    });

    test('explicit package list intersects with RIPPLE_PACKAGES', () {
      final criteria = const PackageFilterCriteria().withPackageNameSelection(
        packages: ['core', 'ui'],
        ripplePackagesEnv: 'ui,tool_pkg',
      );

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria,
        groupMembership: groups,
      );

      expect(names(filtered), ['ui']);
    });

    test('empty name-selection intersection matches no packages', () {
      final criteria = const PackageFilterCriteria().withPackageNameSelection(
        packages: ['core'],
        ripplePackagesEnv: 'ui',
      );

      expect(criteria.packageNames, isEmpty);
      expect(criteria.isEmpty, isFalse);

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria,
        groupMembership: groups,
      );

      expect(filtered, isEmpty);
    });

    test('explicit package list intersects with path filters', () {
      final criteria = const PackageFilterCriteria(
        dirExists: ['lib'],
      ).withPackageNameSelection(packages: ['core', 'tool_pkg']);

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria,
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('parsePackageNameList trims and drops empties', () {
      expect(parsePackageNameList(null), isEmpty);
      expect(parsePackageNameList(''), isEmpty);
      expect(parsePackageNameList('  a, b , ,c  '), ['a', 'b', 'c']);
    });

    test('resolvePackageNameFilter ignores null sides', () {
      expect(resolvePackageNameFilter(null), isNull);
      expect(resolvePackageNameFilter(['a', 'b']), ['a', 'b']);
      expect(resolvePackageNameFilter(null, ['a']), ['a']);
      expect(resolvePackageNameFilter(['a', 'b'], ['b', 'c']), ['b']);
      expect(
        resolvePackageNameFilter(['a', 'b'], ['b', 'c'], ['b', 'x']),
        ['b'],
      );
      expect(resolvePackageNameFilter(['a'], ['b']), isEmpty);
    });
  });

  group('filterPackages — errors', () {
    test('unknown group name fails with a clear error', () {
      expect(
        () => filterPackages(
          packages,
          config: config,
          criteria: const PackageFilterCriteria(groups: ['missing']),
          groupMembership: groups,
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Unknown package group "missing"'),
              contains('Known groups:'),
              contains('core'),
              contains('libs'),
              contains('tooling'),
            ),
          ),
        ),
      );
    });

    test('partial groupMembership map fails with a clear error', () {
      expect(
        () => filterPackages(
          packages,
          config: config,
          criteria: const PackageFilterCriteria(groups: ['libs']),
          groupMembership: const {},
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Missing group membership for "libs"'),
              contains('groupMembership'),
            ),
          ),
        ),
      );
    });
  });
}
