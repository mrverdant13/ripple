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

  /// Writes a package_config.json newer than the package pubspec so doctor
  /// does not emit `pub.get.stale` for fixtures that are otherwise clean.
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
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
      markPubGetFresh(p.join(temp.path, 'packages', 'api'));
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
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
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
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));

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
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));

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
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));

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
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
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
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
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
      markPubGetFresh(p.join(temp.path, 'packages', 'core'));
      markPubGetFresh(p.join(temp.path, 'packages', 'api'));
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(loadConfig(temp));

      final mix = report.findings.singleWhere(
        (f) => f.id == doctorFindingResolutionMix,
      );
      expect(mix.severity, DoctorSeverity.warning);
      expect(mix.message, contains('packages/core'));
      expect(mix.message, contains('packages/api'));
    });

    test('pub.get.stale warns when package_config is missing or older', () {
      final temp = createTempDir('ripple_doctor_pubget_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'fresh', 'pubspec.yaml'),
        'name: fresh\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'missing', 'pubspec.yaml'),
        'name: missing\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'stale', 'pubspec.yaml'),
        'name: stale\nenvironment:\n  sdk: ^3.5.0\n',
      );
      markPubGetFresh(p.join(temp.path, 'packages', 'fresh'));
      final staleConfig = File(
        p.join(
          temp.path,
          'packages',
          'stale',
          '.dart_tool',
          'package_config.json',
        ),
      );
      staleConfig
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}\n');
      final pubspec = File(
        p.join(temp.path, 'packages', 'stale', 'pubspec.yaml'),
      );
      staleConfig.setLastModifiedSync(
        pubspec.lastModifiedSync().subtract(const Duration(seconds: 5)),
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(loadConfig(temp));

      expect(report.hasErrors, isFalse);
      final stale = report.findings
          .where((f) => f.id == doctorFindingPubGetStale)
          .toList();
      expect(
        stale.map((f) => f.path).toList(),
        ['packages/missing', 'packages/stale'],
      );
      expect(stale.every((f) => f.severity == DoctorSeverity.warning), isTrue);
      expect(
        formatDoctorText(report),
        contains('warning  pub.get.stale  packages/missing'),
      );
    });

    test('formatDoctorJson encodes findings', () {
      const report = DoctorReport(
        packageCount: 1,
        findings: [
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

    test('constraint mismatches are absent when ranges allow versions', () {
      final temp = createTempDir('ripple_doctor_constraints_ok_');
      writeFile(p.join(temp.path, 'ripple.yaml'), '''
packages:
  include:
    - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nversion: 1.0.0\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'api_client', 'pubspec.yaml'),
        'name: api_client\nversion: 1.0.0\nenvironment:\n  sdk: ^3.5.0\n'
        'dependencies:\n  core: ^1.0.0\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(loadConfig(temp));

      expect(report.hasErrors, isFalse);
      expect(report.hasConstraintMismatches, isFalse);
      expect(
        report.findings.where((f) => f.id == doctorFindingConstraintMismatch),
        isEmpty,
      );
    });

    test('constraint mismatches are warnings when a range is too narrow', () {
      final temp = createTempDir('ripple_doctor_constraints_bad_');
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

      final report = runDoctor(loadConfig(temp));

      expect(report.hasErrors, isFalse);
      expect(report.hasConstraintMismatches, isTrue);
      final finding = report.findings.singleWhere(
        (f) => f.id == doctorFindingConstraintMismatch,
      );
      expect(finding.severity, DoctorSeverity.warning);
      expect(finding.from, 'api_client');
      expect(finding.to, 'core');
      expect(finding.constraint, '^1.0.0');
      expect(finding.version, '2.0.0');
      expect(
        finding.message,
        'api_client depends on core ^1.0.0 but core is 2.0.0',
      );
      expect(
        formatDoctorText(report),
        'warning  constraint.mismatch  '
        'api_client depends on core ^1.0.0 but core is 2.0.0',
      );
    });

    test('constraint checks skip path dependencies', () {
      final temp = createTempDir('ripple_doctor_constraints_path_');
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
        'dependencies:\n  core:\n    path: ../core\n',
      );
      Directory(p.join(temp.path, '.git')).createSync();

      final report = runDoctor(loadConfig(temp));

      expect(report.hasConstraintMismatches, isFalse);
      expect(
        report.findings.where((f) => f.id == doctorFindingConstraintMismatch),
        isEmpty,
      );
    });

    test('formatDoctorJson includes constraint fields', () {
      const report = DoctorReport(
        packageCount: 2,
        findings: [
          DoctorFinding(
            id: doctorFindingConstraintMismatch,
            severity: DoctorSeverity.warning,
            message: 'api_client depends on core ^1.0.0 but core is 2.0.0',
            from: 'api_client',
            to: 'core',
            constraint: '^1.0.0',
            version: '2.0.0',
          ),
        ],
      );

      final decoded =
          jsonDecode(formatDoctorJson(report)) as Map<String, Object?>;
      final findings = decoded['findings'] as List<Object?>;
      expect(
        findings.single,
        {
          'id': 'constraint.mismatch',
          'severity': 'warning',
          'message': 'api_client depends on core ^1.0.0 but core is 2.0.0',
          'from': 'api_client',
          'to': 'core',
          'constraint': '^1.0.0',
          'version': '2.0.0',
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
