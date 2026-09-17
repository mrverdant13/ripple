import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final repoRoot = Directory.current.path;
  final packageConfig = p.join(repoRoot, '.dart_tool', 'package_config.json');
  final rippleScript = p.join(repoRoot, 'bin', 'ripple.dart');
  final fixtureRoot = Directory(
    p.join('test', 'fixtures', 'discovery_workspace'),
  ).absolute.path;

  Future<ProcessResult> runRipple(
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=$packageConfig',
        rippleScript,
        ...args,
      ],
      workingDirectory: workingDirectory ?? fixtureRoot,
      environment: {
        ...Platform.environment,
        ...?environment,
      },
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  List<String> stdoutLines(ProcessResult result) {
    final text = (result.stdout as String).trimRight();
    if (text.isEmpty) {
      return const [];
    }
    return const LineSplitter().convert(text);
  }

  group('ripple list', () {
    test('lists discovered packages for the fixture root', () async {
      final result = await runRipple(['list']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/app',
        'packages/core',
        'packages/ui',
        'tool',
      ]);
    });

    test('--group narrows to group members', () async {
      final result = await runRipple(['list', '--group', 'libs']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/app',
        'packages/core',
        'packages/ui',
      ]);
    });

    test('--match exact names select packages', () async {
      final result =
          await runRipple(['list', '--match', 'ui', '--match', 'tool_pkg']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/ui', 'tool']);
    });

    test('--match selects by package-name globs', () async {
      final result = await runRipple([
        'list',
        '--match',
        '*_pkg',
        '--match',
        'core',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/core', 'tool']);
    });

    test('--no-match excludes by package-name globs', () async {
      final result = await runRipple([
        'list',
        '--no-match',
        'ui',
        '--no-match',
        '*_pkg',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/app', 'packages/core']);
    });

    test('--dir-exists narrows the printed set', () async {
      final result = await runRipple(['list', '--dir-exists', 'test']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/core']);
    });

    test('--file-exists narrows the printed set', () async {
      final result = await runRipple(['list', '--file-exists', 'README.md']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/ui']);
    });

    test('--no-dir-exists narrows the printed set', () async {
      final result = await runRipple(['list', '--no-dir-exists', 'test']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/app',
        'packages/ui',
        'tool',
      ]);
    });

    test('--no-file-exists narrows the printed set', () async {
      final result =
          await runRipple(['list', '--no-file-exists', 'README.md']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/app',
        'packages/core',
        'tool',
      ]);
    });

    test('--no-file-exists ANDs with --dir-exists', () async {
      final result = await runRipple([
        'list',
        '--dir-exists',
        'lib',
        '--no-file-exists',
        'README.md',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/core']);
    });

    test('--no-file-exists matches packages missing a relative file',
        () async {
      final temp =
          Directory.systemTemp.createTempSync('ripple_list_not_exists_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
name: not_exists
packages:
  include:
    - apps/*
  groups:
    apps:
      - apps/*
''');
      void writeApp(String name, {required bool withPodfile}) {
        final appDir = Directory(p.join(temp.path, 'apps', name))
          ..createSync(recursive: true);
        File(p.join(appDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: $name
environment:
  sdk: ^3.5.0
''');
        Directory(p.join(appDir.path, 'lib')).createSync();
        if (withPodfile) {
          final iosDir = Directory(p.join(appDir.path, 'ios'))..createSync();
          File(p.join(iosDir.path, 'Podfile')).writeAsStringSync('# stub');
        }
      }

      writeApp('mobile', withPodfile: true);
      writeApp('admin', withPodfile: false);

      final withoutPodfile = await runRipple(
        ['list', '--group', 'apps', '--no-file-exists', 'ios/Podfile'],
        workingDirectory: temp.path,
      );
      expect(withoutPodfile.exitCode, 0,
          reason: withoutPodfile.stderr as String);
      expect(stdoutLines(withoutPodfile), ['apps/admin']);

      final withLibNoPods = await runRipple(
        [
          'list',
          '--dir-exists',
          'lib',
          '--no-dir-exists',
          'ios/Pods',
        ],
        workingDirectory: temp.path,
      );
      expect(withLibNoPods.exitCode, 0, reason: withLibNoPods.stderr as String);
      expect(stdoutLines(withLibNoPods), ['apps/admin', 'apps/mobile']);
    });

    test('--depends-on narrows the printed set', () async {
      final result = await runRipple(['list', '--depends-on', 'core']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/ui']);
    });

    test('--preset narrows using packages.filtersPresets', () async {
      final result = await runRipple(['list', '--preset', 'withTestDir']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/core']);
    });

    test('--preset ANDs with flat flags', () async {
      final result = await runRipple([
        'list',
        '--preset',
        'libsOnly',
        '--dir-exists',
        'test',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/core']);
    });

    test('unknown --preset fails with a clear error', () async {
      final result = await runRipple(['list', '--preset', 'missing']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Unknown filter preset "missing"'));
    });

    test('combines filters with intersection semantics', () async {
      final result = await runRipple([
        'list',
        '--group',
        'libs',
        '--match',
        'ui',
        '--match',
        'tool_pkg',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/ui']);
    });

    test('RIPPLE_PACKAGES intersects with other filters', () async {
      final result = await runRipple(
        ['list', '--group', 'libs'],
        environment: const {'RIPPLE_PACKAGES': 'ui,tool_pkg'},
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/ui']);
    });

    test('unknown --group fails with a clear error', () async {
      final result = await runRipple(['list', '--group', 'missing']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Unknown package group "missing"'));
    });

    test('invalid --match glob fails with a clear error', () async {
      final result = await runRipple(['list', '--match', '[']);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('Invalid package-name glob "["'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('outside any ripple.yaml ancestry fails clearly', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_list_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      final result = await runRipple(
        ['list'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('No ripple.yaml found'));
    });

    test('--changed since:HEAD fails with guidance', () async {
      final result = await runRipple([
        'list',
        '--changed',
        'since:HEAD',
      ]);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('workdir:HEAD'));
    });

    test('--help documents the filter flags', () async {
      final result = await runRipple(
        ['list', '--help'],
        workingDirectory: repoRoot,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final help = result.stdout as String;
      expect(help, contains('--group'));
      expect(help, contains('--match'));
      expect(help, contains('--changed'));
      expect(help, contains('--no-match'));
      expect(help, contains('--dir-exists'));
      expect(help, contains('--file-exists'));
      expect(help, contains('--no-dir-exists'));
      expect(help, contains('--no-file-exists'));
      expect(help, contains('--depends-on'));
      expect(help, contains('--preset'));
      expect(help, contains('--sdk'));
      expect(help, contains('--dependents'));
      expect(help, contains('--dependencies'));
      expect(help, contains('--format'));
      expect(help, contains('paths'));
      expect(help, contains('json'));
      expect(help, contains('mermaid'));
    });

    test('without expansion flags stays seed-only', () async {
      final result = await runRipple(['list', '--match', 'core']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/core']);
    });

    test('--dependents expands the reverse workspace closure', () async {
      final result = await runRipple([
        'list',
        '--match',
        'core',
        '--dependents',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/app',
        'packages/core',
        'packages/ui',
      ]);
    });

    test('--dependencies with a leaf seed stays seed-only', () async {
      final result = await runRipple([
        'list',
        '--match',
        'core',
        '--dependencies',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/core']);
    });

    test('--dependencies expands the forward workspace closure', () async {
      final result = await runRipple([
        'list',
        '--match',
        'app',
        '--dependencies',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/app',
        'packages/core',
        'packages/ui',
      ]);
    });

    test('--dependents and --dependencies union both closures', () async {
      final result = await runRipple([
        'list',
        '--match',
        'ui',
        '--dependents',
        '--dependencies',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/app',
        'packages/core',
        'packages/ui',
      ]);
    });

    test('RIPPLE_PACKAGES narrows seeds before --dependents expansion',
        () async {
      final result = await runRipple(
        ['list', '--dependents'],
        environment: const {'RIPPLE_PACKAGES': 'core'},
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/app',
        'packages/core',
        'packages/ui',
      ]);
    });

    test('--changed with --dependents expands from changed seeds', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_list_changed_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
name: changed_expand
packages:
  include:
    - packages/*
''');
      for (final entry in [
        ('core', null),
        ('ui', 'core'),
        ('app', 'ui'),
      ]) {
        final dir = Directory(p.join(temp.path, 'packages', entry.$1))
          ..createSync(recursive: true);
        final deps = entry.$2 == null
            ? ''
            : '''
dependencies:
  ${entry.$2}:
''';
        File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: ${entry.$1}
environment:
  sdk: ^3.5.0
$deps
''');
        File(p.join(dir.path, 'lib', 'x.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('// ${entry.$1}\n');
      }

      Future<void> git(List<String> args) async {
        final result = await Process.run(
          'git',
          args,
          workingDirectory: temp.path,
          runInShell: false,
        );
        expect(
          result.exitCode,
          0,
          reason: 'git ${args.join(' ')}: ${result.stderr}',
        );
      }

      await git(['init']);
      await git(['config', 'user.email', 'test@test.com']);
      await git(['config', 'user.name', 'test']);
      await git(['add', '.']);
      await git(['commit', '-m', 'initial']);
      await git(['branch', '-M', 'main']);
      await git(['checkout', '-b', 'feature']);

      File(p.join(temp.path, 'packages', 'core', 'lib', 'x.dart'))
          .writeAsStringSync('// core changed\n');
      await git(['add', 'packages/core/lib/x.dart']);
      await git(['commit', '-m', 'change core']);

      final seedsOnly = await runRipple(
        ['list', '--changed', 'since:main'],
        workingDirectory: temp.path,
      );
      expect(seedsOnly.exitCode, 0, reason: seedsOnly.stderr as String);
      expect(stdoutLines(seedsOnly), ['packages/core']);

      final withDependents = await runRipple(
        ['list', '--changed', 'since:main', '--dependents'],
        workingDirectory: temp.path,
      );
      expect(
        withDependents.exitCode,
        0,
        reason: withDependents.stderr as String,
      );
      expect(stdoutLines(withDependents), [
        'packages/app',
        'packages/core',
        'packages/ui',
      ]);
    });

    test('--format paths matches default output', () async {
      final defaultResult = await runRipple(['list']);
      final pathsResult = await runRipple(['list', '--format', 'paths']);

      expect(defaultResult.exitCode, 0, reason: defaultResult.stderr as String);
      expect(pathsResult.exitCode, 0, reason: pathsResult.stderr as String);
      expect(pathsResult.stdout, defaultResult.stdout);
      expect(stdoutLines(pathsResult), [
        'packages/app',
        'packages/core',
        'packages/ui',
        'tool',
      ]);
    });

    test('--format json prints a valid package array', () async {
      final result = await runRipple(['list', '--format', 'json']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final decoded = jsonDecode((result.stdout as String).trim()) as List;
      expect(decoded, hasLength(4));
      expect(
        decoded.map((entry) => (entry as Map)['path']).toList(),
        [
          'packages/app',
          'packages/core',
          'packages/ui',
          'tool',
        ],
      );

      final ui = decoded.cast<Map<String, dynamic>>().singleWhere(
            (entry) => entry['name'] == 'ui',
          );
      expect(ui['version'], '1.2.3');
      expect(ui['sdk'], 'dart');
      expect(ui['workspaceDependencies'], ['core']);
      expect(ui['workspaceDependents'], ['app']);

      final core = decoded.cast<Map<String, dynamic>>().singleWhere(
            (entry) => entry['name'] == 'core',
          );
      expect(core['version'], isNull);
      expect(core['workspaceDependencies'], isEmpty);
    });

    test('--format json respects --match and keeps workspace edges', () async {
      final result = await runRipple([
        'list',
        '--format',
        'json',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final decoded = jsonDecode((result.stdout as String).trim()) as List;
      expect(decoded, hasLength(1));
      final ui = decoded.single as Map<String, dynamic>;
      expect(ui['path'], 'packages/ui');
      expect(ui['workspaceDependencies'], ['core']);
      expect(ui['workspaceDependents'], ['app']);
    });

    test('--format mermaid prints workspace edges and isolates', () async {
      final result = await runRipple(['list', '--format', 'mermaid']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final mermaid = result.stdout as String;
      expect(mermaid, startsWith('flowchart TD\n'));
      expect(mermaid, contains('ui --> core'));
      expect(mermaid, contains('app --> ui'));
      expect(mermaid, contains('tool_pkg'));
      expect(mermaid, isNot(contains('path')));
    });

    test('--format mermaid with --match keeps only selected nodes', () async {
      final result = await runRipple([
        'list',
        '--format',
        'mermaid',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final mermaid = result.stdout as String;
      expect(mermaid, contains('  ui\n'));
      expect(mermaid, isNot(contains('-->')));
      expect(mermaid, isNot(contains('core')));
      expect(mermaid, isNot(contains('app')));
    });

    test('unknown --format is a usage error', () async {
      final result = await runRipple(['list', '--format', 'yaml']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('format'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('--format json reports flutter sdk from environment.flutter',
        () async {
      final temp = Directory.systemTemp.createTempSync('ripple_list_sdk_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
name: sdk_probe
packages:
  include:
    - packages/*
''');
      final flutterPkg = Directory(p.join(temp.path, 'packages', 'ui_kit'))
        ..createSync(recursive: true);
      File(p.join(flutterPkg.path, 'pubspec.yaml')).writeAsStringSync('''
name: ui_kit
version: 0.1.0
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''');
      final dartPkg = Directory(p.join(temp.path, 'packages', 'core'))
        ..createSync(recursive: true);
      File(p.join(dartPkg.path, 'pubspec.yaml')).writeAsStringSync('''
name: core
version: 1.0.0
environment:
  sdk: ^3.5.0
''');

      final result = await runRipple(
        ['list', '--format', 'json'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final decoded = jsonDecode((result.stdout as String).trim()) as List;
      final byName = {
        for (final entry in decoded.cast<Map<String, dynamic>>())
          entry['name'] as String: entry,
      };
      expect(byName['ui_kit']!['sdk'], 'flutter');
      expect(byName['core']!['sdk'], 'dart');
    });

    test('--sdk filters by environment.flutter', () async {
      final temp =
          Directory.systemTemp.createTempSync('ripple_list_sdk_filter_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
name: sdk_filter
packages:
  include:
    - packages/*
  groups:
    apps:
      - packages/mobile
      - packages/admin
''');
      void writePkg(String dir, String body) {
        final packageDir = Directory(p.join(temp.path, 'packages', dir))
          ..createSync(recursive: true);
        File(p.join(packageDir.path, 'pubspec.yaml')).writeAsStringSync(body);
      }

      writePkg(
        'core',
        '''
name: core
environment:
  sdk: ^3.5.0
''',
      );
      writePkg(
        'api_client',
        '''
name: api_client
environment:
  sdk: ^3.5.0
''',
      );
      writePkg(
        'ui',
        '''
name: ui
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''',
      );
      writePkg(
        'mobile',
        '''
name: mobile
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''',
      );
      writePkg(
        'admin',
        '''
name: admin
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''',
      );
      writePkg(
        'macos_only',
        '''
name: macos_only
environment:
  sdk: ^3.5.0
  flutter: '>=3.24.0'
''',
      );
      writePkg(
        'fake_flutter_dep',
        '''
name: fake_flutter_dep
environment:
  sdk: ^3.5.0
dependencies:
  flutter:
    sdk: flutter
''',
      );

      final dartResult = await runRipple(
        ['list', '--sdk', 'dart'],
        workingDirectory: temp.path,
      );
      expect(dartResult.exitCode, 0, reason: dartResult.stderr as String);
      expect(stdoutLines(dartResult), [
        'packages/api_client',
        'packages/core',
        'packages/fake_flutter_dep',
      ]);

      final flutterResult = await runRipple(
        ['list', '--sdk', 'flutter'],
        workingDirectory: temp.path,
      );
      expect(flutterResult.exitCode, 0, reason: flutterResult.stderr as String);
      expect(stdoutLines(flutterResult), [
        'packages/admin',
        'packages/macos_only',
        'packages/mobile',
        'packages/ui',
      ]);

      final appsFlutter = await runRipple(
        ['list', '--sdk', 'flutter', '--group', 'apps'],
        workingDirectory: temp.path,
      );
      expect(appsFlutter.exitCode, 0, reason: appsFlutter.stderr as String);
      expect(stdoutLines(appsFlutter), [
        'packages/admin',
        'packages/mobile',
      ]);
    });

    test('unknown --sdk value is a usage error', () async {
      final result = await runRipple(['list', '--sdk', 'node']);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('sdk'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });
  });
}
