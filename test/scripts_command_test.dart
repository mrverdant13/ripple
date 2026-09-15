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

  group('ripple scripts', () {
    test('lists fixture scripts by id with kind, sorted', () async {
      final result = await runRipple(['scripts']);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'pkg.dependencies  exec',
        'pkg.dependents  exec',
        'pkg.dependents.constrained  exec',
        'pkg.dependents.env  exec',
        'pkg.env  exec',
        'pkg.fail  exec',
        'pkg.filtered  exec',
        'pkg.name  exec',
        'pkg.preset  exec',
        'pkg.steps  exec',
        'pkg.steps.fail  exec',
        'pkg.subst  exec',
        'pkg.subst.version  exec',
        'pkg.version  exec',
        'pkg.version.absent  exec',
        'root.env  run',
        'root.pwd  run',
        'root.steps  run',
        'root.steps.fail  run',
        'root.subst  run',
      ]);
    });

    test('prints this repo scripts by id with kind, sorted', () async {
      final result = await runRipple(
        ['scripts'],
        workingDirectory: repoRoot,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'analyze.ci  run',
        'coverage.check  run',
        'coverage.merge  run',
        'format.ci  run',
        'test  exec',
        'test.ci  exec',
      ]);
    });

    test('prints description next to id and kind', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_scripts_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('''
scripts:
  generate:
    exec: dart run build_runner build
  analyze:
    description: Analyze each package
    exec: dart analyze .
  format:
    description: Format the repo
    run: dart format .
''');

      final result = await runRipple(
        ['scripts'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), [
        'analyze  exec  Analyze each package',
        'format  run  Format the repo',
        'generate  exec',
      ]);
    });

    test('prints nothing when scripts is omitted', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_scripts_empty_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });
      File(p.join(temp.path, 'ripple.yaml')).writeAsStringSync('name: empty\n');

      final result = await runRipple(
        ['scripts'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(stdoutLines(result), isEmpty);
    });

    test('outside any ripple.yaml ancestry fails clearly', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_scripts_none_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      final result = await runRipple(
        ['scripts'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('No ripple.yaml found'));
    });

    test('unknown flags fail with usage guidance', () async {
      final result = await runRipple(['scripts', '--unknown']);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('Could not find an option named'));
    });

    test('unexpected arguments fail with usage guidance', () async {
      final result = await runRipple(['scripts', 'analyze']);

      expect(result.exitCode, 64);
      expect(
        result.stderr,
        contains('Command "scripts" does not take any arguments'),
      );
    });

    test('--help documents the command', () async {
      final result = await runRipple(
        ['scripts', '--help'],
        workingDirectory: repoRoot,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final help = result.stdout as String;
      expect(help, contains('List named scripts from ripple.yaml'));
    });
  });
}
