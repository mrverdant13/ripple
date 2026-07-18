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

    test('run: script does not announce a package scope', () async {
      final result = await runRipple(['run', 'root.pwd']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stderr, isNot(contains('[ripple]')));
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
    });

    test('run: multi-step script stops after the first failure', () async {
      final result = await runRipple(['run', 'root.steps.fail']);

      expect(result.exitCode, 7);
      expect(result.stdout, 'before-');
      expect(result.stdout, isNot(contains('after')));
    });

    test('run: script rejects package filters', () async {
      final result = await runRipple([
        'run',
        'root.pwd',
        '--packages',
        'ui',
      ]);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('run: script'));
      expect(result.stderr, contains('does not accept package filters'));
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
        '--packages',
        'core,ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test(
      'exec: multi-step script announces begin/end once per package',
      () async {
        final result = await runRipple([
          'run',
          'pkg.steps',
          '--packages',
          'core,ui',
        ]);

        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(stderrLines(result), [
          '[ripple] ▶ packages/core',
          '[ripple] ■ packages/core  (exit 0)',
          '[ripple] ▶ packages/ui',
          '[ripple] ■ packages/ui  (exit 0)',
        ]);
        expect(result.stdout, 'core-step2ui-step2');
      },
    );

    test('exec: end banner uses the failed step exit code', () async {
      final result = await runRipple([
        'run',
        'pkg.steps.fail',
        '--packages',
        'core,ui',
      ]);

      expect(result.exitCode, 5);
      expect(stderrLines(result), [
        '[ripple] ▶ packages/core',
        '[ripple] ■ packages/core  (exit 5)',
        '[ripple] ▶ packages/ui',
        '[ripple] ■ packages/ui  (exit 0)',
      ]);
    });

    test('exec: script injects RIPPLE_* environment variables', () async {
      final result = await runRipple([
        'run',
        'pkg.env',
        '--packages',
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
        '--packages',
        'ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'ui');
    });

    test('exec: multi-step script runs all steps per package', () async {
      final result = await runRipple([
        'run',
        'pkg.steps',
        '--packages',
        'core,ui',
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
          '--packages',
          'core,ui',
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
          '--packages',
          'core,ui',
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
        '--packages',
        'core,ui',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      // Script filters require dirExists: test; only core has test/.
      expect(stdoutLines(result), ['core']);
    });

    test('without --fail-fast continues after failures', () async {
      final result = await runRipple([
        'run',
        'pkg.fail',
        '--packages',
        'core,ui',
      ]);

      expect(result.exitCode, 3);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test('--fail-fast stops after the first failure', () async {
      final result = await runRipple([
        'run',
        '--fail-fast',
        'pkg.fail',
        '--packages',
        'core,ui',
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
      expect(help, contains('--packages'));
      expect(help, contains('--dir-exists'));
      expect(help, contains('--file-exists'));
      expect(help, contains('--depends-on'));
    });
  });
}
