import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/git_diff.dart';
import 'package:test/test.dart';

void main() {
  group('parseChangedDescriptor', () {
    test('accepts since, range, and workdir', () {
      expect(
        parseChangedDescriptor('since:origin/main'),
        isA<ChangedSince>().having((v) => v.ref, 'ref', 'origin/main'),
      );
      expect(
        parseChangedDescriptor('range:v1.0.0...v2.0.0'),
        isA<ChangedRange>().having((v) => v.range, 'range', 'v1.0.0...v2.0.0'),
      );
      expect(
        parseChangedDescriptor('workdir:HEAD'),
        isA<ChangedWorkdir>().having((v) => v.treeIsh, 'treeIsh', 'HEAD'),
      );
    });

    test('accepts bare since-tag, staged, unstaged, and untracked', () {
      expect(parseChangedDescriptor('since-tag'), isA<ChangedSinceTag>());
      expect(parseChangedDescriptor('staged'), isA<ChangedStaged>());
      expect(parseChangedDescriptor('unstaged'), isA<ChangedUnstaged>());
      expect(parseChangedDescriptor('untracked'), isA<ChangedUntracked>());
    });

    test('accepts bare kinds written with an empty payload', () {
      expect(parseChangedDescriptor('staged:'), isA<ChangedStaged>());
      expect(parseChangedDescriptor('since-tag:'), isA<ChangedSinceTag>());
    });

    test('rejects payloads on bare kinds', () {
      expect(
        () => parseChangedDescriptor('staged:HEAD'),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('does not take a value'),
          ),
        ),
      );
    });

    test('rejects since:HEAD and range:HEAD...HEAD', () {
      expect(
        () => parseChangedDescriptor('since:HEAD'),
        throwsA(isA<RippleConfigException>()),
      );
      expect(
        () => parseChangedDescriptor('range:HEAD...HEAD'),
        throwsA(isA<RippleConfigException>()),
      );
    });

    test('rejects bare keyword and single-ref range', () {
      expect(
        () => parseChangedDescriptor('dirty'),
        throwsA(isA<RippleConfigException>()),
      );
      expect(
        () => parseChangedDescriptor('range:origin/main'),
        throwsA(isA<RippleConfigException>()),
      );
    });
  });

  group('mapChangedPathsToPackages', () {
    test('uses longest-prefix ownership and deprioritizes root', () {
      final packages = [
        const RipplePackage(
          name: 'root_pkg',
          path: '/repo',
          relativePath: '.',
        ),
        const RipplePackage(
          name: 'ui',
          path: '/repo/packages/ui',
          relativePath: 'packages/ui',
        ),
      ];

      final owners = mapChangedPathsToPackages(
        paths: ['packages/ui/lib/button.dart'],
        packages: packages,
        rootPath: '/repo',
      );

      expect(owners, {'packages/ui'});
    });

    test('drops paths matching changedIgnore globs', () {
      final packages = [
        const RipplePackage(
          name: 'ui',
          path: '/repo/packages/ui',
          relativePath: 'packages/ui',
        ),
        const RipplePackage(
          name: 'core',
          path: '/repo/packages/core',
          relativePath: 'packages/core',
        ),
      ];

      final owners = mapChangedPathsToPackages(
        paths: [
          'packages/ui/README.md',
          'packages/core/lib/a.dart',
        ],
        packages: packages,
        rootPath: '/repo',
        ignoreGlobs: ['**/*.md'],
      );

      expect(owners, {'packages/core'});
    });
  });

  group('changedPackageRelativePaths', () {
    late Directory tempDir;
    late Directory coreDir;
    late Directory uiDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ripple_git_diff_');
      coreDir = Directory(p.join(tempDir.path, 'packages', 'core'));
      uiDir = Directory(p.join(tempDir.path, 'packages', 'ui'));
      await coreDir.create(recursive: true);
      await uiDir.create(recursive: true);
      await File(p.join(coreDir.path, 'pubspec.yaml')).writeAsString('''
name: core
environment:
  sdk: ^3.5.0
''');
      await File(p.join(uiDir.path, 'pubspec.yaml')).writeAsString('''
name: ui
environment:
  sdk: ^3.5.0
''');
      await File(p.join(coreDir.path, 'lib', 'a.dart')).create(recursive: true);
      await File(p.join(uiDir.path, 'lib', 'b.dart')).create(recursive: true);
      await File(p.join(tempDir.path, 'ripple.yaml')).writeAsString('''
name: temp
packages:
  include:
    - packages/*
''');

      await _git(tempDir.path, args: ['init']);
      await _git(tempDir.path, args: ['config', 'user.email', 'test@test.com']);
      await _git(tempDir.path, args: ['config', 'user.name', 'test']);
      // Default branch name varies by git version; pin to main for since: refs.
      await _git(tempDir.path, args: ['branch', '-M', 'main']);
      await _git(tempDir.path, args: ['add', '.']);
      await _git(tempDir.path, args: ['commit', '-m', 'initial']);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('workdir:HEAD sees uncommitted package changes', () async {
      await File(p.join(coreDir.path, 'lib', 'a.dart'))
          .writeAsString('// changed\n');

      final config = loadRippleConfig(start: tempDir);
      final packages = discoverPackages(config);
      final owners = changedPackageRelativePaths(
        rootPath: config.rootPath,
        descriptor: const ChangedWorkdir('HEAD'),
        packages: packages,
      );

      expect(owners, {'packages/core'});
    });

    test('since:HEAD~1 sees committed package changes', () async {
      await File(p.join(coreDir.path, 'lib', 'a.dart'))
          .writeAsString('// committed\n');
      await _git(
        tempDir.path,
        args: ['add', 'lib/a.dart'],
        workingDirectory: coreDir.path,
      );
      await _git(tempDir.path, args: ['commit', '-m', 'change core']);

      final config = loadRippleConfig(start: tempDir);
      final packages = discoverPackages(config);
      final owners = changedPackageRelativePaths(
        rootPath: config.rootPath,
        descriptor: const ChangedSince('HEAD~1'),
        packages: packages,
      );

      expect(owners, {'packages/core'});
    });

    test('since-tag matches since:<latest-tag> after tagged baseline', () async {
      await _git(tempDir.path, args: ['tag', 'v1.0.0']);
      await File(p.join(uiDir.path, 'lib', 'b.dart'))
          .writeAsString('// after tag\n');
      await _git(
        tempDir.path,
        args: ['add', 'lib/b.dart'],
        workingDirectory: uiDir.path,
      );
      await _git(tempDir.path, args: ['commit', '-m', 'change ui']);

      final config = loadRippleConfig(start: tempDir);
      final packages = discoverPackages(config);
      final sinceTag = changedPackageRelativePaths(
        rootPath: config.rootPath,
        descriptor: const ChangedSinceTag(),
        packages: packages,
      );
      final sinceNamed = changedPackageRelativePaths(
        rootPath: config.rootPath,
        descriptor: const ChangedSince('v1.0.0'),
        packages: packages,
      );

      expect(sinceTag, {'packages/ui'});
      expect(sinceTag, sinceNamed);
    });

    test('since-tag fails when no tags exist', () async {
      final config = loadRippleConfig(start: tempDir);
      final packages = discoverPackages(config);

      expect(
        () => changedPackageRelativePaths(
          rootPath: config.rootPath,
          descriptor: const ChangedSinceTag(),
          packages: packages,
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('no reachable git tag'),
          ),
        ),
      );
    });

    test('staged excludes unstaged and untracked paths', () async {
      await File(p.join(coreDir.path, 'lib', 'a.dart'))
          .writeAsString('// staged\n');
      await _git(
        tempDir.path,
        args: ['add', 'lib/a.dart'],
        workingDirectory: coreDir.path,
      );
      await File(p.join(uiDir.path, 'lib', 'b.dart'))
          .writeAsString('// unstaged\n');
      await File(p.join(uiDir.path, 'lib', 'new.dart'))
          .writeAsString('// untracked\n');

      final config = loadRippleConfig(start: tempDir);
      final packages = discoverPackages(config);

      expect(
        changedPackageRelativePaths(
          rootPath: config.rootPath,
          descriptor: const ChangedStaged(),
          packages: packages,
        ),
        {'packages/core'},
      );
      expect(
        changedPackageRelativePaths(
          rootPath: config.rootPath,
          descriptor: const ChangedUnstaged(),
          packages: packages,
        ),
        {'packages/ui'},
      );
      expect(
        changedPackageRelativePaths(
          rootPath: config.rootPath,
          descriptor: const ChangedUntracked(),
          packages: packages,
        ),
        {'packages/ui'},
      );
    });

    test('changedIgnore drops matching paths before ownership', () async {
      await File(p.join(coreDir.path, 'README.md'))
          .writeAsString('# core\n');
      await File(p.join(uiDir.path, 'lib', 'b.dart'))
          .writeAsString('// ui code\n');

      final config = loadRippleConfig(start: tempDir);
      final packages = discoverPackages(config);

      expect(
        changedPackageRelativePaths(
          rootPath: config.rootPath,
          descriptor: const ChangedWorkdir('HEAD'),
          packages: packages,
        ),
        {'packages/core', 'packages/ui'},
      );
      expect(
        changedPackageRelativePaths(
          rootPath: config.rootPath,
          descriptor: const ChangedWorkdir('HEAD'),
          packages: packages,
          ignoreGlobs: ['**/*.md'],
        ),
        {'packages/ui'},
      );
    });
  });
}

Future<void> _git(
  String root, {
  required List<String> args,
  String? workingDirectory,
}) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: workingDirectory ?? root,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    fail(
      'git ${args.join(' ')} failed: ${result.stdout} ${result.stderr}',
    );
  }
}
