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
  });

  group('changedPackageRelativePaths', () {
    late Directory tempDir;
    late Directory pkgDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ripple_git_diff_');
      pkgDir = Directory(p.join(tempDir.path, 'packages', 'core'));
      await pkgDir.create(recursive: true);
      await File(p.join(pkgDir.path, 'pubspec.yaml')).writeAsString('''
name: core
environment:
  sdk: ^3.5.0
''');
      await File(p.join(pkgDir.path, 'lib', 'a.dart')).create(recursive: true);
      await File(p.join(tempDir.path, 'ripple.yaml')).writeAsString('''
name: temp
packages:
  include:
    - packages/*
''');

      await _git(tempDir.path, args: ['init']);
      await _git(tempDir.path, args: ['config', 'user.email', 'test@test.com']);
      await _git(tempDir.path, args: ['config', 'user.name', 'test']);
      await _git(tempDir.path, args: ['add', '.']);
      await _git(tempDir.path, args: ['commit', '-m', 'initial']);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('workdir:HEAD sees uncommitted package changes', () async {
      await File(p.join(pkgDir.path, 'lib', 'a.dart'))
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
      await File(p.join(pkgDir.path, 'lib', 'a.dart'))
          .writeAsString('// committed\n');
      await _git(
        tempDir.path,
        args: ['add', 'lib/a.dart'],
        workingDirectory: pkgDir.path,
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
