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

  PackageFilterCriteria criteria(FilterExpr expression) =>
      PackageFilterCriteria(expression: expression);

  group('filterPackages — single criteria', () {
    test('dirExists narrows to packages with that directory', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterDirExists(['test'])),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('fileExists narrows to packages with that file', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterFileExists(['README.md'])),
        groupMembership: groups,
      );

      expect(names(filtered), ['ui']);
    });

    test('dependsOn matches direct dependencies and dev_dependencies', () {
      final byPathDep = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterDependsOn(['core'])),
        groupMembership: groups,
      );
      expect(names(byPathDep), ['ui']);

      final byDevDep = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterDependsOn(['path'])),
        groupMembership: groups,
      );
      expect(names(byDevDep), ['core', 'tool_pkg']);

      final byHostedDevDep = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterDependsOn(['test'])),
        groupMembership: groups,
      );
      expect(names(byHostedDevDep), ['ui']);
    });

    test('group intersects with named group membership', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterGroup('libs')),
        groupMembership: groups,
      );

      expect(names(filtered), ['core', 'ui']);
    });

    test('packageNames selects by RipplePackage.name', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria(
          packageNames: ['ui', 'tool_pkg'],
        ),
        groupMembership: groups,
      );

      expect(names(filtered), ['ui', 'tool_pkg']);
    });

    test('match selects by package-name globs (OR)', () {
      final exact = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterMatch(['ui'])),
        groupMembership: groups,
      );
      expect(names(exact), ['ui']);

      final glob = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterMatch(['*_pkg', 'core'])),
        groupMembership: groups,
      );
      expect(names(glob), ['core', 'tool_pkg']);
    });

    test('noMatch excludes by package-name globs', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterNoMatch(['*_pkg', 'ui'])),
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

  group('filterPackages — boolean expressions', () {
    test('and requires every child to match', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(
          const FilterAnd([
            FilterDirExists(['lib']),
            FilterDependsOn(['path']),
            FilterGroup('libs'),
          ]),
        ),
        groupMembership: groups,
      );

      // core: has lib + path dep + in libs
      // ui: has lib + in libs, but depends on core/test — not path
      // tool_pkg: has path (dev) but no lib/ and not in libs
      expect(names(filtered), ['core']);
    });

    test('or matches when any child matches', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(
          const FilterOr([
            FilterDirExists(['test']),
            FilterFileExists(['README.md']),
          ]),
        ),
        groupMembership: groups,
      );

      expect(names(filtered), ['core', 'ui']);
    });

    test('nested or inside and evaluates correctly', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(
          const FilterAnd([
            FilterGroup('libs'),
            FilterOr([
              FilterDirExists(['test']),
              FilterDependsOn(['test']),
            ]),
          ]),
        ),
        groupMembership: groups,
      );

      // core: libs + dirExists test
      // ui: libs + dependsOn test
      expect(names(filtered), ['core', 'ui']);
    });

    test('multiple groups require membership in every group', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(
          const FilterAnd([
            FilterGroup('libs'),
            FilterGroup('core'),
          ]),
        ),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('intersect ANDs script and CLI filter expressions', () {
      final script = PackageFilterCriteria.fromScriptFilters(
        const FilterAnd([
          FilterDependsOn(['path']),
          FilterGroup('libs'),
        ]),
      );
      final cli = criteria(const FilterDirExists(['lib']));
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: script.intersect(cli),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('fromScriptFilters preserves match and noMatch leaves', () {
      final scriptCriteria = PackageFilterCriteria.fromScriptFilters(
        const FilterAnd([
          FilterMatch(['*_pkg', 'core']),
          FilterNoMatch(['ui']),
        ]),
      );

      expect(
        scriptCriteria.expression,
        const FilterAnd([
          FilterMatch(['*_pkg', 'core']),
          FilterNoMatch(['ui']),
        ]),
      );

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: scriptCriteria,
        groupMembership: groups,
      );
      expect(names(filtered), ['core', 'tool_pkg']);
    });

    test('match and noMatch compose with other filters', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(
          const FilterAnd([
            FilterGroup('libs'),
            FilterMatch(['*']),
            FilterNoMatch(['ui']),
          ]),
        ),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('fromNameGlobs builds an and of leaves; intersect ANDs expressions',
        () {
      final left = PackageFilterCriteria.fromNameGlobs(
        match: ['*'],
        noMatch: ['tool_pkg'],
      );
      final right = PackageFilterCriteria.fromNameGlobs(
        match: ['*ore'],
        noMatch: ['ui'],
      );
      final merged = left.intersect(right);

      expect(
        merged.expression,
        const FilterAnd([
          FilterAnd([
            FilterMatch(['*']),
            FilterNoMatch(['tool_pkg']),
          ]),
          FilterAnd([
            FilterMatch(['*ore']),
            FilterNoMatch(['ui']),
          ]),
        ]),
      );

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
      final nameCriteria = criteria(const FilterGroup('libs'))
          .withPackageNameSelection(ripplePackagesEnv: 'ui,tool_pkg');

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: nameCriteria,
        groupMembership: groups,
      );

      expect(names(filtered), ['ui']);
    });

    test('exact packageNames intersects with RIPPLE_PACKAGES', () {
      final nameCriteria = const PackageFilterCriteria(
        packageNames: ['core', 'ui'],
      ).withPackageNameSelection(ripplePackagesEnv: 'ui,tool_pkg');

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: nameCriteria,
        groupMembership: groups,
      );

      expect(names(filtered), ['ui']);
    });

    test('empty name-selection intersection matches no packages', () {
      final nameCriteria = const PackageFilterCriteria(
        packageNames: ['core'],
      ).withPackageNameSelection(ripplePackagesEnv: 'ui');

      expect(nameCriteria.packageNames, isEmpty);
      expect(nameCriteria.isEmpty, isFalse);

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: nameCriteria,
        groupMembership: groups,
      );

      expect(filtered, isEmpty);
    });

    test('exact packageNames intersects with path filters', () {
      final nameCriteria = const PackageFilterCriteria(
        expression: FilterDirExists(['lib']),
        packageNames: ['core', 'tool_pkg'],
      );

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: nameCriteria,
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
          criteria: criteria(const FilterGroup('missing')),
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
          criteria: criteria(const FilterGroup('libs')),
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

    test('invalid match glob fails with a clear error', () {
      expect(
        () => filterPackages(
          packages,
          config: config,
          criteria: criteria(const FilterMatch(['['])),
          groupMembership: groups,
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Invalid package-name glob "["'),
              isNot(contains('FormatException')),
            ),
          ),
        ),
      );
    });

    test('invalid noMatch glob fails with a clear error', () {
      expect(
        () => filterPackages(
          packages,
          config: config,
          criteria: criteria(const FilterNoMatch(['{a'])),
          groupMembership: groups,
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            contains('Invalid package-name glob "{a"'),
          ),
        ),
      );
    });
  });
}
