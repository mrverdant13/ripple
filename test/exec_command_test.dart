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

  group('ripple exec', () {
    test('runs the command once per selected package', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'core,ui',
        '--',
        'printenv',
        'RIPPLE_PACKAGE_NAME',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test('--match selects packages by name glob', () async {
      final result = await runRipple([
        'exec',
        '--match',
        'u*',
        '--',
        'printenv',
        'RIPPLE_PACKAGE_NAME',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['ui']);
    });

    test('announces package and command banners on stderr', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'core,ui',
        '--',
        'printenv',
        'RIPPLE_PACKAGE_NAME',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stderrLines(result), [
        '[ripple] ▶ packages/core',
        '[ripple] \$ printenv RIPPLE_PACKAGE_NAME',
        '[ripple] \$ printenv RIPPLE_PACKAGE_NAME  (exit 0)',
        '[ripple] ■ packages/core  (exit 0)',
        '[ripple] ▶ packages/ui',
        '[ripple] \$ printenv RIPPLE_PACKAGE_NAME',
        '[ripple] \$ printenv RIPPLE_PACKAGE_NAME  (exit 0)',
        '[ripple] ■ packages/ui  (exit 0)',
      ]);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test('forwards stdin to the package command', () async {
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '--packages=$packageConfig',
          rippleScript,
          'exec',
          '--packages',
          'ui',
          '--',
          'sh',
          '-c',
          'IFS= read -r line; printf %s "\$line"',
        ],
        workingDirectory: fixtureRoot,
        environment: Platform.environment,
        includeParentEnvironment: false,
      );
      process.stdin.writeln('from-stdin');
      await process.stdin.close();

      final stdoutText = await utf8.decodeStream(process.stdout);
      final stderrText = await utf8.decodeStream(process.stderr);
      final exitCode = await process.exitCode;

      expect(exitCode, 0, reason: stderrText);
      expect(stdoutText, 'from-stdin');
    });

    test('end banner reports non-zero package exit codes', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'core,ui',
        '--',
        'sh',
        '-c',
        'if [ "\$RIPPLE_PACKAGE_NAME" = core ]; then exit 3; fi',
      ]);

      expect(result.exitCode, 3);
      expect(stderrLines(result), [
        '[ripple] ▶ packages/core',
        '[ripple] \$ sh -c \'if [ "core" = core ]; then exit 3; fi\'',
        '[ripple] \$ sh -c \'if [ "core" = core ]; then exit 3; fi\'  (exit 3)',
        '[ripple] ■ packages/core  (exit 3)',
        '[ripple] ▶ packages/ui',
        '[ripple] \$ sh -c \'if [ "ui" = core ]; then exit 3; fi\'',
        '[ripple] \$ sh -c \'if [ "ui" = core ]; then exit 3; fi\'  (exit 0)',
        '[ripple] ■ packages/ui  (exit 0)',
      ]);
    });

    test('sets cwd to the package path', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'ui',
        '--',
        'pwd',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        stdoutLines(result),
        [p.normalize(p.join(fixtureRoot, 'packages', 'ui'))],
      );
    });

    test('injects RIPPLE_* environment variables', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'ui',
        '--',
        'sh',
        '-c',
        'printf "%s\\n%s\\n%s\\n" '
            '"\$RIPPLE_ROOT_PATH" '
            '"\$RIPPLE_PACKAGE_PATH" '
            '"\$RIPPLE_PACKAGE_NAME"',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        p.normalize(fixtureRoot),
        p.normalize(p.join(fixtureRoot, 'packages', 'ui')),
        'ui',
      ]);
    });

    test('substitutes RIPPLE_* placeholders in command args', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'ui',
        '--',
        'printf',
        '%s',
        r'$RIPPLE_PACKAGE_NAME',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'ui');
    });

    test('filters restrict which packages execute', () async {
      final result = await runRipple([
        'exec',
        '--dir-exists',
        'test',
        '--',
        'printenv',
        'RIPPLE_PACKAGE_NAME',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core']);
    });

    test('without --fail-fast continues after failures', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'core,ui',
        '--',
        'sh',
        '-c',
        'printf "%s\\n" "\$RIPPLE_PACKAGE_NAME"; '
            'if [ "\$RIPPLE_PACKAGE_NAME" = core ]; then exit 3; fi',
      ]);

      expect(result.exitCode, 3);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test('--fail-fast stops after the first failure', () async {
      final result = await runRipple([
        'exec',
        '--fail-fast',
        '--packages',
        'core,ui',
        '--',
        'sh',
        '-c',
        'printf "%s\\n" "\$RIPPLE_PACKAGE_NAME"; '
            'if [ "\$RIPPLE_PACKAGE_NAME" = core ]; then exit 3; fi',
      ]);

      expect(result.exitCode, 3);
      expect(stdoutLines(result), ['core']);
    });

    test('missing command after -- fails with usage guidance', () async {
      final result = await runRipple(['exec']);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('Missing command'));
      expect(result.stderr, contains('--'));
    });

    test('missing executable fails cleanly without a stack trace', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'ui',
        '--',
        'ripple-exec-missing-binary-that-does-not-exist',
      ]);

      expect(result.exitCode, 127);
      expect(result.stderr, contains('Failed to run'));
      expect(result.stderr,
          contains('ripple-exec-missing-binary-that-does-not-exist'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
      expect(result.stderr, isNot(contains('#0 ')));
    });

    test(
      '--fail-fast stops after a ProcessException on the first package',
      () async {
        final result = await runRipple([
          'exec',
          '--fail-fast',
          '--packages',
          'core,ui',
          '--',
          'ripple-exec-missing-binary-that-does-not-exist',
        ]);

        expect(result.exitCode, 127);
        final stderr = result.stderr as String;
        expect('Failed to run'.allMatches(stderr).length, 1);
      },
    );

    test('without --fail-fast continues after ProcessException', () async {
      final result = await runRipple([
        'exec',
        '--packages',
        'core,ui',
        '--',
        'ripple-exec-missing-binary-that-does-not-exist',
      ]);

      expect(result.exitCode, 127);
      final stderr = result.stderr as String;
      expect('Failed to run'.allMatches(stderr).length, 2);
    });

    test('--help documents filters and --fail-fast', () async {
      final result = await runRipple(
        ['exec', '--help'],
        workingDirectory: repoRoot,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final help = result.stdout as String;
      expect(help, contains('--fail-fast'));
      expect(help, contains('--group'));
      expect(help, contains('--packages'));
      expect(help, contains('--match'));
      expect(help, contains('--no-match'));
      expect(help, contains('--dir-exists'));
      expect(help, contains('--file-exists'));
      expect(help, contains('--depends-on'));
    });
  });
}
