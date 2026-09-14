/// Git change detection and path-to-package mapping for `changed` filters.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'discovery.dart';

/// Parsed `changed` descriptor (`since:`, `range:`, or `workdir:`).
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

final _rangeSeparator = RegExp(r'\.{2,3}');
final _gitRangePattern = RegExp(r'^.+\.{2,3}.+$');

/// Known descriptor kinds for error messages.
const changedDescriptorKinds = ['since', 'range', 'workdir'];

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
  if (colon <= 0 || colon == trimmed.length - 1) {
    throw RippleConfigException(
      'Invalid changed descriptor "$trimmed". Expected kind:value '
      '(since:<ref>, range:<A..B>, workdir:<tree-ish>). '
      'Known kinds: ${changedDescriptorKinds.join(', ')}',
    );
  }
  final kind = trimmed.substring(0, colon);
  final payload = trimmed.substring(colon + 1).trim();
  if (payload.isEmpty) {
    throw RippleConfigException(
      'Invalid changed descriptor "$trimmed": $kind: requires a non-empty value',
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
Set<String> changedPackageRelativePaths({
  required String rootPath,
  required ChangedDescriptor descriptor,
  required List<RipplePackage> packages,
}) {
  final paths = switch (descriptor) {
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
  };
  return mapChangedPathsToPackages(
    paths: paths,
    packages: packages,
    rootPath: rootPath,
  );
}

/// Maps changed repo-relative file paths to owning package [relativePath]s.
Set<String> mapChangedPathsToPackages({
  required Iterable<String> paths,
  required List<RipplePackage> packages,
  required String rootPath,
}) {
  if (packages.isEmpty) {
    return const {};
  }
  final normalizedRoot = p.normalize(rootPath);
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
    for (final package in sorted) {
      if (_pathOwnedByPackage(relative, package.relativePath)) {
        owners.add(package.relativePath);
        break;
      }
    }
  }
  return owners;
}

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
