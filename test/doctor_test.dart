import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/doctor.dart';
import 'package:test/test.dart';

void main() {
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

  RippleConfig loadConfig(Directory root) {
    return loadRippleConfig(start: root);
  }

  group('runDoctor', () {
    test('clean workspace with selected packages reports OK shape', () {
      final temp = createTempDir('ripple_doctor_clean_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
name: shop
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nversion: 1.0.0\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'api', 'pubspec.yaml'),
        'name: api\nversion: 1.0.0\nenvironment:\n  sdk: ^3.5.0\n',
      );
      // Mimic a git checkout so git.missing is not emitted.
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(loadConfig(temp));

      expect(report.packageCount, 2);
      expect(report.findings, isEmpty);
      expect(report.hasErrors, isFalse);
      expect(formatDoctorText(report), 'OK: 2 packages');
    });

    test('include.missed warns for pubspecs outside include', () {
      final temp = createTempDir('ripple_doctor_missed_');
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
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(loadConfig(temp));

      expect(report.packageCount, 1);
      expect(report.hasErrors, isFalse);
      expect(report.findings, hasLength(1));
      expect(report.findings.single.id, doctorFindingIncludeMissed);
      expect(report.findings.single.severity, DoctorSeverity.warning);
      expect(report.findings.single.path, 'scratch/orphan');
      expect(
        formatDoctorText(report),
        'warning  include.missed  scratch/orphan',
      );
    });

    test('git.missing is a warning when changed filters are unused', () {
      final temp = createTempDir('ripple_doctor_nogit_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );

      final report = runDoctor(loadConfig(temp));

      expect(report.hasErrors, isFalse);
      final git = report.findings.singleWhere(
        (f) => f.id == doctorFindingGitMissing,
      );
      expect(git.severity, DoctorSeverity.warning);
      expect(git.message, contains('no git checkout'));
    });

    test('git.missing is an error when scripts use changed filters', () {
      final temp = createTempDir('ripple_doctor_nogit_changed_');
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

      final report = runDoctor(loadConfig(temp));

      expect(report.hasErrors, isTrue);
      final git = report.findings.singleWhere(
        (f) => f.id == doctorFindingGitMissing,
      );
      expect(git.severity, DoctorSeverity.error);
    });

    test('git.missing error when changed is only in a filtersPreset', () {
      final temp = createTempDir('ripple_doctor_preset_changed_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
  filtersPresets:
    affected:
      - changed: workdir:HEAD
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );

      expect(configUsesChangedFilters(loadConfig(temp)), isTrue);
      final report = runDoctor(loadConfig(temp));
      expect(
        report.findings
            .singleWhere((f) => f.id == doctorFindingGitMissing)
            .severity,
        DoctorSeverity.error,
      );
    });

    test('replacement.missing warns when dart token is absent from PATH', () {
      final temp = createTempDir('ripple_doctor_repl_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
replacements:
  dart: definitely-not-on-path-xyz
  flutter: also-missing-flutter-bin
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(
        loadConfig(temp),
        executableExists: (_) => false,
      );

      final missing = report.findings
          .where((f) => f.id == doctorFindingReplacementMissing)
          .toList();
      expect(missing, hasLength(2));
      expect(missing[0].message, contains('{{dart}}'));
      expect(missing[1].message, contains('{{flutter}}'));
    });

    test('replacement.missing is skipped when tokens resolve on PATH', () {
      final temp = createTempDir('ripple_doctor_repl_ok_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
replacements:
  dart: dart
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nenvironment:\n  sdk: ^3.5.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(
        loadConfig(temp),
        executableExists: (exe) => exe == 'dart',
      );

      expect(
        report.findings.where((f) => f.id == doctorFindingReplacementMissing),
        isEmpty,
      );
    });

    test('resolution.mix warns when workspace resolution is mixed', () {
      final temp = createTempDir('ripple_doctor_resolution_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nversion: 1.0.0\n'
        'environment:\n  sdk: ^3.5.0\n'
        'resolution: workspace\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'api', 'pubspec.yaml'),
        'name: api\nversion: 1.0.0\n'
        'environment:\n  sdk: ^3.5.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(loadConfig(temp));

      final mix = report.findings.singleWhere(
        (f) => f.id == doctorFindingResolutionMix,
      );
      expect(mix.severity, DoctorSeverity.warning);
      expect(mix.message, contains('packages/core'));
      expect(mix.message, contains('packages/api'));
    });

    test('formatDoctorJson encodes findings', () {
      final report = DoctorReport(
        packageCount: 1,
        findings: const [
          DoctorFinding(
            id: doctorFindingIncludeMissed,
            severity: DoctorSeverity.warning,
            message: 'missed',
            path: 'scratch/orphan',
          ),
        ],
      );

      final decoded =
          jsonDecode(formatDoctorJson(report)) as Map<String, Object?>;
      expect(decoded['packageCount'], 1);
      final findings = decoded['findings'] as List<Object?>;
      expect(findings, hasLength(1));
      expect(
        findings.single,
        {
          'id': 'include.missed',
          'severity': 'warning',
          'message': 'missed',
          'path': 'scratch/orphan',
        },
      );
    });
  });

  group('isGitCheckout', () {
    test('accepts .git directory and file', () {
      final temp = createTempDir('ripple_doctor_git_');
      expect(isGitCheckout(temp.path), isFalse);

      Directory(p.join(temp.path, '.git')).createSync();
      expect(isGitCheckout(temp.path), isTrue);
      Directory(p.join(temp.path, '.git')).deleteSync(recursive: true);

      File(p.join(temp.path, '.git'))
          .writeAsStringSync('gitdir: /tmp/elsewhere');
      expect(isGitCheckout(temp.path), isTrue);
    });
  });
}
