import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/exec.dart';
import 'package:test/test.dart';

void main() {
  final repoRoot = Directory.current.path;
  final packageConfig = p.join(repoRoot, '.dart_tool', 'package_config.json');
  final rippleScript = p.join(repoRoot, 'bin', 'ripple.dart');
  final probeScript = p.join(repoRoot, 'test', 'helpers', 'probe.dart');
  final fixtureRoot = Directory(
    p.join('test', 'fixtures', 'discovery_workspace'),
  ).absolute.path;

  List<String> probe(List<String> args) => [
        Platform.resolvedExecutable,
        probeScript,
        ...args,
      ];

  String commandStart(String scope, List<String> args) => formatCommandStart(
        probe(args),
        scopeLabel: scope,
        color: false,
      );

  String commandEnd(String scope, List<String> args, int exitCode) =>
      formatCommandEnd(
        probe(args),
        scopeLabel: scope,
        exitCode: exitCode,
        color: false,
      );

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
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
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
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['ui']);
    });

    test('announces package and command banners on stderr', () async {
      final result = await runRipple([
        'exec',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stderrLines(result), [
        '[ripple] ▶ core @ packages/core',
        commandStart('core', ['env', 'RIPPLE_PACKAGE_NAME']),
        commandEnd('core', ['env', 'RIPPLE_PACKAGE_NAME'], 0),
        '[ripple] ■ core @ packages/core  (exit 0)',
        '[ripple] ▶ ui @ packages/ui',
        commandStart('ui', ['env', 'RIPPLE_PACKAGE_NAME']),
        commandEnd('ui', ['env', 'RIPPLE_PACKAGE_NAME'], 0),
        '[ripple] ■ ui @ packages/ui  (exit 0)',
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
          '--match',
          'ui',
          '--',
          ...probe(['stdin']),
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
      const failIf = [
        'fail-if',
        'RIPPLE_PACKAGE_NAME=core',
        '--exit',
        '3',
      ];
      final result = await runRipple([
        'exec',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(failIf),
      ]);

      expect(result.exitCode, 3);
      expect(stderrLines(result), [
        '[ripple] ▶ core @ packages/core',
        commandStart('core', failIf),
        commandEnd('core', failIf, 3),
        '[ripple] ■ core @ packages/core  (exit 3)',
        '[ripple] ▶ ui @ packages/ui',
        commandStart('ui', failIf),
        commandEnd('ui', failIf, 0),
        '[ripple] ■ ui @ packages/ui  (exit 0)',
      ]);
    });

    test('sets cwd to the package path', () async {
      final result = await runRipple([
        'exec',
        '--match',
        'ui',
        '--',
        ...probe(['cwd']),
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
        '--match',
        'ui',
        '--',
        ...probe([
          'env',
          'RIPPLE_ROOT_PATH',
          'RIPPLE_PACKAGE_PATH',
          'RIPPLE_PACKAGE_NAME',
          'RIPPLE_PACKAGE_VERSION',
        ]),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        p.normalize(fixtureRoot),
        p.normalize(p.join(fixtureRoot, 'packages', 'ui')),
        'ui',
        '1.2.3',
      ]);
    });

    test('omits RIPPLE_PACKAGE_VERSION when the pubspec has no version',
        () async {
      final result = await runRipple(
        [
          'exec',
          '--match',
          'core',
          '--',
          ...probe(['env-absent', 'RIPPLE_PACKAGE_VERSION']),
        ],
        environment: const {ripplePackageVersionEnvVar: '9.9.9'},
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
    });

    test('substitutes RIPPLE_* placeholders in command args', () async {
      final result = await runRipple([
        'exec',
        '--match',
        'ui',
        '--',
        ...probe(['write', r'$RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, 'ui');
    });

    test('substitutes RIPPLE_PACKAGE_VERSION in command args', () async {
      final result = await runRipple([
        'exec',
        '--match',
        'ui',
        '--',
        ...probe(['write', r'$RIPPLE_PACKAGE_VERSION']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, '1.2.3');
    });

    test('filters restrict which packages execute', () async {
      final result = await runRipple([
        'exec',
        '--dir-exists',
        'test',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core']);
    });

    test('without --fail-fast continues after failures', () async {
      final result = await runRipple([
        'exec',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe([
          'fail-if',
          'RIPPLE_PACKAGE_NAME=core',
          '--exit',
          '3',
          '--print-env',
          'RIPPLE_PACKAGE_NAME',
        ]),
      ]);

      expect(result.exitCode, 3);
      expect(stdoutLines(result), ['core', 'ui']);
    });

    test('--fail-fast stops after the first failure', () async {
      final result = await runRipple([
        'exec',
        '--fail-fast',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe([
          'fail-if',
          'RIPPLE_PACKAGE_NAME=core',
          '--exit',
          '3',
          '--print-env',
          'RIPPLE_PACKAGE_NAME',
        ]),
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
        '--match',
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
          '--match',
          'core',
          '--match',
          'ui',
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
        '--match',
        'core',
        '--match',
        'ui',
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
      expect(help, contains('--quiet'));
      expect(help, contains('--concurrency'));
      expect(help, contains('--order'));
      expect(help, contains('--group'));
      expect(help, contains('--match'));
      expect(help, contains('--no-match'));
      expect(help, contains('--dir-exists'));
      expect(help, contains('--file-exists'));
      expect(help, contains('--depends-on'));
      expect(help, contains('--preset'));
      expect(help, contains('--override'));
    });

    test('--quiet suppresses banners and output when all packages succeed',
        () async {
      final result = await runRipple([
        'exec',
        '--quiet',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['echo', 'ok']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, isEmpty);
      expect(result.stderr, isEmpty);
    });

    test('--quiet prints banners and output only for failing packages',
        () async {
      const failIf = [
        'fail-if',
        'RIPPLE_PACKAGE_NAME=core',
        '--exit',
        '3',
        '--print-env',
        'RIPPLE_PACKAGE_NAME',
      ];
      final result = await runRipple([
        'exec',
        '--quiet',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(failIf),
      ]);

      expect(result.exitCode, 3);
      expect(stdoutLines(result), ['core']);
      expect(stderrLines(result), [
        '[ripple] ▶ core @ packages/core',
        commandStart('core', failIf),
        commandEnd('core', failIf, 3),
        '[ripple] ■ core @ packages/core  (exit 3)',
      ]);
      expect(result.stderr, isNot(contains('ui @ packages/ui')));
    });

    test('--quiet with --fail-fast does not start later packages', () async {
      final result = await runRipple([
        'exec',
        '--quiet',
        '--fail-fast',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe([
          'fail-if',
          'RIPPLE_PACKAGE_NAME=core',
          '--exit',
          '3',
          '--print-env',
          'RIPPLE_PACKAGE_NAME',
        ]),
      ]);

      expect(result.exitCode, 3);
      expect(stdoutLines(result), ['core']);
      expect(result.stdout, isNot(contains('ui')));
      expect(result.stderr, isNot(contains('ui @ packages/ui')));
    });

    test('omitted --concurrency keeps relativePath start order', () async {
      final result = await runRipple([
        'exec',
        '--match',
        'app',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['app', 'core', 'ui']);
    });

    test('--concurrency 1 keeps relativePath start order', () async {
      final result = await runRipple([
        'exec',
        '--concurrency',
        '1',
        '--match',
        'app',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['app', 'core', 'ui']);
    });

    test('--concurrency 2 overlaps package work', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_exec_overlap_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      final logFile = File(p.join(temp.path, 'started.log'));

      Future<int> runWithConcurrency(int concurrency) async {
        for (final name in ['core', 'ui']) {
          final stamp = File('${logFile.path}.$name');
          if (stamp.existsSync()) {
            stamp.deleteSync();
          }
        }
        final sw = Stopwatch()..start();
        final result = await runRipple([
          'exec',
          '--concurrency',
          '$concurrency',
          '--quiet',
          '--match',
          'core',
          '--match',
          'ui',
          '--',
          ...probe(['sleep-ms-append', logFile.path, '300']),
        ]);
        sw.stop();
        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(File('${logFile.path}.core').existsSync(), isTrue);
        expect(File('${logFile.path}.ui').existsSync(), isTrue);
        return sw.elapsedMilliseconds;
      }

      final sequentialMs = await runWithConcurrency(1);
      final parallelMs = await runWithConcurrency(2);
      // Parallel should save roughly one sleep interval after process overhead.
      expect(parallelMs, lessThan(sequentialMs - 150));
    });

    test('without --fail-fast every package still runs under concurrency',
        () async {
      final temp = Directory.systemTemp.createTempSync('ripple_exec_all_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      final logPrefix = p.join(temp.path, 'started');

      final result = await runRipple([
        'exec',
        '--concurrency',
        '2',
        '--quiet',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe([
          'stamp-and-fail-if',
          logPrefix,
          'RIPPLE_PACKAGE_NAME=core',
          '--exit',
          '3',
        ]),
      ]);

      expect(result.exitCode, 3);
      expect(File('$logPrefix.core').existsSync(), isTrue);
      expect(File('$logPrefix.ui').existsSync(), isTrue);
    });

    test('--fail-fast with concurrency does not start later packages',
        () async {
      final temp = Directory.systemTemp.createTempSync('ripple_exec_conc_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      final logPrefix = p.join(temp.path, 'started');

      final result = await runRipple([
        'exec',
        '--concurrency',
        '1',
        '--fail-fast',
        '--quiet',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe([
          'stamp-and-fail-if',
          logPrefix,
          'RIPPLE_PACKAGE_NAME=core',
          '--exit',
          '3',
        ]),
      ]);

      expect(result.exitCode, 3);
      expect(File('$logPrefix.core').existsSync(), isTrue);
      expect(File('$logPrefix.ui').existsSync(), isFalse);
    });

    test('--concurrency less than 1 is a usage error', () async {
      final result = await runRipple([
        'exec',
        '--concurrency',
        '0',
        '--',
        ...probe(['echo', 'ok']),
      ]);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('at least 1'));
    });

    test('omitted --order keeps relativePath start order', () async {
      final result = await runRipple([
        'exec',
        '--match',
        'app',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['app', 'core', 'ui']);
    });

    test('--order path keeps relativePath start order', () async {
      final result = await runRipple([
        'exec',
        '--order',
        'path',
        '--match',
        'app',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['app', 'core', 'ui']);
    });

    test('--order layers runs dependencies before dependents', () async {
      final result = await runRipple([
        'exec',
        '--order',
        'layers',
        '--concurrency',
        '1',
        '--match',
        'app',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core', 'ui', 'app']);
    });

    test('--order layers respects remaining edges in a filtered subset',
        () async {
      final result = await runRipple([
        'exec',
        '--order',
        'layers',
        '--concurrency',
        '1',
        '--match',
        'app',
        '--match',
        'ui',
        '--',
        ...probe(['env', 'RIPPLE_PACKAGE_NAME']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['ui', 'app']);
    });

    test('--order layers keeps layer barriers under concurrency', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_exec_layers_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      final logPrefix = p.join(temp.path, 'timed');

      final result = await runRipple([
        'exec',
        '--order',
        'layers',
        '--concurrency',
        '2',
        '--quiet',
        '--match',
        'app',
        '--match',
        'core',
        '--match',
        'ui',
        '--',
        ...probe(['timed-log', logPrefix, '200']),
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);

      ({int start, int end}) readStamp(String name) {
        final lines = File('$logPrefix.$name').readAsLinesSync();
        expect(lines, hasLength(2));
        return (
          start: int.parse(lines[0].split(' ').last),
          end: int.parse(lines[1].split(' ').last),
        );
      }

      final core = readStamp('core');
      final ui = readStamp('ui');
      final app = readStamp('app');
      expect(ui.start, greaterThanOrEqualTo(core.end));
      expect(app.start, greaterThanOrEqualTo(ui.end));
    });

    test('--order layers fails on a dependency cycle before running commands',
        () async {
      final temp = Directory.systemTemp.createTempSync('ripple_exec_cycle_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
name: cycle
packages:
  include:
    - packages/*
''');
      Directory(p.join(temp.path, 'packages', 'alpha')).createSync(
        recursive: true,
      );
      Directory(p.join(temp.path, 'packages', 'beta')).createSync(
        recursive: true,
      );
      File(p.join(temp.path, 'packages', 'alpha', 'pubspec.yaml'))
          .writeAsStringSync('''
name: alpha
dependencies:
  beta:
    path: ../beta
''');
      File(p.join(temp.path, 'packages', 'beta', 'pubspec.yaml'))
          .writeAsStringSync('''
name: beta
dependencies:
  alpha:
    path: ../alpha
''');
      final marker = File(p.join(temp.path, 'ran.txt'));

      final result = await runRipple(
        [
          'exec',
          '--order',
          'layers',
          '--',
          ...probe(['write-file', marker.path, 'ran']),
        ],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Dependency cycle detected'));
      expect(result.stderr, contains('alpha'));
      expect(result.stderr, contains('beta'));
      expect(marker.existsSync(), isFalse);
    });
  });
}
