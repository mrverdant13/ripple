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
    );
  }

  List<String> stdoutLines(ProcessResult result) {
    final text = (result.stdout as String).trimRight();
    if (text.isEmpty) {
      return const [];
    }
    return const LineSplitter().convert(text);
  }

  List<String> stderrLines(ProcessResult result) {
    final text = (result.stderr as String).trimRight();
    if (text.isEmpty) {
      return const [];
    }
    return const LineSplitter().convert(text);
  }

  group('ripple run', () {
    test('run: script executes once at the config root', () async {
      final result = await runRipple(['run', 'root.pwd']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [p.normalize(fixtureRoot)]);
    });

    test('run: script announces command banners without package scope',
        () async {
      final result = await runRipple(['run', 'root.pwd']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stderrLines(result), [
        '[ripple] \$ pwd',
        '[ripple] \$ pwd  (exit 0)',
      ]);
      expect(result.stderr, isNot(contains('▶')));
      expect(result.stderr, isNot(contains('■')));
    });

    test('run: script sets RIPPLE_ROOT_PATH without package vars', () async {
      final environment = Map<String, String>.from(Platform.environment)
        ..remove('RIPPLE_PACKAGE_PATH')
        ..remove('RIPPLE_PACKAGE_NAME')
        ..remove('RIPPLE_PACKAGES');
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=$packageConfig',
          rippleScript,
          'run',
          'root.env',
        ],
        workingDirectory: fixtureRoot,
        environment: environment,
        includeParentEnvironment: false,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [p.normalize(fixtureRoot)]);
    });

    test(
      'run: script hides parent RIPPLE_PACKAGE_* even when already set',
      () async {
        final result = await runRipple(
          ['run', 'root.env'],
          environment: {
            'RIPPLE_PACKAGE_PATH': '/leaked/package',
            'RIPPLE_PACKAGE_NAME': 'leaked',
          },
        );

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(stdoutLines(result), [p.normalize(fixtureRoot)]);
      },
    );

    test('run: script substitutes RIPPLE_ROOT_PATH placeholders', () async {
      final result = await runRipple(['run', 'root.subst']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, p.normalize(fixtureRoot));
    });

    test('run: multi-step script runs steps sequentially', () async {
      final result = await runRipple(['run', 'root.steps']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'first-second');
      expect(stderrLines(result), [
        '[ripple] \$ printf %s first-',
        '[ripple] \$ printf %s first-  (exit 0)',
        '[ripple] \$ printf %s second',
        '[ripple] \$ printf %s second  (exit 0)',
      ]);
    });

    test('run: multi-step script stops after the first failure', () async {
      final result = await runRipple(['run', 'root.steps.fail']);

      expect(result.exitCode, 7);
      expect(result.stdout, 'before-');
      expect(result.stdout, isNot(contains('after')));
      expect(stderrLines(result), [
        '[ripple] \$ sh -c \'printf %s before-; exit 7\'',
        '[ripple] \$ sh -c \'printf %s before-; exit 7\'  (exit 7)',
      ]);
    });

    test('run: script rejects package filters', () async {
      final result = await runRipple([
        'run',
        'root.pwd',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('run: script'));
      expect(result.stderr, contains('does not accept package filters'));
      expect(result.stderr, contains('--match'));
    });

    test('run: script rejects RIPPLE_PACKAGES selection', () async {
      final result = await runRipple(
        ['run', 'root.pwd'],
        environment: {'RIPPLE_PACKAGES': 'ui'},
      );

      expect(result.exitCode, 64);
      expect(result.stderr, contains('does not accept package filters'));
      expect(result.stderr, contains('RIPPLE_PACKAGES'));
    });

    test('exec: script runs once per matching package', () async {
      final result = await runRipple([
        'run',
        'pkg.name',
        '--match',
        'core',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test(
      'exec: multi-step script announces package and per-step command banners',
      () async {
        final result = await runRipple([
          'run',
          'pkg.steps',
          '--match',
          'core',
          '--match',
          'ui',
        ]);

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(stderrLines(result), [
          '[ripple] ▶ packages/core',
          '[ripple] \$ printf %s core-',
          '[ripple] \$ printf %s core-  (exit 0)',
          '[ripple] \$ printf %s step2',
          '[ripple] \$ printf %s step2  (exit 0)',
          '[ripple] ■ packages/core  (exit 0)',
          '[ripple] ▶ packages/ui',
          '[ripple] \$ printf %s ui-',
          '[ripple] \$ printf %s ui-  (exit 0)',
          '[ripple] \$ printf %s step2',
          '[ripple] \$ printf %s step2  (exit 0)',
          '[ripple] ■ packages/ui  (exit 0)',
        ]);
        expect(result.stdout, 'core-step2ui-step2');
      },
    );

    test('exec: end banner uses the failed step exit code', () async {
      final result = await runRipple([
        'run',
        'pkg.steps.fail',
        '--match',
        'core',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 5);
      expect(stderrLines(result), [
        '[ripple] ▶ packages/core',
        '[ripple] \$ sh -c \'printf "%s\\n" "core"; if [ "core" = core ]; '
            'then exit 5; fi\'',
        '[ripple] \$ sh -c \'printf "%s\\n" "core"; if [ "core" = core ]; '
            'then exit 5; fi\'  (exit 5)',
        '[ripple] ■ packages/core  (exit 5)',
        '[ripple] ▶ packages/ui',
        '[ripple] \$ sh -c \'printf "%s\\n" "ui"; if [ "ui" = core ]; '
            'then exit 5; fi\'',
        '[ripple] \$ sh -c \'printf "%s\\n" "ui"; if [ "ui" = core ]; '
            'then exit 5; fi\'  (exit 0)',
        '[ripple] \$ printf %s should-not-run',
        '[ripple] \$ printf %s should-not-run  (exit 0)',
        '[ripple] ■ packages/ui  (exit 0)',
      ]);
    });

    test('exec: script injects RIPPLE_* environment variables', () async {
      final result = await runRipple([
        'run',
        'pkg.env',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        p.normalize(fixtureRoot),
        p.normalize(p.join(fixtureRoot, 'packages', 'ui')),
        'ui',
      ]);
    });

    test('exec: script substitutes RIPPLE_* placeholders', () async {
      final result = await runRipple([
        'run',
        'pkg.subst',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'ui');
    });

    test('exec: multi-step script runs all steps per package', () async {
      final result = await runRipple([
        'run',
        'pkg.steps',
        '--match',
        'core',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'core-step2ui-step2');
    });

    test(
      'exec: multi-step skips remaining steps for a failed package',
      () async {
        final result = await runRipple([
          'run',
          'pkg.steps.fail',
          '--match',
          'core',
          '--match',
          'ui',
        ]);

        expect(result.exitCode, 5);
        expect(stdoutLines(result), ['core', 'ui', 'should-not-run']);
      },
    );

    test(
      'exec: multi-step --fail-fast stops before later packages',
      () async {
        final result = await runRipple([
          'run',
          '--fail-fast',
          'pkg.steps.fail',
          '--match',
          'core',
          '--match',
          'ui',
        ]);

        expect(result.exitCode, 5);
        expect(stdoutLines(result), ['core']);
        expect(result.stdout, isNot(contains('ui')));
        expect(result.stdout, isNot(contains('should-not-run')));
      },
    );

    test('script filters intersect with CLI filters', () async {
      final result = await runRipple([
        'run',
        'pkg.filtered',
        '--match',
        'core',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      // Script filters require dirExists: test; only core has test/.
      expect(stdoutLines(result), ['core']);
    });

    test('script preset filters select matching packages', () async {
      final result = await runRipple(['run', 'pkg.preset']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core']);
    });

    test('dependentsFilters: [] expands reverse closure of seeds', () async {
      final result = await runRipple(['run', 'pkg.dependents']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['app', 'core', 'ui']);
    });

    test('dependenciesFilters: [] expands forward closure of seeds', () async {
      final result = await runRipple(['run', 'pkg.dependencies']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['app', 'core', 'ui']);
    });

    test('constrained dependentsFilters keeps matching dependents', () async {
      final result = await runRipple(['run', 'pkg.dependents.constrained']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test('RIPPLE_PACKAGES narrows seeds before dependents expansion', () async {
      final result = await runRipple(
        ['run', 'pkg.dependents.env'],
        environment: const {'RIPPLE_PACKAGES': 'core'},
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      // Seed narrowed to core; expansion still adds app + ui (not tool_pkg).
      expect(stdoutLines(result), ['app', 'core', 'ui']);
    });

    test('--preset ANDs into seed filters with flat flags', () async {
      final result = await runRipple([
        'run',
        'pkg.name',
        '--preset',
        'libsOnly',
        '--dir-exists',
        'test',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core']);
    });

    test('run: script rejects --preset', () async {
      final result = await runRipple([
        'run',
        'root.pwd',
        '--preset',
        'withTestDir',
      ]);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('does not accept package filters'));
      expect(result.stderr, contains('--preset'));
    });

    test('without --fail-fast continues after failures', () async {
      final result = await runRipple([
        'run',
        'pkg.fail',
        '--match',
        'core',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 3);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test('--fail-fast stops after the first failure', () async {
      final result = await runRipple([
        'run',
        '--fail-fast',
        'pkg.fail',
        '--match',
        'core',
        '--match',
        'ui',
      ]);

      expect(result.exitCode, 3);
      expect(stdoutLines(result), ['core']);
    });

    test('unknown script fails with available names', () async {
      final result = await runRipple(['run', 'does.not.exist']);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('Unknown script "does.not.exist"'));
      expect(result.stderr, contains('root.pwd'));
      expect(result.stderr, contains('pkg.name'));
    });

    test('missing script name fails with usage guidance', () async {
      final result = await runRipple(['run']);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('Missing script name'));
    });

    test('--help documents filters and --fail-fast', () async {
      final result = await runRipple(
        ['run', '--help'],
        workingDirectory: repoRoot,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final help = result.stdout as String;
      expect(help, contains('--fail-fast'));
      expect(help, contains('--group'));
      expect(help, contains('--match'));
      expect(help, contains('--no-match'));
      expect(help, contains('--dir-exists'));
      expect(help, contains('--file-exists'));
      expect(help, contains('--depends-on'));
      expect(help, contains('--preset'));
    });
  });
}
