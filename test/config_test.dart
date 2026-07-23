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
  });
}
