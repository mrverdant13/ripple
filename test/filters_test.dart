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

    test('noDirExists excludes packages that have that directory', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterNoDirExists(['test'])),
        groupMembership: groups,
      );

      expect(names(filtered), ['app', 'ui', 'tool_pkg']);
    });

    test('noFileExists excludes packages that have that file', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterNoFileExists(['README.md'])),
        groupMembership: groups,
      );

      expect(names(filtered), ['app', 'core', 'tool_pkg']);
    });

    test('noDirExists ANDs with dirExists', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(
          const FilterAnd([
            FilterDirExists(['lib']),
            FilterNoDirExists(['test']),
          ]),
        ),
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

      expect(names(filtered), ['app', 'core', 'ui']);
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

      expect(names(filtered), ['app', 'core']);
    });

    test('empty criteria returns the full discovered set', () {
      final filtered = filterPackages(
        packages,
        config: config,
        groupMembership: groups,
      );

      expect(names(filtered), ['app', 'core', 'ui', 'tool_pkg']);
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

      expect(names(filtered), ['app', 'core']);
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

  group('filterPackages — presets', () {
    test('resolves a preset referenced from script filters', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterPreset('withTestDir')),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('resolves nested presets', () {
      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterPreset('libsWithTest')),
        groupMembership: groups,
      );

      expect(names(filtered), ['core']);
    });

    test('fromNameGlobs --preset ANDs with flat flags', () {
      final criteriaWithPreset = PackageFilterCriteria.fromNameGlobs(
        match: ['*'],
        presets: ['withTestDir'],
      );

      expect(
        criteriaWithPreset.expression,
        const FilterAnd([
          FilterMatch(['*']),
          FilterPreset('withTestDir'),
        ]),
      );

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteriaWithPreset,
        groupMembership: groups,
      );
      expect(names(filtered), ['core']);
    });

    test('fromNameGlobs not-exists leaves AND with other flags', () {
      final criteriaWithNotExists = PackageFilterCriteria.fromNameGlobs(
        dirExists: const ['lib'],
        noDirExists: const ['test'],
        noFileExists: const ['README.md'],
      );

      expect(
        criteriaWithNotExists.expression,
        const FilterAnd([
          FilterDirExists(['lib']),
          FilterNoDirExists(['test']),
          FilterNoFileExists(['README.md']),
        ]),
      );

      final filtered = filterPackages(
        packages,
        config: config,
        criteria: criteriaWithNotExists,
        groupMembership: groups,
      );
      // ui has lib + no test, but has README.md — excluded by noFileExists
      expect(names(filtered), isEmpty);
    });

    test('resolveFilterPresets expands nested presets', () {
      final resolved = resolveFilterPresets(
        const FilterPreset('libsWithTest'),
        presets: config.packages.filtersPresets,
      );

      expect(
        resolved,
        const FilterAnd([
          FilterAnd([
            FilterGroup('libs'),
          ]),
          FilterDirExists(['test']),
        ]),
      );
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

    test('unknown preset fails with a clear error', () {
      expect(
        () => filterPackages(
          packages,
          config: config,
          criteria: criteria(const FilterPreset('missing')),
          groupMembership: groups,
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Unknown filter preset "missing"'),
              contains('Known presets:'),
              contains('withTestDir'),
            ),
          ),
        ),
      );
    });

    test('circular preset references fail with a clear error', () {
      final cyclicConfig = RippleConfig(
        rootPath: config.rootPath,
        packages: RipplePackages(
          include: config.packages.include,
          exclude: config.packages.exclude,
          groups: config.packages.groups,
          filtersPresets: {
            'a': const FilterPreset('b'),
            'b': const FilterPreset('a'),
          },
        ),
      );

      expect(
        () => filterPackages(
          packages,
          config: cyclicConfig,
          criteria: criteria(const FilterPreset('a')),
          groupMembership: groups,
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Circular filter preset reference'),
              contains('a -> b -> a'),
            ),
          ),
        ),
      );
    });
  });

  group('selectPackages — graph expansion', () {
    test('absent expansion keys return seeds only', () {
      final selection = selectPackages(
        packages,
        config: config,
        criteria: criteria(const FilterMatch(['core'])),
        groupMembership: groups,
      );

      expect(names(selection.seeds), ['core']);
      expect(selection.dependents, isEmpty);
      expect(selection.dependencies, isEmpty);
      expect(names(selection.packages), ['core']);
    });

    test('empty dependentsFilters expands the reverse closure', () {
      final selection = selectPackages(
        packages,
        config: config,
        criteria: criteria(const FilterMatch(['core'])),
        dependentsFilters: const GraphExpansionFilters(),
        groupMembership: groups,
      );

      expect(names(selection.seeds), ['core']);
      expect(names(selection.dependents), ['app', 'ui']);
      expect(names(selection.packages), ['app', 'core', 'ui']);
    });

    test('empty dependenciesFilters expands the forward closure', () {
      final selection = selectPackages(
        packages,
        config: config,
        criteria: criteria(const FilterMatch(['app'])),
        dependenciesFilters: const GraphExpansionFilters(),
        groupMembership: groups,
      );

      expect(names(selection.seeds), ['app']);
      expect(names(selection.dependencies), ['core', 'ui']);
      expect(names(selection.packages), ['app', 'core', 'ui']);
    });

    test('constrained dependentsFilters keeps matching closure members', () {
      final selection = selectPackages(
        packages,
        config: config,
        criteria: criteria(const FilterMatch(['core'])),
        dependentsFilters: const GraphExpansionFilters(
          expression: FilterMatch(['ui']),
        ),
        groupMembership: groups,
      );

      expect(names(selection.seeds), ['core']);
      expect(names(selection.dependents), ['ui']);
      expect(names(selection.packages), ['core', 'ui']);
    });

    test('RIPPLE_PACKAGES narrows seeds before expansion', () {
      final selection = selectPackages(
        packages,
        config: config,
        criteria: const PackageFilterCriteria()
            .withPackageNameSelection(ripplePackagesEnv: 'core'),
        dependentsFilters: const GraphExpansionFilters(),
        groupMembership: groups,
      );

      expect(names(selection.seeds), ['core']);
      expect(names(selection.dependents), ['app', 'ui']);
      // Expansion is not re-filtered by RIPPLE_PACKAGES.
      expect(names(selection.packages), ['app', 'core', 'ui']);
    });

    test('preset may constrain an expansion closure', () {
      final selection = selectPackages(
        packages,
        config: config,
        criteria: criteria(const FilterMatch(['core'])),
        dependentsFilters: const GraphExpansionFilters(
          expression: FilterPreset('withTestDir'),
        ),
        groupMembership: groups,
      );

      // Reverse closure is {app, ui}; neither has test/ — only seeds remain.
      expect(names(selection.dependents), isEmpty);
      expect(names(selection.packages), ['core']);
    });
  });

  group('filterPackages — sdk', () {
    late Directory temp;
    late RippleConfig sdkConfig;
    late List<RipplePackage> sdkPackages;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ripple_sdk_filter_');
      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
name: sdk_workspace
packages:
  include:
    - packages/*
  groups:
    apps:
      - packages/mobile
      - packages/admin
''');
      _writePubspec(
        p.join(temp.path, 'packages', 'core'),
        '''
name: core
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'api_client'),
        '''
name: api_client
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'ui'),
        '''
name: ui
version: 1.0.0
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'mobile'),
        '''
name: mobile
version: 1.0.0
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'admin'),
        '''
name: admin
version: 1.0.0
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'macos_only'),
        '''
name: macos_only
version: 1.0.0
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''',
      );
      // Flutter SDK dep without environment.flutter — not a Flutter package.
      _writePubspec(
        p.join(temp.path, 'packages', 'fake_flutter_dep'),
        '''
name: fake_flutter_dep
version: 1.0.0
environment:
  sdk: ^3.5.0
dependencies:
  flutter:
    sdk: flutter
''',
      );

      sdkConfig = loadRippleConfig(start: temp);
      sdkPackages = discoverPackages(sdkConfig);
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('sdk flutter matches environment.flutter packages only', () {
      final filtered = filterPackages(
        sdkPackages,
        config: sdkConfig,
        criteria: criteria(const FilterSdk(packageSdkFlutter)),
      );

      expect(names(filtered), ['admin', 'macos_only', 'mobile', 'ui']);
    });

    test('sdk dart matches packages without environment.flutter', () {
      final filtered = filterPackages(
        sdkPackages,
        config: sdkConfig,
        criteria: criteria(const FilterSdk(packageSdkDart)),
      );

      expect(names(filtered), ['api_client', 'core', 'fake_flutter_dep']);
    });

    test('flutter SDK dependency alone does not match sdk flutter', () {
      final filtered = filterPackages(
        sdkPackages,
        config: sdkConfig,
        criteria: criteria(
          const FilterAnd([
            FilterSdk(packageSdkFlutter),
            FilterMatch(['fake_flutter_dep']),
          ]),
        ),
      );

      expect(names(filtered), isEmpty);
    });

    test('fromNameGlobs sdk leaf ANDs with other flags', () {
      final filtered = filterPackages(
        sdkPackages,
        config: sdkConfig,
        criteria: PackageFilterCriteria.fromNameGlobs(
          sdk: packageSdkFlutter,
          groups: const ['apps'],
        ),
      );

      expect(names(filtered), ['admin', 'mobile']);
    });
  });

  group('filterPackages — pubGet', () {
    late Directory temp;
    late RippleConfig pubGetConfig;
    late List<RipplePackage> pubGetPackages;
    late PubGetMatchContext pubGetContext;

    void writePackageConfig(String packageDir, {required DateTime modified}) {
      final file = File(
        p.join(packageDir, '.dart_tool', 'package_config.json'),
      );
      file
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}\n');
      file.setLastModifiedSync(modified);
    }

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ripple_pub_get_');
      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
packages:
  include:
    - packages/*
''');
      _writePubspec(
        p.join(temp.path, 'packages', 'fresh'),
        '''
name: fresh
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'missing_config'),
        '''
name: missing_config
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'stale_pubspec'),
        '''
name: stale_pubspec
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'stale_lock'),
        '''
name: stale_lock
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );

      final now = DateTime.now();
      writePackageConfig(
        p.join(temp.path, 'packages', 'fresh'),
        modified: now.add(const Duration(seconds: 2)),
      );
      writePackageConfig(
        p.join(temp.path, 'packages', 'stale_pubspec'),
        modified: now.subtract(const Duration(seconds: 5)),
      );
      writePackageConfig(
        p.join(temp.path, 'packages', 'stale_lock'),
        modified: now.add(const Duration(seconds: 2)),
      );
      final lock = File(
        p.join(temp.path, 'packages', 'stale_lock', 'pubspec.lock'),
      )..writeAsStringSync('# lock\n');
      lock.setLastModifiedSync(now.add(const Duration(seconds: 5)));

      pubGetConfig = loadRippleConfig(start: temp);
      pubGetPackages = discoverPackages(pubGetConfig);
      pubGetContext = buildPubGetMatchContext(
        rippleRootPath: pubGetConfig.rootPath,
        packages: pubGetPackages,
      );
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('pubGet missing matches missing or older package_config', () {
      final filtered = filterPackages(
        pubGetPackages,
        config: pubGetConfig,
        criteria: criteria(const FilterPubGet(state: PubGetState.missing)),
        pubGetContext: pubGetContext,
      );

      expect(
        names(filtered),
        ['missing_config', 'stale_lock', 'stale_pubspec'],
      );
    });

    test('pubGet resolved matches fresh packages only', () {
      final filtered = filterPackages(
        pubGetPackages,
        config: pubGetConfig,
        criteria: criteria(const FilterPubGet(state: PubGetState.resolved)),
        pubGetContext: pubGetContext,
      );

      expect(names(filtered), ['fresh']);
    });

    test('packagePubGetIsMissing is false after fresh package_config', () {
      final fresh = pubGetPackages.singleWhere((p) => p.name == 'fresh');
      expect(packagePubGetIsMissing(fresh), isFalse);
    });

    test('fromNameGlobs pubGet missing builds the leaf', () {
      final filtered = filterPackages(
        pubGetPackages,
        config: pubGetConfig,
        criteria: PackageFilterCriteria.fromNameGlobs(
          pubGet: const FilterPubGet(state: PubGetState.missing),
        ),
        pubGetContext: pubGetContext,
      );

      expect(
        names(filtered),
        ['missing_config', 'stale_lock', 'stale_pubspec'],
      );
    });

    test('asOf start keeps snapshot after filesystem changes', () {
      final filteredStart = filterPackages(
        pubGetPackages,
        config: pubGetConfig,
        criteria: criteria(
          const FilterPubGet(
            state: PubGetState.missing,
            asOf: PubGetAsOf.start,
          ),
        ),
        pubGetContext: pubGetContext,
      );
      expect(names(filteredStart), contains('missing_config'));

      // Make missing_config look fresh after the snapshot.
      writePackageConfig(
        p.join(temp.path, 'packages', 'missing_config'),
        modified: DateTime.now().add(const Duration(seconds: 2)),
      );

      final stillStart = filterPackages(
        pubGetPackages,
        config: pubGetConfig,
        criteria: criteria(
          const FilterPubGet(
            state: PubGetState.missing,
            asOf: PubGetAsOf.start,
          ),
        ),
        pubGetContext: pubGetContext,
      );
      expect(names(stillStart), contains('missing_config'));

      final live = filterPackages(
        pubGetPackages,
        config: pubGetConfig,
        criteria: criteria(const FilterPubGet(state: PubGetState.missing)),
        pubGetContext: pubGetContext,
      );
      expect(names(live), isNot(contains('missing_config')));
    });

    test('workspace members share resolution root freshness', () {
      final wsTemp = Directory.systemTemp.createTempSync('ripple_pub_ws_');
      addTearDown(() {
        if (wsTemp.existsSync()) {
          wsTemp.deleteSync(recursive: true);
        }
      });
      File(p.join(wsTemp.path, 'ripple.yaml')).writeAsStringSync('''
packages:
  include:
    - workspace: .
''');
      File(p.join(wsTemp.path, 'pubspec.yaml')).writeAsStringSync('''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/a
  - packages/b
''');
      _writePubspec(
        p.join(wsTemp.path, 'packages', 'a'),
        'name: a\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );
      _writePubspec(
        p.join(wsTemp.path, 'packages', 'b'),
        'name: b\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );

      final config = loadRippleConfig(start: wsTemp);
      final packages = discoverPackages(config);
      final ctx = buildPubGetMatchContext(
        rippleRootPath: config.rootPath,
        packages: packages,
      );

      // No root package_config → all members missing.
      final missing = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterPubGet(state: PubGetState.missing)),
        pubGetContext: ctx,
      );
      expect(
        names(missing),
        containsAll(['_', 'a', 'b']),
      );

      final now = DateTime.now().add(const Duration(seconds: 2));
      writePackageConfig(wsTemp.path, modified: now);

      final resolved = filterPackages(
        packages,
        config: config,
        criteria: criteria(const FilterPubGet(state: PubGetState.resolved)),
        pubGetContext: buildPubGetMatchContext(
          rippleRootPath: config.rootPath,
          packages: packages,
        ),
      );
      expect(names(resolved), containsAll(['_', 'a', 'b']));
    });
  });

  group('filterExpressionHasLivePubGet', () {
    test('detects live pubGet nested in presets', () {
      final presets = <String, FilterExpr>{
        'needsPubGetLive': const FilterPubGet(
          state: PubGetState.missing,
          asOf: PubGetAsOf.live,
        ),
        'nested': const FilterAnd([
          FilterMatch(['core']),
          FilterPreset('needsPubGetLive'),
        ]),
      };

      expect(
        filterExpressionHasLivePubGet(
          const FilterPreset('needsPubGetLive'),
          presets: presets,
        ),
        isTrue,
      );
      expect(
        filterExpressionHasLivePubGet(
          const FilterPreset('nested'),
          presets: presets,
        ),
        isTrue,
      );
      expect(
        filterExpressionHasLivePubGet(
          const FilterPreset('withTestDir'),
          presets: {
            'withTestDir': const FilterDirExists(['test']),
          },
        ),
        isFalse,
      );
    });

    test('start asOf inside a preset is not live', () {
      expect(
        filterExpressionHasLivePubGet(
          const FilterPreset('snapshot'),
          presets: {
            'snapshot': const FilterPubGet(
              state: PubGetState.missing,
              asOf: PubGetAsOf.start,
            ),
          },
        ),
        isFalse,
      );
    });

    test('cycles in presets do not throw', () {
      expect(
        filterExpressionHasLivePubGet(
          const FilterPreset('a'),
          presets: {
            'a': const FilterPreset('b'),
            'b': const FilterPreset('a'),
          },
        ),
        isFalse,
      );
    });
  });

  group('packageStillMatchesLivePubGet', () {
    late Directory temp;
    late RippleConfig liveConfig;
    late List<RipplePackage> livePackages;
    late PubGetMatchContext liveContext;

    void writePackageConfig(String packageDir, {required DateTime modified}) {
      final file = File(
        p.join(packageDir, '.dart_tool', 'package_config.json'),
      );
      file
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}\n');
      file.setLastModifiedSync(modified);
    }

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ripple_live_recheck_');
      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
packages:
  include:
    - packages/*
''');
      _writePubspec(
        p.join(temp.path, 'packages', 'core'),
        '''
name: core
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'app'),
        '''
name: app
version: 1.0.0
environment:
  sdk: ^3.5.0
dependencies:
  core:
    path: ../core
''',
      );
      _writePubspec(
        p.join(temp.path, 'packages', 'other'),
        '''
name: other
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );

      liveConfig = loadRippleConfig(start: temp);
      livePackages = discoverPackages(liveConfig);
      liveContext = buildPubGetMatchContext(
        rippleRootPath: liveConfig.rootPath,
        packages: livePackages,
      );
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('seed match + live pubGet does not drop expansion dependents', () {
      final seedCriteria = criteria(
        const FilterAnd([
          FilterMatch(['core']),
          FilterPubGet(state: PubGetState.missing, asOf: PubGetAsOf.live),
        ]),
      );
      final selection = selectPackages(
        livePackages,
        config: liveConfig,
        criteria: seedCriteria,
        dependentsFilters: const GraphExpansionFilters(),
        pubGetContext: liveContext,
      );

      expect(names(selection.seeds), ['core']);
      expect(names(selection.dependents), ['app']);

      final app = selection.dependents.single;
      expect(
        packageStillMatchesLivePubGet(
          package: app,
          config: liveConfig,
          seedCriteria: seedCriteria,
          selection: selection,
          dependentsFilters: const GraphExpansionFilters(),
          pubGetContext: liveContext,
          packagesForChangedMapping: livePackages,
        ),
        isTrue,
      );
    });

    test('seed is skipped after live missing resolves', () {
      final seedCriteria = criteria(
        const FilterPubGet(state: PubGetState.missing, asOf: PubGetAsOf.live),
      );
      final selection = selectPackages(
        livePackages,
        config: liveConfig,
        criteria: seedCriteria,
        pubGetContext: liveContext,
      );
      final core = selection.seeds.singleWhere((p) => p.name == 'core');
      expect(
        packageStillMatchesLivePubGet(
          package: core,
          config: liveConfig,
          seedCriteria: seedCriteria,
          selection: selection,
          pubGetContext: liveContext,
          packagesForChangedMapping: livePackages,
        ),
        isTrue,
      );

      writePackageConfig(
        p.join(temp.path, 'packages', 'core'),
        modified: DateTime.now().add(const Duration(seconds: 2)),
      );

      expect(
        packageStillMatchesLivePubGet(
          package: core,
          config: liveConfig,
          seedCriteria: seedCriteria,
          selection: selection,
          pubGetContext: liveContext,
          packagesForChangedMapping: livePackages,
        ),
        isFalse,
      );
    });

    test('preset-wrapped live pubGet enables seed recheck', () {
      final presetTemp =
          Directory.systemTemp.createTempSync('ripple_live_preset_');
      addTearDown(() {
        if (presetTemp.existsSync()) {
          presetTemp.deleteSync(recursive: true);
        }
      });
      File(p.join(presetTemp.path, 'ripple.yaml')).writeAsStringSync('''
packages:
  include:
    - packages/*
  filtersPresets:
    needsGet:
      - pubGet: missing
        asOf: live
''');
      _writePubspec(
        p.join(presetTemp.path, 'packages', 'core'),
        '''
name: core
version: 1.0.0
environment:
  sdk: ^3.5.0
''',
      );
      final presetConfig = loadRippleConfig(start: presetTemp);
      final presetPackages = discoverPackages(presetConfig);
      final presetContext = buildPubGetMatchContext(
        rippleRootPath: presetConfig.rootPath,
        packages: presetPackages,
      );
      final seedCriteria = criteria(const FilterPreset('needsGet'));
      expect(
        filterExpressionHasLivePubGet(
          seedCriteria.expression,
          presets: presetConfig.packages.filtersPresets,
        ),
        isTrue,
      );

      final selection = selectPackages(
        presetPackages,
        config: presetConfig,
        criteria: seedCriteria,
        pubGetContext: presetContext,
      );
      final core = selection.seeds.single;
      expect(
        packageStillMatchesLivePubGet(
          package: core,
          config: presetConfig,
          seedCriteria: seedCriteria,
          selection: selection,
          pubGetContext: presetContext,
          packagesForChangedMapping: presetPackages,
        ),
        isTrue,
      );

      final file = File(
        p.join(presetTemp.path, 'packages', 'core', '.dart_tool',
            'package_config.json'),
      );
      file
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}\n');
      file.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));

      expect(
        packageStillMatchesLivePubGet(
          package: core,
          config: presetConfig,
          seedCriteria: seedCriteria,
          selection: selection,
          pubGetContext: presetContext,
          packagesForChangedMapping: presetPackages,
        ),
        isFalse,
      );
    });

    test('expansion live pubGet rechecks with expansion expression only', () {
      final seedCriteria = criteria(const FilterMatch(['core']));
      const dependentsFilters = GraphExpansionFilters(
        expression: FilterPubGet(
          state: PubGetState.missing,
          asOf: PubGetAsOf.live,
        ),
      );
      final selection = selectPackages(
        livePackages,
        config: liveConfig,
        criteria: seedCriteria,
        dependentsFilters: dependentsFilters,
        pubGetContext: liveContext,
      );
      final app = selection.dependents.single;
      expect(
        packageStillMatchesLivePubGet(
          package: app,
          config: liveConfig,
          seedCriteria: seedCriteria,
          selection: selection,
          dependentsFilters: dependentsFilters,
          pubGetContext: liveContext,
          packagesForChangedMapping: livePackages,
        ),
        isTrue,
      );

      writePackageConfig(
        p.join(temp.path, 'packages', 'app'),
        modified: DateTime.now().add(const Duration(seconds: 2)),
      );

      expect(
        packageStillMatchesLivePubGet(
          package: app,
          config: liveConfig,
          seedCriteria: seedCriteria,
          selection: selection,
          dependentsFilters: dependentsFilters,
          pubGetContext: liveContext,
          packagesForChangedMapping: livePackages,
        ),
        isFalse,
      );
    });
  });
}

void _writePubspec(String packageDir, String contents) {
  Directory(packageDir).createSync(recursive: true);
  File(p.join(packageDir, 'pubspec.yaml')).writeAsStringSync(contents);
}
