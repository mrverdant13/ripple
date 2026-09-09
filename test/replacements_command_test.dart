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
