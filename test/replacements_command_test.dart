import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final repoRoot = Directory.current.path;
  final packageConfig = p.join(repoRoot, '.dart_tool', 'package_config.json');
  final rippleScript = p.join(repoRoot, 'bin', 'ripple.dart');

  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('ripple_replacements_');
    Directory(p.join(workspace.path, 'packages', 'core'))
        .createSync(recursive: true);
    File(p.join(workspace.path, 'packages', 'core', 'pubspec.yaml'))
        .writeAsStringSync('name: core\n');
  });

  tearDown(() {
    if (workspace.existsSync()) {
      workspace.deleteSync(recursive: true);
    }
  });

  Future<ProcessResult> runRipple(
    List<String> args, {
    Map<String, String>? environment,
  }) {
    return Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=$packageConfig',
        rippleScript,
        ...args,
      ],
      workingDirectory: workspace.path,
      environment: {
        ...Platform.environment,
        ...?environment,
      }..removeWhere(
          (key, _) =>
              key == 'RIPPLE_OVERRIDE' &&
              (environment == null || !environment.containsKey(key)),
        ),
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

  group('replacements in run and exec', () {
    test('exec: script splices multi-word values and banners show argv',
        () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo REPLACED
packages:
  include:
    - packages/*
scripts:
  analyze:
    exec: "{{dart}} analyze ."
''');

      final result = await runRipple(['run', 'analyze']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['REPLACED analyze .']);
      expect(
        stderrLines(result),
        [
          '[ripple] ▶ core @ packages/core',
          '[ripple][core] \$ echo REPLACED analyze .',
          '[ripple][core] \$ echo REPLACED analyze .  (exit 0)',
          '[ripple] ■ core @ packages/core  (exit 0)',
        ],
      );
    });

    test('run: script expands replacements at the root', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo REPLACED
scripts:
  format:
    run: "{{dart}} format ."
''');

      final result = await runRipple(['run', 'format']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['REPLACED format .']);
      expect(
        stderrLines(result),
        [
          '[ripple] ▶ (root)',
          '[ripple][(root)] \$ echo REPLACED format .',
          '[ripple][(root)] \$ echo REPLACED format .  (exit 0)',
          '[ripple] ■ (root)  (exit 0)',
        ],
      );
    });

    test('ripple exec expands {{key}} from the command line', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo REPLACED
packages:
  include:
    - packages/*
''');

      final result = await runRipple([
        'exec',
        '--match',
        'core',
        '--',
        '{{dart}}',
        'analyze',
        '.',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['REPLACED analyze .']);
      expect(
        stderrLines(result),
        contains('[ripple][core] \$ echo REPLACED analyze .'),
      );
    });

    test('unknown placeholder fails clearly', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo REPLACED
packages:
  include:
    - packages/*
''');

      final result = await runRipple([
        'exec',
        '--',
        '{{darrt}}',
        'analyze',
        '.',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('Unknown replacement "darrt"'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('empty placeholder fails clearly', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
packages:
  include:
    - packages/*
''');

      final result = await runRipple(['exec', '--', '{{}}', 'analyze']);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('must contain a key'));
    });

    test('substitutes RIPPLE vars in replacement values', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync(r'''
replacements:
  dart: echo $RIPPLE_PACKAGE_NAME
packages:
  include:
    - packages/*
scripts:
  greet:
    exec: "{{dart}} extra"
''');

      final result = await runRipple(['run', 'greet']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['core extra']);
    });

    test('exec applies the first matching replacementOverrides entry',
        () async {
      Directory(p.join(workspace.path, 'packages', 'legacy'))
          .createSync(recursive: true);
      File(p.join(workspace.path, 'packages', 'legacy', 'pubspec.yaml'))
          .writeAsStringSync('name: legacy\n');
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
replacementOverrides:
  - filters:
      - match: [legacy]
    replacements:
      dart: echo OVERRIDE
  - filters:
      - match: [legacy]
    replacements:
      dart: echo SECOND
packages:
  include:
    - packages/*
''');

      final result = await runRipple(['exec', '--', '{{dart}}', 'ok']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['DEFAULT ok', 'OVERRIDE ok']);
    });

    test('exec: script applies per-package overrides', () async {
      Directory(p.join(workspace.path, 'packages', 'legacy'))
          .createSync(recursive: true);
      File(p.join(workspace.path, 'packages', 'legacy', 'pubspec.yaml'))
          .writeAsStringSync('name: legacy\n');
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
replacementOverrides:
  - filters:
      - match: [legacy]
    replacements:
      dart: echo OVERRIDE
packages:
  include:
    - packages/*
scripts:
  greet:
    exec: "{{dart}} ok"
''');

      final result = await runRipple(['run', 'greet']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['DEFAULT ok', 'OVERRIDE ok']);
    });

    test('--override=none skips ripple_overrides.yaml', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
packages:
  include:
    - packages/*
''');
      File(p.join(workspace.path, 'ripple_overrides.yaml'))
          .writeAsStringSync('''
replacements:
  dart: echo LOCAL
''');

      final result = await runRipple([
        'exec',
        '--override',
        'none',
        '--',
        '{{dart}}',
        'ok',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['DEFAULT ok']);
    });

    test('--override=file loads that overlay and beats env', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
packages:
  include:
    - packages/*
''');
      File(p.join(workspace.path, 'ripple.ci.yaml')).writeAsStringSync('''
replacements:
  dart: echo CI
''');
      File(p.join(workspace.path, 'ripple_overrides.yaml'))
          .writeAsStringSync('''
replacements:
  dart: echo LOCAL
''');

      final result = await runRipple(
        [
          'exec',
          '--override',
          'file:ripple.ci.yaml',
          '--',
          '{{dart}}',
          'ok',
        ],
        environment: {
          'RIPPLE_OVERRIDE': 'none',
        },
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['CI ok']);
    });

    test('RIPPLE_OVERRIDE=none skips the default overlay file', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
packages:
  include:
    - packages/*
''');
      File(p.join(workspace.path, 'ripple_overrides.yaml'))
          .writeAsStringSync('''
replacements:
  dart: echo LOCAL
''');

      final result = await runRipple(
        ['exec', '--', '{{dart}}', 'ok'],
        environment: {
          'RIPPLE_OVERRIDE': 'none',
        },
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['DEFAULT ok']);
    });

    test('bare --override path is rejected', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
packages:
  include:
    - packages/*
''');

      final result = await runRipple([
        'exec',
        '--override',
        'ripple.ci.yaml',
        '--',
        '{{dart}}',
        'ok',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('Invalid overlay descriptor'));
    });

    test('RIPPLE_OVERRIDE=file selects an overlay file', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
packages:
  include:
    - packages/*
''');
      File(p.join(workspace.path, 'ripple.ci.yaml')).writeAsStringSync('''
replacements:
  dart: echo CI
''');

      final result = await runRipple(
        ['exec', '--', '{{dart}}', 'ok'],
        environment: {
          'RIPPLE_OVERRIDE': 'file:ripple.ci.yaml',
        },
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['CI ok']);
    });

    test('--override=default beats RIPPLE_OVERRIDE=file', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
packages:
  include:
    - packages/*
''');
      File(p.join(workspace.path, 'ripple.ci.yaml')).writeAsStringSync('''
replacements:
  dart: echo CI
''');
      File(p.join(workspace.path, 'ripple_overrides.yaml'))
          .writeAsStringSync('''
replacements:
  dart: echo LOCAL
''');

      final result = await runRipple(
        [
          'exec',
          '--override',
          'default',
          '--',
          '{{dart}}',
          'ok',
        ],
        environment: {
          'RIPPLE_OVERRIDE': 'file:ripple.ci.yaml',
        },
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['LOCAL ok']);
    });

    test('file: overlay errors when the file is missing', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
packages:
  include:
    - packages/*
''');

      final result = await runRipple([
        'exec',
        '--override',
        'file:missing.yaml',
        '--',
        '{{dart}}',
        'ok',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('Overlay file not found'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('run --override=none uses ripple.yaml replacements', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
scripts:
  format:
    run: "{{dart}} ok"
''');
      File(p.join(workspace.path, 'ripple_overrides.yaml'))
          .writeAsStringSync('''
replacements:
  dart: echo LOCAL
''');

      final result = await runRipple(['run', '--override', 'none', 'format']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['DEFAULT ok']);
    });

    test('auto-loads ripple_overrides.yaml next to ripple.yaml', () async {
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
packages:
  include:
    - packages/*
''');
      File(p.join(workspace.path, 'ripple_overrides.yaml'))
          .writeAsStringSync('''
replacements:
  dart: echo LOCAL
''');

      final result = await runRipple(['exec', '--', '{{dart}}', 'ok']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['LOCAL ok']);
    });

    test('run: script ignores replacementOverrides', () async {
      Directory(p.join(workspace.path, 'packages', 'legacy'))
          .createSync(recursive: true);
      File(p.join(workspace.path, 'packages', 'legacy', 'pubspec.yaml'))
          .writeAsStringSync('name: legacy\n');
      File(p.join(workspace.path, 'ripple.yaml')).writeAsStringSync('''
replacements:
  dart: echo DEFAULT
replacementOverrides:
  - filters:
      - match: [legacy]
    replacements:
      dart: echo OVERRIDE
scripts:
  format:
    run: "{{dart}} ok"
''');

      final result = await runRipple(['run', 'format']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), ['DEFAULT ok']);
    });
  });
}
