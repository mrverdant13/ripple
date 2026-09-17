/// Git change detection and path-to-package mapping for `changed` filters.
library;

import 'dart:convert';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'discovery.dart';

/// Parsed `changed` descriptor.
sealed class ChangedDescriptor {
  const ChangedDescriptor();
}

/// Commit-tree diff `{ref}...HEAD`.
final class ChangedSince extends ChangedDescriptor {
  /// Creates a `since:` descriptor.
  const ChangedSince(this.ref);

  /// Git ref compared to `HEAD` with three-dot range syntax.
  final String ref;
}

/// Commit-tree diff with an explicit git range (`..` or `...`).
final class ChangedRange extends ChangedDescriptor {
  /// Creates a `range:` descriptor.
  const ChangedRange(this.range);

  /// Range passed to `git diff --name-only`.
  final String range;
}

/// Working tree diff against [treeIsh].
final class ChangedWorkdir extends ChangedDescriptor {
  /// Creates a `workdir:` descriptor.
  const ChangedWorkdir(this.treeIsh);

  /// Tree-ish compared to the working tree.
  final String treeIsh;
}

/// Diff from the latest reachable git tag to `HEAD`.
final class ChangedSinceLatestTag extends ChangedDescriptor {
  /// Creates a `since-latest-tag` descriptor.
  const ChangedSinceLatestTag();
}

/// Staged index changes vs `HEAD` only.
final class ChangedStaged extends ChangedDescriptor {
  /// Creates a `staged` descriptor.
  const ChangedStaged();
}

/// Tracked unstaged changes vs the index.
final class ChangedUnstaged extends ChangedDescriptor {
  /// Creates a `unstaged` descriptor.
  const ChangedUnstaged();
}

/// Untracked files (`git ls-files --others --exclude-standard`).
final class ChangedUntracked extends ChangedDescriptor {
  /// Creates a `untracked` descriptor.
  const ChangedUntracked();
}

final _rangeSeparator = RegExp(r'\.{2,3}');
final _gitRangePattern = RegExp(r'^.+\.{2,3}.+$');
final _posixMatchContext = p.Context(style: p.Style.posix);

/// Value-bearing descriptor kinds (`kind:value`).
const changedValueDescriptorKinds = ['since', 'range', 'workdir'];

/// Bare descriptor kinds (no payload after the kind name).
const changedBareDescriptorKinds = [
  'since-latest-tag',
  'staged',
  'unstaged',
  'untracked',
];

/// Known descriptor kinds for error messages.
const changedDescriptorKinds = [
  ...changedValueDescriptorKinds,
  ...changedBareDescriptorKinds,
];

/// Parses a single `changed` descriptor string.
///
/// Throws [RippleConfigException] when [value] is invalid.
ChangedDescriptor parseChangedDescriptor(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw const RippleConfigException(
      'Invalid changed descriptor: value must be a non-empty string',
    );
  }

  final colon = trimmed.indexOf(':');
  if (colon < 0) {
    return _parseBareChangedDescriptor(trimmed);
  }

  final kind = trimmed.substring(0, colon);
  final payload = trimmed.substring(colon + 1).trim();
  if (changedBareDescriptorKinds.contains(kind)) {
    if (payload.isNotEmpty) {
      throw RippleConfigException(
        'Invalid changed descriptor "$trimmed": $kind does not take a value. '
        'Use bare `$kind`.',
      );
    }
    return _parseBareChangedDescriptor(kind);
  }

  if (kind.isEmpty || payload.isEmpty) {
    throw RippleConfigException(
      'Invalid changed descriptor "$trimmed". Expected kind:value '
      '(since:<ref>, range:<A..B>, workdir:<tree-ish>) or a bare kind '
      '(${changedBareDescriptorKinds.join(', ')}). '
      'Known kinds: ${changedDescriptorKinds.join(', ')}',
    );
  }

  switch (kind) {
    case 'since':
      if (_isHeadRef(payload)) {
        throw RippleConfigException(
          'Invalid changed descriptor "$trimmed": since:HEAD compares commit '
          'trees only. Use workdir:HEAD for uncommitted working-tree changes.',
        );
      }
      return ChangedSince(payload);
    case 'range':
      if (!_gitRangePattern.hasMatch(payload)) {
        throw RippleConfigException(
          'Invalid changed descriptor "$trimmed": range: must be a git range '
          'with .. or ... (for example range:origin/main...HEAD). '
          'For a single ref compared to HEAD, use since:<ref>.',
        );
      }
      if (_isHeadOnlyRange(payload)) {
        throw RippleConfigException(
          'Invalid changed descriptor "$trimmed": range:HEAD...HEAD is empty. '
          'Use workdir:HEAD for uncommitted working-tree changes.',
        );
      }
      return ChangedRange(payload);
    case 'workdir':
      return ChangedWorkdir(payload);
    default:
      throw RippleConfigException(
        'Unknown changed descriptor kind "$kind" in "$trimmed". '
        'Known kinds: ${changedDescriptorKinds.join(', ')}',
      );
  }
}

ChangedDescriptor _parseBareChangedDescriptor(String kind) {
  switch (kind) {
    case 'since-latest-tag':
      return const ChangedSinceLatestTag();
    case 'staged':
      return const ChangedStaged();
    case 'unstaged':
      return const ChangedUnstaged();
    case 'untracked':
      return const ChangedUntracked();
    default:
      throw RippleConfigException(
        'Invalid changed descriptor "$kind". Expected kind:value '
        '(since:<ref>, range:<A..B>, workdir:<tree-ish>) or a bare kind '
        '(${changedBareDescriptorKinds.join(', ')}). '
        'Known kinds: ${changedDescriptorKinds.join(', ')}',
      );
  }
}

bool _isHeadRef(String ref) {
  final normalized = ref.trim().toUpperCase();
  return normalized == 'HEAD';
}

bool _isHeadOnlyRange(String range) {
  final parts = range.split(_rangeSeparator);
  if (parts.length != 2) {
    return false;
  }
  return _isHeadRef(parts[0]) && _isHeadRef(parts[1]);
}

/// Returns package [relativePath] values with path changes for [descriptor].
///
/// [rootPath] is the Ripple root (git working directory). [packages] is the
/// discovered package list used for longest-prefix ownership mapping.
/// [ignoreGlobs] drops matching repo-relative paths before ownership mapping
/// (`packages.changedIgnore`).
Set<String> changedPackageRelativePaths({
  required String rootPath,
  required ChangedDescriptor descriptor,
  required List<RipplePackage> packages,
  List<String> ignoreGlobs = const [],
}) {
  return changedPackageRelativePathsForDescriptors(
    rootPath: rootPath,
    descriptors: [descriptor],
    packages: packages,
    ignoreGlobs: ignoreGlobs,
  );
}

/// Like [changedPackageRelativePaths], but unions path sets from every
/// descriptor before longest-prefix ownership mapping.
Set<String> changedPackageRelativePathsForDescriptors({
  required String rootPath,
  required List<ChangedDescriptor> descriptors,
  required List<RipplePackage> packages,
  List<String> ignoreGlobs = const [],
}) {
  final paths = <String>{
    for (final descriptor in descriptors)
      ..._pathsForDescriptor(rootPath: rootPath, descriptor: descriptor),
  };
  return mapChangedPathsToPackages(
    paths: paths,
    packages: packages,
    rootPath: rootPath,
    ignoreGlobs: ignoreGlobs,
  );
}

Set<String> _pathsForDescriptor({
  required String rootPath,
  required ChangedDescriptor descriptor,
}) {
  return switch (descriptor) {
    ChangedSince(:final ref) => _pathsFromGitDiff(
        rootPath: rootPath,
        diffRange: '$ref...HEAD',
        revisionsToVerify: [ref, 'HEAD'],
      ),
    ChangedRange(:final range) => _pathsFromGitDiff(
        rootPath: rootPath,
        diffRange: range,
        revisionsToVerify: _revisionsFromRange(range),
      ),
    ChangedWorkdir(:final treeIsh) => _pathsFromWorkdir(
        rootPath: rootPath,
        treeIsh: treeIsh,
      ),
    ChangedSinceLatestTag() => _pathsFromSinceLatestTag(rootPath: rootPath),
    ChangedStaged() => _pathsFromStaged(rootPath: rootPath),
    ChangedUnstaged() => _pathsFromUnstaged(rootPath: rootPath),
    ChangedUntracked() => _pathsFromUntracked(rootPath: rootPath),
  };
}

/// Maps changed repo-relative file paths to owning package [relativePath]s.
///
/// Paths matching any [ignoreGlobs] pattern are dropped before ownership
/// mapping.
Set<String> mapChangedPathsToPackages({
  required Iterable<String> paths,
  required List<RipplePackage> packages,
  required String rootPath,
  List<String> ignoreGlobs = const [],
}) {
  if (packages.isEmpty) {
    return const {};
  }
  final normalizedRoot = p.normalize(rootPath);
  final ignoreMatchers = [
    for (final pattern in ignoreGlobs) _posixGlob(pattern),
  ];
  final sorted = packages.toList()
    ..sort((a, b) {
      if (a.relativePath == '.') {
        return 1;
      }
      if (b.relativePath == '.') {
        return -1;
      }
      return b.relativePath.length.compareTo(a.relativePath.length);
    });

  final owners = <String>{};
  for (final rawPath in paths) {
    final relative = _normalizeRepoRelativePath(rawPath, normalizedRoot);
    if (relative == null) {
      continue;
    }
    if (ignoreMatchers.any((glob) => glob.matches(relative))) {
      continue;
    }
    for (final package in sorted) {
      if (_pathOwnedByPackage(relative, package.relativePath)) {
        owners.add(package.relativePath);
        break;
      }
    }
  }
  return owners;
}

Glob _posixGlob(String pattern) => Glob(pattern, context: _posixMatchContext);

bool _pathOwnedByPackage(String relativePath, String packageRelativePath) {
  if (packageRelativePath == '.') {
    return true;
  }
  return relativePath == packageRelativePath ||
      relativePath.startsWith('$packageRelativePath/');
}

String? _normalizeRepoRelativePath(String path, String rootPath) {
  final normalized = p.normalize(path);
  if (p.isAbsolute(normalized)) {
    final rel = p.relative(normalized, from: rootPath);
    if (rel.startsWith('..')) {
      return null;
    }
    return _toPosixPath(rel);
  }
  return _toPosixPath(normalized);
}

String _toPosixPath(String path) => path.replaceAll(r'\', '/');

List<String> _revisionsFromRange(String range) {
  return range
      .split(_rangeSeparator)
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
}

Set<String> _pathsFromGitDiff({
  required String rootPath,
  required String diffRange,
  required List<String> revisionsToVerify,
}) {
  _ensureGitRepository(rootPath);
  for (final revision in revisionsToVerify) {
    _verifyRevision(rootPath, revision);
  }
  final result = _git(
    rootPath,
    ['--no-pager', 'diff', '--name-only', diffRange],
  );
  return _splitNameOnlyOutput(result.stdout as String);
}

Set<String> _pathsFromWorkdir({
  required String rootPath,
  required String treeIsh,
}) {
  _ensureGitRepository(rootPath);
  _verifyRevision(rootPath, treeIsh);
  final tracked = _git(
    rootPath,
    ['--no-pager', 'diff', '--name-only', treeIsh],
  );
  final untracked = _git(
    rootPath,
    ['--no-pager', 'ls-files', '--others', '--exclude-standard'],
  );
  return {
    ..._splitNameOnlyOutput(tracked.stdout as String),
    ..._splitNameOnlyOutput(untracked.stdout as String),
  };
}

Set<String> _pathsFromSinceLatestTag({required String rootPath}) {
  _ensureGitRepository(rootPath);
  _verifyRevision(rootPath, 'HEAD');
  final tag = _latestReachableTag(rootPath);
  final result = _git(
    rootPath,
    ['--no-pager', 'diff', '--name-only', '$tag...HEAD'],
  );
  return _splitNameOnlyOutput(result.stdout as String);
}

String _latestReachableTag(String rootPath) {
  final result = Process.runSync(
    'git',
    ['describe', '--tags', '--abbrev=0'],
    workingDirectory: rootPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw const RippleConfigException(
      'Cannot apply changed filter since-latest-tag: no reachable git tag from HEAD',
    );
  }
  final tag = (result.stdout as String).trim();
  if (tag.isEmpty) {
    throw const RippleConfigException(
      'Cannot apply changed filter since-latest-tag: no reachable git tag from HEAD',
    );
  }
  return tag;
}

Set<String> _pathsFromStaged({required String rootPath}) {
  _ensureGitRepository(rootPath);
  _verifyRevision(rootPath, 'HEAD');
  final result = _git(
    rootPath,
    ['--no-pager', 'diff', '--name-only', '--cached', 'HEAD'],
  );
  return _splitNameOnlyOutput(result.stdout as String);
}

Set<String> _pathsFromUnstaged({required String rootPath}) {
  _ensureGitRepository(rootPath);
  final result = _git(
    rootPath,
    ['--no-pager', 'diff', '--name-only'],
  );
  return _splitNameOnlyOutput(result.stdout as String);
}

Set<String> _pathsFromUntracked({required String rootPath}) {
  _ensureGitRepository(rootPath);
  final result = _git(
    rootPath,
    ['--no-pager', 'ls-files', '--others', '--exclude-standard'],
  );
  return _splitNameOnlyOutput(result.stdout as String);
}

Set<String> _splitNameOnlyOutput(String stdout) {
  return {
    for (final line in stdout.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  };
}

void _ensureGitRepository(String rootPath) {
  final gitDir = Directory(p.join(rootPath, '.git'));
  if (!gitDir.existsSync()) {
    throw RippleConfigException(
      'Cannot apply changed filter: "$rootPath" is not a git repository',
    );
  }
}

void _verifyRevision(String rootPath, String revision) {
  final result = Process.runSync(
    'git',
    ['rev-parse', '--verify', '--quiet', revision],
    workingDirectory: rootPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw RippleConfigException(
      'Cannot apply changed filter: unknown git revision "$revision"',
    );
  }
}

ProcessResult _git(String rootPath, List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: rootPath,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw RippleConfigException(
      'Git command failed: git ${arguments.join(' ')} '
      '(${result.stderr}${result.stdout})',
    );
  }
  return result;
}
