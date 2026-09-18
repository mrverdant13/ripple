import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final repoRoot = Directory.current.path;
  final packageConfig = p.join(repoRoot, '.dart_tool', 'package_config.json');
  final rippleScript = p.join(repoRoot, 'bin', 'ripple.dart');

  Future<ProcessResult> runRipple(
    List<String> args, {
    required String workingDirectory,
  }) {
    return Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=$packageConfig',
        rippleScript,
        ...args,
      ],
      workingDirectory: workingDirectory,
      environment: Platform.environment,
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  Directory createTempDir(String prefix) {
    final temp = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    return temp;
  }

  void writeFile(String path, String contents) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  void markPubGetFresh(String packageDir) {
    final pubspec = File(p.join(packageDir, 'pubspec.yaml'));
    final packageConfig = File(
      p.join(packageDir, '.dart_tool', 'package_config.json'),
    );
    packageConfig
      ..createSync(recursive: true)
      ..writeAsStringSync('{"configVersion":2,"packages":[]}\n');
    if (pubspec.existsSync()) {
      packageConfig.setLastModifiedSync(
        pubspec.lastModifiedSync().add(const Duration(seconds: 2)),
      );
    }
  }

  group('ripple doctor', () {
    test('clean fixture exits 0 with OK summary', () async {
      final temp = createTempDir('ripple_doctor_cmd_clean_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'ui', 'pubspec.yaml'),
        'name: ui\nenvironment:\n  sdk: ^3.5.0\n',
      );
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
      markPubGetFresh(p.join(temp.path, 'packages', 'ui'));
      Directory(p.join(temp.path, '.git')).createSync();

      final result = await runRipple(['doctor'], workingDirectory: temp.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect((result.stdout as String).trim(), 'OK: 2 packages');
    });

    test('include.missed warns and exits 0', () async {
      final temp = createTempDir('ripple_doctor_cmd_missed_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'scratch', 'orphan', 'pubspec.yaml'),
        'name: orphan\nenvironment:\n  sdk: ^3.5.0\n',
      );
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
      Directory(p.join(temp.path, '.git')).createSync();

      final result = await runRipple(['doctor'], workingDirectory: temp.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
          result.stdout, contains('warning  include.missed  scratch/orphan'));
    });

    test('git.missing with changed filters exits 1', () async {
      final temp = createTempDir('ripple_doctor_cmd_git_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
scripts:
  affected:
    exec: dart analyze .
    filters:
      - changed: since:main
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));

      final result = await runRipple(['doctor'], workingDirectory: temp.path);

      expect(result.exitCode, 1);
      expect(result.stdout, contains('error  git.missing'));
    });

    test('--format json prints machine-readable findings', () async {
      final temp = createTempDir('ripple_doctor_cmd_json_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'scratch', 'orphan', 'pubspec.yaml'),
        'name: orphan\nenvironment:\n  sdk: ^3.5.0\n',
      );
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
      Directory(p.join(temp.path, '.git')).createSync();

      final result = await runRipple(
        ['doctor', '--format', 'json'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final decoded =
          jsonDecode((result.stdout as String).trim()) as Map<String, Object?>;
      expect(decoded['packageCount'], 1);
      final findings = decoded['findings'] as List<Object?>;
      expect(findings, isNotEmpty);
      final first = findings.first as Map<String, Object?>;
      expect(first['id'], 'include.missed');
      expect(first['path'], 'scratch/orphan');
    });

    test('does not create or edit files', () async {
      final temp = createTempDir('ripple_doctor_cmd_readonly_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
      Directory(p.join(temp.path, '.git')).createSync();

      final before = Directory(temp.path)
          .listSync(recursive: true)
          .map((e) => e.path)
          .toSet();

      final result = await runRipple(['doctor'], workingDirectory: temp.path);
      expect(result.exitCode, 0, reason: result.stderr as String);

      final after = Directory(temp.path)
          .listSync(recursive: true)
          .map((e) => e.path)
          .toSet();
      expect(after, before);
    });

    test('pub.get.stale warns and exits 0', () async {
      final temp = createTempDir('ripple_doctor_cmd_pubget_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final result = await runRipple(['doctor'], workingDirectory: temp.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        result.stdout,
        contains('warning  pub.get.stale  packages/core'),
      );
    });

    test('outside any ripple.yaml ancestry fails clearly', () async {
      final temp = createTempDir('ripple_doctor_cmd_none_');

      final result = await runRipple(['doctor'], workingDirectory: temp.path);

      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('No ripple.yaml found'));
    });

    test('unknown flags fail with usage guidance', () async {
      final temp = createTempDir('ripple_doctor_cmd_unknown_');
      writeFile(p.join(temp.path, 'ripple.yaml'), 'name: x\n');

      final result = await runRipple(
        ['doctor', '--unknown'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, 64);
      expect(result.stderr, contains('Could not find an option named'));
    });

    test('unexpected arguments fail with usage guidance', () async {
      final temp = createTempDir('ripple_doctor_cmd_args_');
      writeFile(p.join(temp.path, 'ripple.yaml'), 'name: x\n');

      final result = await runRipple(
        ['doctor', 'extra'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, 64);
      expect(
        result.stderr,
        contains('Command "doctor" does not take any arguments'),
      );
    });

    test('--help documents the command and --format', () async {
      final result = await runRipple(
        ['doctor', '--help'],
        workingDirectory: repoRoot,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final help = result.stdout as String;
      expect(help, contains('Report read-only workspace hygiene findings'));
      expect(help, contains('--format'));
      expect(help, contains('json'));
      expect(help, contains('--fatal-constraint-mismatch'));
    });

    test('constraint mismatches warn and exit 0 by default', () async {
      final temp = createTempDir('ripple_doctor_cmd_constraints_warn_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nversion: 2.0.0\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'api_client', 'pubspec.yaml'),
        'name: api_client\nversion: 1.0.0\nenvironment:\n  sdk: ^3.5.0\n'
        'dependencies:\n  core: ^1.0.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final result = await runRipple(['doctor'], workingDirectory: temp.path);

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        result.stdout,
        contains(
          'warning  constraint.mismatch  '
          'api_client depends on core ^1.0.0 but core is 2.0.0',
        ),
      );
    });

    test('--fatal-constraint-mismatch exits 1 on mismatches', () async {
      final temp = createTempDir('ripple_doctor_cmd_constraints_fatal_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nversion: 2.0.0\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'api_client', 'pubspec.yaml'),
        'name: api_client\nversion: 1.0.0\nenvironment:\n  sdk: ^3.5.0\n'
        'dependencies:\n  core: ^1.0.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final result = await runRipple(
        ['doctor', '--fatal-constraint-mismatch'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, 1);
      expect(
        result.stdout,
        contains(
          'warning  constraint.mismatch  '
          'api_client depends on core ^1.0.0 but core is 2.0.0',
        ),
      );
    });

    test('--format json encodes mismatch fields as warnings', () async {
      final temp = createTempDir('ripple_doctor_cmd_constraints_json_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nversion: 2.0.0\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'api_client', 'pubspec.yaml'),
        'name: api_client\nversion: 1.0.0\nenvironment:\n  sdk: ^3.5.0\n'
        'dependencies:\n  core: ^1.0.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final result = await runRipple(
        ['doctor', '--format', 'json'],
        workingDirectory: temp.path,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final decoded =
          jsonDecode((result.stdout as String).trim()) as Map<String, Object?>;
      final findings = decoded['findings'] as List<Object?>;
      final mismatch = findings.cast<Map<String, Object?>>().singleWhere(
            (f) => f['id'] == 'constraint.mismatch',
          );
      expect(mismatch['severity'], 'warning');
      expect(mismatch['from'], 'api_client');
      expect(mismatch['to'], 'core');
      expect(mismatch['constraint'], '^1.0.0');
      expect(mismatch['version'], '2.0.0');
    });

    test('doctor with mismatches does not create or edit files', () async {
      final temp = createTempDir('ripple_doctor_cmd_constraints_ro_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nversion: 2.0.0\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'api_client', 'pubspec.yaml'),
        'name: api_client\nversion: 1.0.0\nenvironment:\n  sdk: ^3.5.0\n'
        'dependencies:\n  core: ^1.0.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final before = Directory(temp.path)
          .listSync(recursive: true)
          .map((e) => e.path)
          .toSet();

      final result = await runRipple(
        ['doctor', '--fatal-constraint-mismatch'],
        workingDirectory: temp.path,
      );
      expect(result.exitCode, 1);

      final after = Directory(temp.path)
          .listSync(recursive: true)
          .map((e) => e.path)
          .toSet();
      expect(after, before);
    });
  });
}
