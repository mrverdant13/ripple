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
    );
  }

  List<String> stdoutLines(ProcessResult result) {
    final text = (result.stdout as String).trimRight();
    if (text.isEmpty) {
      return const [];
    }
    return text.split('\n');
  }

  group('ripple list', () {
    test('lists discovered packages for the fixture root', () async {
      final result = await runRipple(['list']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'packages/core',
        'packages/ui',
        'tool',
      ]);
    });

    test('--group narrows to group members', () async {
      final result = await runRipple(['list', '--group', 'libs']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/core', 'packages/ui']);
    });

    test('--packages intersects by package name', () async {
      final result = await runRipple(['list', '--packages', 'ui,tool_pkg']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/ui', 'tool']);
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

    test('--depends-on narrows the printed set', () async {
      final result = await runRipple(['list', '--depends-on', 'core']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['packages/ui']);
    });

    test('combines filters with intersection semantics', () async {
      final result = await runRipple([
        'list',
        '--group',
        'libs',
        '--packages',
        'ui,tool_pkg',
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

    test('--help documents the filter flags', () async {
      final result = await runRipple(
        ['list', '--help'],
        workingDirectory: repoRoot,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final help = result.stdout as String;
      expect(help, contains('--group'));
      expect(help, contains('--packages'));
      expect(help, contains('--dir-exists'));
      expect(help, contains('--file-exists'));
      expect(help, contains('--depends-on'));
    });
  });
}
