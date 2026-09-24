import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/dart_workspace.dart';
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

  group('loadDartWorkspace', () {
    test('loads root and path members', () {
      final temp = createTempDir('ripple_ws_load_');
      writeFile(p.join(temp.path, 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/core
  - packages/api
''');
      writeFile(
        p.join(temp.path, 'packages', 'core', 'pubspec.yaml'),
        'name: core\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'api', 'pubspec.yaml'),
        'name: api\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );

      final workspace = loadDartWorkspace(temp.path);

      expect(workspace.rootPath, p.normalize(temp.path));
      expect(
        workspace.memberPaths,
        containsAll([
          p.normalize(temp.path),
          p.normalize(p.join(temp.path, 'packages', 'core')),
          p.normalize(p.join(temp.path, 'packages', 'api')),
        ]),
      );
    });

    test('expands nested workspace members', () {
      final temp = createTempDir('ripple_ws_nested_');
      writeFile(p.join(temp.path, 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/server
''');
      writeFile(p.join(temp.path, 'packages', 'server', 'pubspec.yaml'), '''
name: server
resolution: workspace
environment:
  sdk: ^3.6.0
workspace:
  - auth
  - api
''');
      writeFile(
        p.join(temp.path, 'packages', 'server', 'auth', 'pubspec.yaml'),
        'name: auth\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'server', 'api', 'pubspec.yaml'),
        'name: api\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );

      final workspace = loadDartWorkspace(temp.path);

      expect(
        workspace.memberPaths,
        containsAll([
          p.normalize(p.join(temp.path, 'packages', 'server')),
          p.normalize(p.join(temp.path, 'packages', 'server', 'auth')),
          p.normalize(p.join(temp.path, 'packages', 'server', 'api')),
        ]),
      );
    });

    test('expands glob workspace entries', () {
      final temp = createTempDir('ripple_ws_glob_');
      writeFile(p.join(temp.path, 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/*
''');
      writeFile(
        p.join(temp.path, 'packages', 'a', 'pubspec.yaml'),
        'name: a\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'b', 'pubspec.yaml'),
        'name: b\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );

      final workspace = loadDartWorkspace(temp.path);

      expect(workspace.memberPaths.length, 3);
      expect(
        workspace.contains(p.join(temp.path, 'packages', 'a')),
        isTrue,
      );
    });

    test('throws when workspace root has no workspace entries', () {
      final temp = createTempDir('ripple_ws_empty_');
      writeFile(
        p.join(temp.path, 'pubspec.yaml'),
        'name: alone\nenvironment:\n  sdk: ^3.6.0\n',
      );

      expect(
        () => loadDartWorkspace(temp.path),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('no workspace: entries'),
          ),
        ),
      );
    });

    test('throws on intermediate standalone between root and member', () {
      final temp = createTempDir('ripple_ws_intermediate_');
      writeFile(p.join(temp.path, 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/b3/child
''');
      writeFile(
        p.join(temp.path, 'packages', 'b3', 'pubspec.yaml'),
        'name: b3\nenvironment:\n  sdk: ^3.6.0\n',
      );
      writeFile(
        p.join(temp.path, 'packages', 'b3', 'child', 'pubspec.yaml'),
        'name: child\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );

      expect(
        () => loadDartWorkspace(temp.path),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('intermediate standalone'),
          ),
        ),
      );
    });

    test('throws when a workspace member escapes the declaring package', () {
      final temp = createTempDir('ripple_ws_escape_');
      final outside = createTempDir('ripple_ws_outside_');
      writeFile(
        p.join(outside.path, 'pubspec.yaml'),
        'name: outsider\nenvironment:\n  sdk: ^3.6.0\n',
      );
      writeFile(p.join(temp.path, 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - ${p.relative(outside.path, from: temp.path)}
''');

      expect(
        () => loadDartWorkspace(temp.path),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('outside the declaring package'),
          ),
        ),
      );
    });

    test('allows standalone descendant under a member', () {
      final temp = createTempDir('ripple_ws_descendant_');
      writeFile(p.join(temp.path, 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/ui
''');
      writeFile(
        p.join(temp.path, 'packages', 'ui', 'pubspec.yaml'),
        'name: ui\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );
      // Standalone under member — not on path root→member.
      writeFile(
        p.join(temp.path, 'packages', 'ui', 'example', 'pubspec.yaml'),
        'name: ui_example\nenvironment:\n  sdk: ^3.6.0\n',
      );

      final workspace = loadDartWorkspace(temp.path);
      expect(workspace.memberPaths.length, 2);
      expect(
        workspace.contains(p.join(temp.path, 'packages', 'ui', 'example')),
        isFalse,
      );
    });
  });

  group('detectDartWorkspaces and workspaceFor', () {
    test('detects workspace under ripple root and resolves innermost', () {
      final temp = createTempDir('ripple_ws_detect_');
      writeFile(
        p.join(temp.path, 'standalone', 'pubspec.yaml'),
        'name: alone\nenvironment:\n  sdk: ^3.5.0\n',
      );
      writeFile(p.join(temp.path, 'ws', 'pubspec.yaml'), '''
name: _
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - packages/core
''');
      writeFile(
        p.join(temp.path, 'ws', 'packages', 'core', 'pubspec.yaml'),
        'name: core\nresolution: workspace\nenvironment:\n  sdk: ^3.6.0\n',
      );

      final workspaces = detectDartWorkspaces(temp.path);
      expect(workspaces, hasLength(1));
      expect(
        workspaceFor(
          p.join(temp.path, 'ws', 'packages', 'core'),
          workspaces: workspaces,
        )?.rootPath,
        p.normalize(p.join(temp.path, 'ws')),
      );
      expect(
        workspaceFor(
          p.join(temp.path, 'standalone'),
          workspaces: workspaces,
        ),
        isNull,
      );
    });
  });

  group('resolutionRootFor', () {
    test('uses workspace_ref.json when present', () {
      final temp = createTempDir('ripple_ws_ref_');
      final root = p.join(temp.path, 'ws');
      final member = p.join(root, 'packages', 'core');
      writeFile(p.join(root, 'pubspec.yaml'), '''
name: _
workspace:
  - packages/core
''');
      writeFile(
        p.join(member, 'pubspec.yaml'),
        'name: core\nresolution: workspace\n',
      );
      // workspace_ref.json is relative to the ref file directory.
      writeFile(
        p.join(member, '.dart_tool', 'pub', 'workspace_ref.json'),
        // Relative to `.dart_tool/pub/` → workspace root.
        '{"workspaceRoot": "../../../.."}\n',
      );

      expect(
        resolutionRootFor(member, workspaces: const []),
        p.normalize(root),
      );
    });
  });
}
