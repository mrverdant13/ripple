/// Dart pub workspace detection, membership, and layout validation.
library;

import 'dart:convert';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';

/// A Dart pub workspace rooted at [rootPath].
///
/// [memberPaths] includes the workspace root and every transitive member from
/// nested `workspace:` declarations (absolute, normalized paths).
class DartWorkspace {
  /// Creates a workspace description.
  const DartWorkspace({
    required this.rootPath,
    required this.memberPaths,
  });

  /// Absolute path of the directory containing the root `pubspec.yaml`.
  final String rootPath;

  /// Absolute paths of the root and all transitive workspace members.
  final Set<String> memberPaths;

  /// Whether [packagePath] is the root or a member of this workspace.
  bool contains(String packagePath) =>
      memberPaths.contains(p.normalize(packagePath));
}

/// Loads a Dart workspace rooted at [workspaceRootPath].
///
/// [workspaceRootPath] must contain a `pubspec.yaml` with a non-empty
/// `workspace:` list. Throws [RippleConfigException] when the root is missing,
/// has no `workspace:` entry, or the layout has an intermediate standalone
/// pubspec on the path from the root to a member.
DartWorkspace loadDartWorkspace(String workspaceRootPath) {
  final root = p.normalize(workspaceRootPath);
  final pubspecFile = File(p.join(root, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) {
    throw RippleConfigException(
      'Dart workspace root has no pubspec.yaml: $root',
    );
  }

  final workspaceEntries = _readWorkspaceEntries(pubspecFile);
  if (workspaceEntries == null || workspaceEntries.isEmpty) {
    throw RippleConfigException(
      'Dart workspace root has no workspace: entries: $root',
    );
  }

  final members = <String>{root};
  _collectMembers(
    workspaceRoot: root,
    packageDir: root,
    entries: workspaceEntries,
    members: members,
  );

  final intermediate = findIntermediateStandalones(
    workspaceRootPath: root,
    memberPaths: members,
  );
  if (intermediate.isNotEmpty) {
    final listed = intermediate.map(_displayPath).join(', ');
    throw RippleConfigException(
      'Dart workspace at $root has intermediate standalone pubspec(s) on the '
      'path to a workspace member: $listed',
    );
  }

  return DartWorkspace(
    rootPath: root,
    memberPaths: Set<String>.unmodifiable(members),
  );
}

/// Walks [rippleRootPath] for `pubspec.yaml` files with a `workspace:` key and
/// loads each as a [DartWorkspace].
///
/// Throws [RippleConfigException] when any detected workspace fails layout
/// validation (intermediate standalones). Nested workspace roots that are
/// themselves members of a parent are still loaded independently when they
/// declare `workspace:`.
List<DartWorkspace> detectDartWorkspaces(String rippleRootPath) {
  final root = p.normalize(rippleRootPath);
  final workspaces = <DartWorkspace>[];
  final seenRoots = <String>{};

  for (final pubspecPath in _findPubspecFiles(root)) {
    final packageDir = p.dirname(pubspecPath);
    final entries = _readWorkspaceEntries(File(pubspecPath));
    if (entries == null || entries.isEmpty) {
      continue;
    }
    if (!seenRoots.add(packageDir)) {
      continue;
    }
    workspaces.add(loadDartWorkspace(packageDir));
  }

  workspaces.sort((a, b) => a.rootPath.compareTo(b.rootPath));
  return List<DartWorkspace>.unmodifiable(workspaces);
}

/// Returns the [DartWorkspace] that contains [packagePath], if any.
///
/// When multiple workspaces contain the path (nested), returns the **innermost**
/// (longest root path).
DartWorkspace? workspaceFor(
  String packagePath, {
  required List<DartWorkspace> workspaces,
}) {
  final normalized = p.normalize(packagePath);
  DartWorkspace? best;
  for (final workspace in workspaces) {
    if (!workspace.contains(normalized)) {
      continue;
    }
    if (best == null ||
        workspace.rootPath.length > best.rootPath.length ||
        (workspace.rootPath.length == best.rootPath.length &&
            workspace.rootPath.compareTo(best.rootPath) < 0)) {
      best = workspace;
    }
  }
  return best;
}

/// Absolute paths of directories that contain a `pubspec.yaml` strictly between
/// [workspaceRootPath] and a member in [memberPaths], and that are **not**
/// themselves members.
List<String> findIntermediateStandalones({
  required String workspaceRootPath,
  required Set<String> memberPaths,
}) {
  final root = p.normalize(workspaceRootPath);
  final members = {
    for (final member in memberPaths) p.normalize(member),
  };
  final intermediates = <String>{};

  for (final member in members) {
    if (member == root) {
      continue;
    }
    if (!_isWithinOrEqual(root, member)) {
      continue;
    }

    var current = p.dirname(member);
    while (current != root && _isWithinOrEqual(root, current)) {
      final pubspec = File(p.join(current, 'pubspec.yaml'));
      if (pubspec.existsSync() && !members.contains(current)) {
        intermediates.add(current);
      }
      final parent = p.dirname(current);
      if (parent == current) {
        break;
      }
      current = parent;
    }
  }

  final sorted = intermediates.toList()..sort();
  return sorted;
}

/// Resolves the absolute directory that owns shared resolution metadata for
/// [packagePath] (workspace root when [packagePath] is a member, else the
/// package directory itself).
///
/// Prefers `.dart_tool/pub/workspace_ref.json` when present; otherwise uses
/// [workspaces] membership.
String resolutionRootFor(
  String packagePath, {
  List<DartWorkspace> workspaces = const [],
}) {
  final normalized = p.normalize(packagePath);
  final fromRef = _workspaceRootFromRef(normalized);
  if (fromRef != null) {
    return fromRef;
  }
  final workspace = workspaceFor(normalized, workspaces: workspaces);
  return workspace?.rootPath ?? normalized;
}

void _collectMembers({
  required String workspaceRoot,
  required String packageDir,
  required List<String> entries,
  required Set<String> members,
}) {
  final listContext = p.Context(style: p.style, current: packageDir);

  for (final entry in entries) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) {
      continue;
    }

    final memberDirs = <String>[];
    if (_looksLikeGlob(trimmed)) {
      final glob = Glob(trimmed, context: listContext);
      for (final entity
          in glob.listSync(root: packageDir, followLinks: false)) {
        if (entity is Directory) {
          memberDirs.add(p.normalize(entity.path));
        }
      }
    } else {
      memberDirs.add(p.normalize(p.join(packageDir, trimmed)));
    }

    for (final memberDir in memberDirs) {
      final pubspecFile = File(p.join(memberDir, 'pubspec.yaml'));
      if (!pubspecFile.existsSync()) {
        throw RippleConfigException(
          'Dart workspace member has no pubspec.yaml: $memberDir '
          '(from workspace at $workspaceRoot)',
        );
      }
      if (!members.add(memberDir)) {
        continue;
      }

      final nested = _readWorkspaceEntries(pubspecFile);
      if (nested != null && nested.isNotEmpty) {
        _collectMembers(
          workspaceRoot: workspaceRoot,
          packageDir: memberDir,
          entries: nested,
          members: members,
        );
      }
    }
  }
}

List<String>? _readWorkspaceEntries(File pubspecFile) {
  late final String contents;
  try {
    contents = pubspecFile.readAsStringSync();
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
  final value = document['workspace'];
  if (value == null) {
    return null;
  }
  if (value is! List) {
    throw RippleConfigException(
      'Invalid workspace: in ${pubspecFile.path}: expected a list',
    );
  }
  final entries = <String>[];
  for (final item in value) {
    if (item is! String) {
      throw RippleConfigException(
        'Invalid workspace: in ${pubspecFile.path}: entries must be strings',
      );
    }
    entries.add(item);
  }
  return entries;
}

bool _looksLikeGlob(String pattern) {
  return pattern.contains('*') ||
      pattern.contains('?') ||
      pattern.contains('[') ||
      pattern.contains('{');
}

bool _isWithinOrEqual(String ancestor, String path) {
  final a = p.normalize(ancestor);
  final b = p.normalize(path);
  if (a == b) {
    return true;
  }
  final relative = p.relative(b, from: a);
  return relative != '.' &&
      !relative.startsWith('..') &&
      !p.isAbsolute(relative);
}

String? _workspaceRootFromRef(String packagePath) {
  final refFile = File(
    p.join(packagePath, '.dart_tool', 'pub', 'workspace_ref.json'),
  );
  if (!refFile.existsSync()) {
    return null;
  }
  late final String contents;
  try {
    contents = refFile.readAsStringSync();
  } on FileSystemException {
    return null;
  }
  late final Object? decoded;
  try {
    decoded = jsonDecode(contents);
  } on Object {
    return null;
  }
  if (decoded is! Map) {
    return null;
  }
  final relativeRoot = decoded['workspaceRoot'];
  if (relativeRoot is! String || relativeRoot.isEmpty) {
    return null;
  }
  // workspaceRoot is relative to the workspace_ref.json file itself.
  final resolved = p.normalize(p.join(p.dirname(refFile.path), relativeRoot));
  if (!File(p.join(resolved, 'pubspec.yaml')).existsSync()) {
    return null;
  }
  return resolved;
}

List<String> _findPubspecFiles(String rootPath) {
  final results = <String>[];

  void visit(Directory dir) {
    List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
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
      if (entity is File && name == 'pubspec.yaml') {
        results.add(p.normalize(entity.path));
      }
    }
  }

  visit(Directory(rootPath));
  results.sort();
  return results;
}

String _displayPath(String absolutePath) => absolutePath;
