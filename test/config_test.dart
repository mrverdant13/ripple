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
      dirExists:
        - lib
      fileExists:
        - pubspec.yaml
      dependsOn:
        - test
      group: core
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

      final format = config.scripts['format.ci']!;
      expect(format.kind, ScriptKind.run);
      expect(format.commands, ['dart format --set-exit-if-changed .']);
      expect(format.filters, isNull);

      final analyze = config.scripts['analyze.ci']!;
      expect(analyze.kind, ScriptKind.exec);
      expect(analyze.commands, ['dart analyze .']);
      expect(analyze.filters!.dirExists, ['lib']);
      expect(analyze.filters!.fileExists, ['pubspec.yaml']);
      expect(analyze.filters!.dependsOn, ['test']);
      expect(analyze.filters!.group, 'core');
    });

    test('defaults missing packages and scripts to empty', () {
      final config = parseRippleYaml('name: bare\n', rootPath: '/r');
      expect(config.name, 'bare');
      expect(config.packages.include, isEmpty);
      expect(config.packages.exclude, isEmpty);
      expect(config.packages.groups, isEmpty);
      expect(config.scripts, isEmpty);
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
      group: core
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
      group: core
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
      dirExists:
        - lib
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
      expect(config.scripts['analyze.ci']!.filters!.dirExists, ['lib']);
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
