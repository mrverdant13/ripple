/// Read-only workspace hygiene checks for `ripple doctor`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'discovery.dart';
import 'scripts.dart';

/// Finding id: a `pubspec.yaml` on disk is outside include/exclude selection.
const doctorFindingIncludeMissed = 'include.missed';

/// Finding id: Ripple root is not a git checkout.
const doctorFindingGitMissing = 'git.missing';

/// Finding id: a `{{dart}}` / `{{flutter}}` replacement token is not on `PATH`.
const doctorFindingReplacementMissing = 'replacement.missing';

/// Finding id: some selected packages use `resolution: workspace`, others do not.
const doctorFindingResolutionMix = 'resolution.mix';

/// Severity of a [DoctorFinding].
enum DoctorSeverity {
  /// Non-fatal; `ripple doctor` still exits 0.
  warning,

  /// Fatal for the doctor run; `ripple doctor` exits 1.
  error,
}

/// One hygiene finding from [runDoctor].
class DoctorFinding {
  /// Creates a finding.
  const DoctorFinding({
    required this.id,
    required this.severity,
    required this.message,
    this.path,
  });

  /// Stable id (`include.missed`, `git.missing`, …).
  final String id;

  /// Warning or error.
  final DoctorSeverity severity;

  /// Human-readable description.
  final String message;

  /// Optional repo-relative path (posix) related to the finding.
  final String? path;

  /// JSON object for `--format json`.
  Map<String, Object?> toJson() => {
        'id': id,
        'severity': severity.name,
        'message': message,
        if (path != null) 'path': path,
      };
}

/// Aggregated result of [runDoctor].
class DoctorReport {
  /// Creates a report for [packageCount] selected packages.
  const DoctorReport({
    required this.packageCount,
    required this.findings,
  });

  /// Number of packages selected by include/exclude.
  final int packageCount;

  /// Findings in stable check order (then by path when applicable).
  final List<DoctorFinding> findings;

  /// Whether any finding has [DoctorSeverity.error].
  bool get hasErrors =>
      findings.any((finding) => finding.severity == DoctorSeverity.error);
}

/// Runs v1 doctor checks against [config]. Does not create or edit files.
///
/// [environment] defaults to [Platform.environment] (used for `PATH` /
/// `PATHEXT`). [executableExists] overrides PATH lookup for tests.
DoctorReport runDoctor(
  RippleConfig config, {
  Map<String, String>? environment,
  bool Function(String executable)? executableExists,
}) {
  final packages = discoverPackages(config);
  final findings = <DoctorFinding>[
    ..._includeMissedFindings(config, packages),
    if (_gitMissingFinding(config) case final gitFinding?) gitFinding,
    ..._replacementMissingFindings(
      config,
      environment: environment ?? Platform.environment,
      executableExists: executableExists,
    ),
    if (_resolutionMixFinding(packages) case final finding?) finding,
  ];

  return DoctorReport(
    packageCount: packages.length,
    findings: List<DoctorFinding>.unmodifiable(findings),
  );
}

/// Human text for [report] (`OK: N packages` when clean).
String formatDoctorText(DoctorReport report) {
  if (report.findings.isEmpty) {
    return 'OK: ${report.packageCount} packages';
  }

  final buffer = StringBuffer();
  for (final finding in report.findings) {
    buffer.write(finding.severity.name);
    buffer.write('  ');
    buffer.write(finding.id);
    if (finding.path != null) {
      buffer.write('  ');
      buffer.write(finding.path);
    } else {
      buffer.write('  ');
      buffer.write(finding.message);
    }
    buffer.writeln();
  }
  return buffer.toString().trimRight();
}

/// JSON object string for [report].
String formatDoctorJson(DoctorReport report) {
  return jsonEncode({
    'packageCount': report.packageCount,
    'findings': [
      for (final finding in report.findings) finding.toJson(),
    ],
  });
}

/// Whether [rootPath] looks like a git working tree (`.git` file or directory).
bool isGitCheckout(String rootPath) {
  final gitPath = p.join(rootPath, '.git');
  final type = FileSystemEntity.typeSync(gitPath, followLinks: false);
  return type == FileSystemEntityType.directory ||
      type == FileSystemEntityType.file;
}

/// Whether [executable] resolves on `PATH` given [environment].
bool isExecutableOnPath(
  String executable, {
  required Map<String, String> environment,
}) {
  if (executable.isEmpty) {
    return false;
  }

  final pathSep = Platform.isWindows ? ';' : ':';
  final pathEnv = environment['PATH'] ?? environment['Path'] ?? '';
  final extensions =
      Platform.isWindows ? _windowsPathExts(environment) : const <String>[''];

  bool existsWithExts(String base) {
    for (final ext in extensions) {
      final candidate = File('$base$ext');
      if (candidate.existsSync()) {
        return true;
      }
    }
    return false;
  }

  if (p.isAbsolute(executable) ||
      executable.contains(r'\') ||
      executable.contains('/')) {
    return existsWithExts(executable);
  }

  for (final dir in pathEnv.split(pathSep)) {
    if (dir.isEmpty) {
      continue;
    }
    if (existsWithExts(p.join(dir, executable))) {
      return true;
    }
  }
  return false;
}

List<String> _windowsPathExts(Map<String, String> environment) {
  final raw = environment['PATHEXT'] ?? '.EXE;.CMD;.BAT;.COM';
  final exts = <String>{''};
  for (final part in raw.split(';')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    exts.add(trimmed.startsWith('.') ? trimmed : '.$trimmed');
  }
  return exts.toList(growable: false);
}

List<DoctorFinding> _includeMissedFindings(
  RippleConfig config,
  List<RipplePackage> selected,
) {
  final selectedPaths = {
    for (final package in selected) package.relativePath,
  };
  final onDisk = _findPubspecRelativePaths(config.rootPath);
  final missed = [
    for (final relative in onDisk)
      if (!selectedPaths.contains(relative)) relative,
  ]..sort();

  return [
    for (final relative in missed)
      DoctorFinding(
        id: doctorFindingIncludeMissed,
        severity: DoctorSeverity.warning,
        message: 'pubspec.yaml not selected by packages.include/exclude',
        path: relative,
      ),
  ];
}

DoctorFinding? _gitMissingFinding(RippleConfig config) {
  if (isGitCheckout(config.rootPath)) {
    return null;
  }

  final usesChanged = configUsesChangedFilters(config);
  return DoctorFinding(
    id: doctorFindingGitMissing,
    severity: usesChanged ? DoctorSeverity.error : DoctorSeverity.warning,
    message: 'no git checkout at Ripple root',
  );
}

/// Exposed for tests: whether [config] declares any `changed` filter.
bool configUsesChangedFilters(RippleConfig config) {
  final presets = config.packages.filtersPresets;
  for (final script in config.scripts.values) {
    if (_expressionUsesChanged(script.filters, presets: presets)) {
      return true;
    }
    if (_expressionUsesChanged(
      script.dependentsFilters?.expression,
      presets: presets,
    )) {
      return true;
    }
    if (_expressionUsesChanged(
      script.dependenciesFilters?.expression,
      presets: presets,
    )) {
      return true;
    }
  }
  for (final preset in presets.values) {
    if (_expressionUsesChanged(preset, presets: presets)) {
      return true;
    }
  }
  for (final override in config.replacementOverrides) {
    if (_expressionUsesChanged(override.filters, presets: presets)) {
      return true;
    }
  }
  return false;
}

bool _expressionUsesChanged(
  FilterExpr? expression, {
  required Map<String, FilterExpr> presets,
  Set<String>? visiting,
}) {
  if (expression == null) {
    return false;
  }
  switch (expression) {
    case FilterAnd(:final children) || FilterOr(:final children):
      return children.any(
        (child) => _expressionUsesChanged(
          child,
          presets: presets,
          visiting: visiting,
        ),
      );
    case FilterChanged():
      return true;
    case FilterPreset(:final name):
      final stack = visiting ?? <String>{};
      if (!stack.add(name)) {
        return false;
      }
      return _expressionUsesChanged(
        presets[name],
        presets: presets,
        visiting: stack,
      );
    case FilterDirExists() ||
          FilterFileExists() ||
          FilterNoDirExists() ||
          FilterNoFileExists() ||
          FilterDependsOn() ||
          FilterGroup() ||
          FilterMatch() ||
          FilterNoMatch() ||
          FilterSdk():
      return false;
  }
}

List<DoctorFinding> _replacementMissingFindings(
  RippleConfig config, {
  required Map<String, String> environment,
  bool Function(String executable)? executableExists,
}) {
  final findings = <DoctorFinding>[];
  for (final key in const ['dart', 'flutter']) {
    final raw = config.replacements[key];
    if (raw == null) {
      continue;
    }
    late final List<String> tokens;
    try {
      tokens = parseScriptCommand(raw);
    } on RippleConfigException {
      findings.add(
        DoctorFinding(
          id: doctorFindingReplacementMissing,
          severity: DoctorSeverity.warning,
          message: '{{$key}} replacement is not a valid command string',
        ),
      );
      continue;
    }
    if (tokens.isEmpty) {
      continue;
    }
    final first = tokens.first;
    final exists = executableExists != null
        ? executableExists(first)
        : isExecutableOnPath(first, environment: environment);
    if (!exists) {
      findings.add(
        DoctorFinding(
          id: doctorFindingReplacementMissing,
          severity: DoctorSeverity.warning,
          message: '{{$key}} first token "$first" not found on PATH',
        ),
      );
    }
  }
  return findings;
}

DoctorFinding? _resolutionMixFinding(List<RipplePackage> packages) {
  if (packages.isEmpty) {
    return null;
  }

  final withWorkspace = <String>[];
  final withoutWorkspace = <String>[];
  for (final package in packages) {
    // Read `resolution:` from YAML directly. `Pubspec.resolution` exists only
    // in newer pubspec_parse versions (SDK ^3.6+), which cannot resolve on the
    // package min SDK (3.5).
    if (_pubspecResolution(package) == 'workspace') {
      withWorkspace.add(package.relativePath);
    } else {
      withoutWorkspace.add(package.relativePath);
    }
  }

  if (withWorkspace.isEmpty || withoutWorkspace.isEmpty) {
    return null;
  }

  return DoctorFinding(
    id: doctorFindingResolutionMix,
    severity: DoctorSeverity.warning,
    message: 'mixed resolution: workspace (${withWorkspace.join(', ')}) vs '
        'other (${withoutWorkspace.join(', ')})',
  );
}

/// Top-level `resolution:` value from [package]'s `pubspec.yaml`, if present.
String? _pubspecResolution(RipplePackage package) {
  final file = File(p.join(package.path, 'pubspec.yaml'));
  late final String contents;
  try {
    contents = file.readAsStringSync();
  } on FileSystemException {
    return null;
  }

  late final Object? document;
  try {
    document = loadYaml(contents);
  } on Object {
    return null;
  }
  if (document is! YamlMap) {
    return null;
  }
  final value = document['resolution'];
  return value is String ? value : null;
}

/// Repo-relative posix paths of directories that contain `pubspec.yaml`.
List<String> _findPubspecRelativePaths(String rootPath) {
  final root = p.normalize(rootPath);
  final results = <String>[];

  void visit(Directory dir) {
    final entities = dir.listSync(followLinks: false);
    for (final entity in entities) {
      final name = p.basename(entity.path);
      if (name == '.git' || name == '.dart_tool') {
        continue;
      }
      if (entity is Directory) {
        if (name.startsWith('.')) {
          continue;
        }
        visit(entity);
        continue;
      }
      if (entity is! File || name != 'pubspec.yaml') {
        continue;
      }
      final packageDir = p.dirname(entity.path);
      results.add(_posixRelative(root, packageDir));
    }
  }

  visit(Directory(root));
  results.sort();
  return results;
}

String _posixRelative(String rootPath, String absolutePath) {
  final relative = p.relative(absolutePath, from: rootPath);
  if (relative == '.') {
    return '.';
  }
  return p.posix.joinAll(p.split(relative));
}
