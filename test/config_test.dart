import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/config.dart';
import 'package:test/test.dart';

void main() {
  group('parseRippleYaml', () {
    test('parses name, packages, groups, and scripts', () {
      const yaml = '''
name: demo
packages:
  include:
    - packages/*
    - tool
  exclude:
    - '**/example/**'
  groups:
    core:
      - packages/a
      - packages/b
    e2e:
      - packages/*/e2e
scripts:
  format.ci:
    run: dart format --set-exit-if-changed .
  analyze.ci:
    exec: dart analyze .
    filters:
      - dirExists: [lib]
      - fileExists: [pubspec.yaml]
      - dependsOn: [test]
      - group: core
      - match: ['*_api', core]
      - noMatch: ['*_test']
''';

      final config = parseRippleYaml(yaml, rootPath: '/tmp/demo');

      expect(config.rootPath, '/tmp/demo');
      expect(config.name, 'demo');
      expect(config.packages.include, ['packages/*', 'tool']);
      expect(config.packages.exclude, ['**/example/**']);
      expect(config.packages.groups, {
        'core': ['packages/a', 'packages/b'],
        'e2e': ['packages/*/e2e'],
      });
      expect(config.packages.filtersPresets, isEmpty);

      final format = config.scripts['format.ci']!;
      expect(format.kind, ScriptKind.run);
      expect(format.commands, ['dart format --set-exit-if-changed .']);
      expect(format.filters, isNull);

      final analyze = config.scripts['analyze.ci']!;
      expect(analyze.kind, ScriptKind.exec);
      expect(analyze.commands, ['dart analyze .']);
      expect(
        analyze.filters,
        const FilterAnd([
          FilterDirExists(['lib']),
          FilterFileExists(['pubspec.yaml']),
          FilterDependsOn(['test']),
          FilterGroup('core'),
          FilterMatch(['*_api', 'core']),
          FilterNoMatch(['*_test']),
        ]),
      );
    });

    test('defaults missing packages and scripts to empty', () {
      final config = parseRippleYaml('name: bare\n', rootPath: '/r');
      expect(config.name, 'bare');
      expect(config.packages.include, isEmpty);
      expect(config.packages.exclude, isEmpty);
      expect(config.packages.groups, isEmpty);
      expect(config.packages.filtersPresets, isEmpty);
      expect(config.scripts, isEmpty);
      expect(config.replacements, isEmpty);
      expect(config.replacementOverrides, isEmpty);
    });

    test('parses replacements map', () {
      const yaml = '''
replacements:
  dart: fvm dart
  flutter: fvm flutter
  coverde: dart run coverde
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');
      expect(config.replacements, {
        'dart': 'fvm dart',
        'flutter': 'fvm flutter',
        'coverde': 'dart run coverde',
      });
    });

    test('trims replacement keys', () {
      const yaml = '''
replacements:
  " dart ": fvm dart
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');
      expect(config.replacements, {'dart': 'fvm dart'});
    });

    test('allows quoted && in a replacement value', () {
      const yaml = '''
replacements:
  check: sh -c 'dart format . && dart analyze .'
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');
      expect(
        config.replacements['check'],
        "sh -c 'dart format . && dart analyze .'",
      );
    });

    test('rejects empty replacement keys', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  "": fvm dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('non-empty'),
          ),
        ),
      );
    });

    test('rejects whitespace-only replacement keys', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  "   ": fvm dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('non-empty'),
          ),
        ),
      );
    });

    test('rejects blank replacement values', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  dart: '   '
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('dart'), contains('non-empty')),
          ),
        ),
      );
    });

    test('rejects unquoted && in a replacement value', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  dart: fvm dart && echo done
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('dart'), contains('unquoted `&&`')),
          ),
        ),
      );
    });

    test('rejects RIPPLE_ replacement keys', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  RIPPLE_ROOT_PATH: /tmp
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('RIPPLE_ROOT_PATH'), contains('reserved')),
          ),
        ),
      );
    });

    test('rejects non-map replacements', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  - dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('replacements'),
          ),
        ),
      );
    });

    test('rejects non-string replacement values', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  dart:
    - fvm
    - dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('dart'), contains('command string')),
          ),
        ),
      );
    });

    test('rejects non-string replacement keys', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  1: fvm dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('must be strings'),
          ),
        ),
      );
    });

    test('rejects duplicate replacement keys after trim', () {
      expect(
        () => parseRippleYaml(
          '''
replacements:
  dart: fvm dart
  " dart ": puro dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('duplicated'),
          ),
        ),
      );
    });

    test('parses replacementOverrides', () {
      const yaml = '''
replacements:
  dart: fvm dart
  flutter: fvm flutter
replacementOverrides:
  - filters:
      - group: puro
    replacements:
      dart: puro dart
      flutter: puro flutter
  - filters:
      - match: ['legacy_*']
    replacements:
      dart: /opt/dart-3.3/bin/dart
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');
      expect(config.replacementOverrides, [
        const ReplacementOverride(
          filters: FilterAnd([
            FilterGroup('puro'),
          ]),
          replacements: {
            'dart': 'puro dart',
            'flutter': 'puro flutter',
          },
        ),
        const ReplacementOverride(
          filters: FilterAnd([
            FilterMatch(['legacy_*']),
          ]),
          replacements: {
            'dart': '/opt/dart-3.3/bin/dart',
          },
        ),
      ]);
    });

    test('ReplacementOverride equality distinguishes filters and maps', () {
      const override = ReplacementOverride(
        filters: FilterMatch(['legacy_*']),
        replacements: {'dart': 'puro dart'},
      );
      expect(override, override);
      expect(
        override,
        const ReplacementOverride(
          filters: FilterMatch(['legacy_*']),
          replacements: {'dart': 'puro dart'},
        ),
      );
      expect(
        override.hashCode,
        const ReplacementOverride(
          filters: FilterMatch(['legacy_*']),
          replacements: {'dart': 'puro dart'},
        ).hashCode,
      );
      expect(
        override,
        isNot(
          const ReplacementOverride(
            filters: FilterMatch(['other']),
            replacements: {'dart': 'puro dart'},
          ),
        ),
      );
      expect(
        override,
        isNot(
          const ReplacementOverride(
            filters: FilterMatch(['legacy_*']),
            replacements: {'dart': 'fvm dart'},
          ),
        ),
      );
      expect(
        override,
        isNot(
          const ReplacementOverride(
            filters: FilterMatch(['legacy_*']),
            replacements: {'dart': 'puro dart', 'flutter': 'x'},
          ),
        ),
      );
    });

    test('rejects non-list replacementOverrides', () {
      expect(
        () => parseRippleYaml(
          '''
replacementOverrides:
  filters:
    - match: [core]
  replacements:
    dart: puro dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('replacementOverrides'),
          ),
        ),
      );
    });

    test('rejects non-map replacementOverrides entries', () {
      expect(
        () => parseRippleYaml(
          '''
replacementOverrides:
  - just-a-string
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
                contains('replacementOverrides[0]'), contains('must be a map')),
          ),
        ),
      );
    });

    test('rejects replacementOverrides entries without filters', () {
      expect(
        () => parseRippleYaml(
          '''
replacementOverrides:
  - replacements:
      dart: puro dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('must declare `filters`'),
          ),
        ),
      );
    });

    test('rejects replacementOverrides entries without replacements', () {
      expect(
        () => parseRippleYaml(
          '''
replacementOverrides:
  - filters:
      - match: [core]
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('must declare `replacements`'),
          ),
        ),
      );
    });

    test('rejects empty replacementOverrides filters', () {
      expect(
        () => parseRippleYaml(
          '''
replacementOverrides:
  - filters: []
    replacements:
      dart: puro dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('non-empty'),
          ),
        ),
      );
    });

    test('rejects null replacementOverrides filters', () {
      expect(
        () => parseRippleYaml(
          '''
replacementOverrides:
  - filters:
    replacements:
      dart: puro dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('filters'),
          ),
        ),
      );
    });

    test('rejects map-form replacementOverrides filters', () {
      expect(
        () => parseRippleYaml(
          '''
replacementOverrides:
  - filters:
      match: [core]
    replacements:
      dart: puro dart
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('map-form'),
          ),
        ),
      );
    });

    test('rejects invalid replacements inside an override', () {
      expect(
        () => parseRippleYaml(
          '''
replacementOverrides:
  - filters:
      - match: [core]
    replacements:
      RIPPLE_ROOT_PATH: /tmp
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('reserved'),
          ),
        ),
      );
    });

    test('parses filtersPresets and preset filter nodes', () {
      const yaml = '''
packages:
  filtersPresets:
    e2eTestable:
      - dependsOn: [test]
      - dirExists: [e2e]
    nested:
      - preset: e2eTestable
      - match: ['*_app']
scripts:
  test.e2e:
    exec: dart test
    filters:
      - preset: e2eTestable
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');
      expect(
        config.packages.filtersPresets['e2eTestable'],
        const FilterAnd([
          FilterDependsOn(['test']),
          FilterDirExists(['e2e']),
        ]),
      );
      expect(
        config.packages.filtersPresets['nested'],
        const FilterAnd([
          FilterPreset('e2eTestable'),
          FilterMatch(['*_app']),
        ]),
      );
      expect(
        config.scripts['test.e2e']!.filters,
        const FilterAnd([
          FilterPreset('e2eTestable'),
        ]),
      );
    });

    test('rejects empty filtersPresets bodies', () {
      expect(
        () => parseRippleYaml(
          '''
packages:
  filtersPresets:
    empty: []
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('empty'), contains('non-empty')),
          ),
        ),
      );
    });

    test('rejects null filtersPresets bodies', () {
      expect(
        () => parseRippleYaml(
          '''
packages:
  filtersPresets:
    missing:
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('missing'), contains('non-empty')),
          ),
        ),
      );
    });

    test('rejects non-map filtersPresets', () {
      expect(
        () => parseRippleYaml(
          '''
packages:
  filtersPresets:
    - not-a-map
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('filtersPresets'),
          ),
        ),
      );
    });

    test('rejects non-string preset filter values', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    exec: dart analyze .
    filters:
      - preset: [e2e]
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('preset'), contains('must be a string')),
          ),
        ),
      );
    });

    test('rejects map-form filtersPresets bodies', () {
      expect(
        () => parseRippleYaml(
          '''
packages:
  filtersPresets:
    bad:
      dirExists: [lib]
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('list of filter expressions'),
              contains('map-form'),
            ),
          ),
        ),
      );
    });

    test('rejects blank preset names in filter nodes', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    exec: dart analyze .
    filters:
      - preset: '   '
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('preset'), contains('non-empty')),
          ),
        ),
      );
    });

    test('rejects script with both run and exec', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run: echo once
    exec: echo per-package
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('exactly one of `run:` or `exec:`'),
          ),
        ),
      );
    });

    test('rejects script with neither run nor exec', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    filters:
      - group: core
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('exactly one of `run:` or `exec:`'),
          ),
        ),
      );
    });

    test('rejects filters on a run script', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run: dart format .
    filters:
      - group: core
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('run:'), contains('filters')),
          ),
        ),
      );
    });

    test('rejects dependentsFilters on a run script', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run: dart format .
    dependentsFilters: []
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('run:'), contains('dependentsFilters')),
          ),
        ),
      );
    });

    test('rejects dependenciesFilters on a run script', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run: dart format .
    dependenciesFilters: []
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('run:'), contains('dependenciesFilters')),
          ),
        ),
      );
    });

    test('parses absent, empty, and constrained expansion filters', () {
      const yaml = '''
scripts:
  seedsOnly:
    exec: dart test
    filters:
      - match: [core]
  exhaustiveDependents:
    exec: dart test
    filters:
      - match: [core]
    dependentsFilters: []
  constrainedDependencies:
    exec: dart test
    filters:
      - match: [app]
    dependenciesFilters:
      - match: [ui]
      - preset: withTestDir
packages:
  filtersPresets:
    withTestDir:
      - dirExists: [test]
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');

      expect(config.scripts['seedsOnly']!.dependentsFilters, isNull);
      expect(config.scripts['seedsOnly']!.dependenciesFilters, isNull);

      expect(
        config.scripts['exhaustiveDependents']!.dependentsFilters,
        const GraphExpansionFilters(),
      );
      expect(
        config.scripts['exhaustiveDependents']!.dependenciesFilters,
        isNull,
      );

      expect(
        config.scripts['constrainedDependencies']!.dependenciesFilters,
        const GraphExpansionFilters(
          expression: FilterAnd([
            FilterMatch(['ui']),
            FilterPreset('withTestDir'),
          ]),
        ),
      );
    });

    test('rejects map-form expansion filters', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    exec: dart test
    dependentsFilters:
      match: [ui]
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('list of filter expressions'),
              contains('map-form'),
            ),
          ),
        ),
      );
    });

    test('parses nested and/or filter expressions', () {
      const yaml = '''
scripts:
  nested:
    exec: dart test
    filters:
      - match: ['*_app']
      - or:
          - dependsOn: [test]
          - dirExists: [test]
      - and:
          - noMatch: ['*_test']
          - fileExists: [pubspec.yaml]
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');
      expect(
        config.scripts['nested']!.filters,
        const FilterAnd([
          FilterMatch(['*_app']),
          FilterOr([
            FilterDependsOn(['test']),
            FilterDirExists(['test']),
          ]),
          FilterAnd([
            FilterNoMatch(['*_test']),
            FilterFileExists(['pubspec.yaml']),
          ]),
        ]),
      );
    });

    test('rejects map-form filters with a clear error', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    exec: dart analyze .
    filters:
      dirExists: [lib]
      match: ['*_api']
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('list of filter expressions'),
              contains('map-form'),
            ),
          ),
        ),
      );
    });

    test('rejects filter nodes with unknown keys', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    exec: dart analyze .
    filters:
      - mystery: e2e
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('unknown key "mystery"'), contains('filters[0]')),
          ),
        ),
      );
    });

    test('rejects filter nodes with multiple keys', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    exec: dart analyze .
    filters:
      - dirExists: [lib]
        match: ['*_api']
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('exactly one key'),
          ),
        ),
      );
    });

    test('rejects empty and/or children', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    exec: dart analyze .
    filters:
      - or: []
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('non-empty list'),
          ),
        ),
      );
    });

    test('parses run/exec as a YAML list of steps', () {
      const yaml = '''
scripts:
  check.ci:
    run:
      - dart format .
      - dart analyze .
  analyze.ci:
    exec:
      - dart analyze .
      - dart test
    filters:
      - dirExists: [lib]
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');

      expect(
        config.scripts['check.ci']!.commands,
        ['dart format .', 'dart analyze .'],
      );
      expect(config.scripts['check.ci']!.kind, ScriptKind.run);
      expect(
        config.scripts['analyze.ci']!.commands,
        ['dart analyze .', 'dart test'],
      );
      expect(config.scripts['analyze.ci']!.kind, ScriptKind.exec);
      expect(
        config.scripts['analyze.ci']!.filters,
        const FilterAnd([
          FilterDirExists(['lib']),
        ]),
      );
    });

    test('allows quoted && inside sh -c', () {
      const yaml = '''
scripts:
  shell.ci:
    run: sh -c 'dart format . && dart analyze .'
''';

      final config = parseRippleYaml(yaml, rootPath: '/r');
      expect(
        config.scripts['shell.ci']!.commands,
        ["sh -c 'dart format . && dart analyze .'"],
      );
    });

    test('rejects unquoted && in a string command', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run: dart format . && dart analyze .
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('unquoted `&&`'),
              contains('YAML list'),
            ),
          ),
        ),
      );
    });

    test('rejects unquoted && in a list step', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run:
      - dart format .
      - dart analyze . && dart test
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('unquoted `&&`'),
          ),
        ),
      );
    });

    test('rejects empty command list', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run: []
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('non-empty'), contains('list')),
          ),
        ),
      );
    });

    test('rejects non-string list items', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run:
      - dart format .
      - 42
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('list of strings'), contains('index 1')),
          ),
        ),
      );
    });

    test('rejects blank command strings', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad:
    run: '   '
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('non-empty string'),
          ),
        ),
      );
    });

    test('rejects non-map script entry', () {
      expect(
        () => parseRippleYaml(
          '''
scripts:
  bad: just-a-string
''',
          rootPath: '/r',
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('bad'), contains('must be a map')),
          ),
        ),
      );
    });

    test('rejects malformed YAML', () {
      expect(
        () => parseRippleYaml('packages: [\n', rootPath: '/r'),
        throwsA(isA<RippleConfigException>()),
      );
    });

    test('rejects non-map root document', () {
      expect(
        () => parseRippleYaml('- just a list\n', rootPath: '/r'),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('Not a map'),
          ),
        ),
      );
    });
  });

  group('parseRippleOverridesYaml / applyRippleOverlay', () {
    test('parses replacements and prepends override entries on merge', () {
      final overlay = parseRippleOverridesYaml('''
replacements:
  dart: dart
replacementOverrides:
  - filters:
      - match: [ci]
    replacements:
      dart: echo CI
''');
      expect(overlay.replacements, {'dart': 'dart'});
      expect(overlay.replacementOverrides, [
        const ReplacementOverride(
          filters: FilterAnd([
            FilterMatch(['ci']),
          ]),
          replacements: {'dart': 'echo CI'},
        ),
      ]);

      const base = RippleConfig(
        rootPath: '/r',
        replacements: {'dart': 'fvm dart', 'flutter': 'fvm flutter'},
        replacementOverrides: [
          ReplacementOverride(
            filters: FilterAnd([
              FilterMatch(['legacy']),
            ]),
            replacements: {'dart': 'puro dart'},
          ),
        ],
      );
      final merged = applyRippleOverlay(base, overlay);
      expect(merged.replacements, {'dart': 'dart', 'flutter': 'fvm flutter'});
      expect(merged.replacementOverrides.first,
          overlay.replacementOverrides.first);
      expect(merged.replacementOverrides.last, base.replacementOverrides.first);
      expect(merged.rootPath, '/r');
    });

    test('allows an empty overlay map', () {
      final overlay = parseRippleOverridesYaml('{}\n');
      expect(overlay.replacements, isEmpty);
      expect(overlay.replacementOverrides, isEmpty);
    });

    test('rejects unknown overlay keys', () {
      expect(
        () => parseRippleOverridesYaml('scripts:\n  x:\n    run: echo\n'),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('scripts'), contains('only')),
          ),
        ),
      );
    });

    test('rejects a non-map overlay document', () {
      expect(
        () => parseRippleOverridesYaml('- just a list\n'),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('Not a map'),
          ),
        ),
      );
    });

    test('rejects malformed overlay YAML', () {
      expect(
        () => parseRippleOverridesYaml('replacements: [\n'),
        throwsA(isA<RippleConfigException>()),
      );
    });

    test('rejects a null overlay document', () {
      expect(
        () => parseRippleOverridesYaml(''),
        throwsA(isA<RippleConfigException>()),
      );
    });
  });

  group('parseOverlayDescriptor', () {
    test('parses none, default, and file paths', () {
      expect(parseOverlayDescriptor('none'), isA<OverlayNone>());
      expect(parseOverlayDescriptor(' default '), isA<OverlayDefault>());
      expect(
        (parseOverlayDescriptor('file:ripple.ci.yaml') as OverlayFile).path,
        'ripple.ci.yaml',
      );
      expect(
        (parseOverlayDescriptor(r'file:C:\foo.yaml') as OverlayFile).path,
        r'C:\foo.yaml',
      );
    });

    test('rejects a bare path', () {
      expect(
        () => parseOverlayDescriptor('ripple.ci.yaml'),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('ripple.ci.yaml'), contains('file:<path>')),
          ),
        ),
      );
    });

    test('rejects an empty file: descriptor', () {
      expect(
        () => parseOverlayDescriptor('file:'),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('must include a path'),
          ),
        ),
      );
    });

    test('rejects a whitespace-only file: path', () {
      expect(
        () => parseOverlayDescriptor('file:   '),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('must include a path'),
          ),
        ),
      );
    });

    test('rejects an unknown prefix', () {
      expect(
        () => parseOverlayDescriptor('dir:overlays'),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('Invalid overlay descriptor'),
          ),
        ),
      );
    });

    test('rejects an empty descriptor', () {
      expect(
        () => parseOverlayDescriptor(''),
        throwsA(isA<RippleConfigException>()),
      );
    });

    test('overlayDescriptorFromSources prefers CLI over env', () {
      expect(
        overlayDescriptorFromSources(cli: 'none', env: 'file:ripple.ci.yaml'),
        isA<OverlayNone>(),
      );
      expect(
        overlayDescriptorFromSources(env: 'default'),
        isA<OverlayDefault>(),
      );
      expect(overlayDescriptorFromSources(env: ''), isNull);
      expect(overlayDescriptorFromSources(env: null), isNull);
      expect(overlayDescriptorFromSources(), isNull);
    });
  });

  group('findRippleYamlPath / loadRippleConfig', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('ripple_config_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('finds nearest ancestor ripple.yaml from a nested cwd', () {
      final root = Directory(p.join(tempRoot.path, 'repo'))..createSync();
      final nested = Directory(p.join(root.path, 'packages', 'a', 'lib'))
        ..createSync(recursive: true);
      File(p.join(root.path, 'ripple.yaml')).writeAsStringSync('''
name: nested-demo
packages:
  include:
    - packages/*
scripts:
  format.ci:
    run: dart format .
''');
      // Decoy deeper file must not win over the nearest ancestor.
      File(p.join(tempRoot.path, 'ripple.yaml'))
          .writeAsStringSync('name: outer\n');

      final yamlPath = findRippleYamlPath(start: nested);
      expect(yamlPath, p.join(root.path, 'ripple.yaml'));

      final config = loadRippleConfig(start: nested);
      expect(config.rootPath, root.path);
      expect(config.name, 'nested-demo');
      expect(config.packages.include, ['packages/*']);
      expect(config.scripts['format.ci']!.kind, ScriptKind.run);
    });

    test('throws when no ripple.yaml exists in ancestry', () {
      final orphan = Directory(p.join(tempRoot.path, 'orphan'))..createSync();
      expect(
        () => findRippleYamlPath(start: orphan),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('No ripple.yaml found'),
          ),
        ),
      );
    });

    test('loadRippleConfig ignores a missing ripple_overrides.yaml', () {
      final root = Directory(p.join(tempRoot.path, 'repo'))..createSync();
      File(p.join(root.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: fvm dart
''');

      final config = loadRippleConfig(start: root);
      expect(config.replacements, {'dart': 'fvm dart'});
      expect(config.replacementOverrides, isEmpty);
    });

    test('loadRippleConfig merges ripple_overrides.yaml when present', () {
      final root = Directory(p.join(tempRoot.path, 'repo'))..createSync();
      File(p.join(root.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: fvm dart
  flutter: fvm flutter
replacementOverrides:
  - filters:
      - match: [legacy]
    replacements:
      dart: puro dart
''');
      File(p.join(root.path, rippleOverridesFileName)).writeAsStringSync('''
replacements:
  dart: dart
replacementOverrides:
  - filters:
      - match: [ci]
    replacements:
      dart: echo CI
''');

      final config = loadRippleConfig(start: root);
      expect(config.replacements, {'dart': 'dart', 'flutter': 'fvm flutter'});
      expect(config.replacementOverrides, [
        const ReplacementOverride(
          filters: FilterAnd([
            FilterMatch(['ci']),
          ]),
          replacements: {'dart': 'echo CI'},
        ),
        const ReplacementOverride(
          filters: FilterAnd([
            FilterMatch(['legacy']),
          ]),
          replacements: {'dart': 'puro dart'},
        ),
      ]);
    });

    test('loadRippleConfig reads overlay from the Ripple root, not cwd', () {
      final root = Directory(p.join(tempRoot.path, 'repo'))..createSync();
      final nested = Directory(p.join(root.path, 'packages', 'a'))
        ..createSync(recursive: true);
      File(p.join(root.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: fvm dart
''');
      File(p.join(root.path, rippleOverridesFileName)).writeAsStringSync('''
replacements:
  dart: dart
''');
      File(p.join(nested.path, rippleOverridesFileName)).writeAsStringSync('''
replacements:
  dart: WRONG
''');

      final config = loadRippleConfig(start: nested);
      expect(config.replacements, {'dart': 'dart'});
    });

    test('loadRippleConfig rejects an invalid overlay file', () {
      final root = Directory(p.join(tempRoot.path, 'repo'))..createSync();
      File(p.join(root.path, 'ripple.yaml')).writeAsStringSync('name: demo\n');
      File(p.join(root.path, rippleOverridesFileName)).writeAsStringSync('''
scripts:
  bad:
    run: echo
''');

      expect(
        () => loadRippleConfig(start: root),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('only'),
          ),
        ),
      );
    });

    test('mergeDefaultRippleOverlay is a no-op when the file is absent', () {
      const config = RippleConfig(
        rootPath: '/does/not/exist',
        replacements: {'dart': 'fvm dart'},
      );
      expect(
        mergeDefaultRippleOverlay(config).replacements,
        {'dart': 'fvm dart'},
      );
    });
  });
}
