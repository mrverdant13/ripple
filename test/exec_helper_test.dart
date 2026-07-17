import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/exec.dart';
import 'package:test/test.dart';

void main() {
  group('rippleEnvironment', () {
    test('always sets RIPPLE_ROOT_PATH', () {
      expect(
        rippleEnvironment(rootPath: '/repo'),
        {rippleRootPathEnvVar: '/repo'},
      );
    });

    test('adds package path and name when package is provided', () {
      const package = RipplePackage(
        name: 'ui',
        path: '/repo/packages/ui',
        relativePath: 'packages/ui',
      );

      expect(
        rippleEnvironment(rootPath: '/repo', package: package),
        {
          rippleRootPathEnvVar: '/repo',
          ripplePackagePathEnvVar: '/repo/packages/ui',
          ripplePackageNameEnvVar: 'ui',
        },
      );
    });
  });

  group('substituteRippleVars', () {
    const vars = {
      rippleRootPathEnvVar: '/repo',
      ripplePackagePathEnvVar: '/repo/packages/ui',
      ripplePackageNameEnvVar: 'ui',
    };

    test('substitutes \$VAR and \${VAR} forms', () {
      expect(
        substituteRippleVars(
          [
            'echo',
            r'$RIPPLE_PACKAGE_NAME',
            r'${RIPPLE_PACKAGE_PATH}',
            r'root=$RIPPLE_ROOT_PATH',
          ],
          vars: vars,
        ),
        [
          'echo',
          'ui',
          '/repo/packages/ui',
          'root=/repo',
        ],
      );
    });

    test('leaves unknown placeholders unchanged', () {
      expect(
        substituteRippleVars([r'$UNKNOWN', 'plain'], vars: vars),
        [r'$UNKNOWN', 'plain'],
      );
    });
  });

  group('runProcess', () {
    test('runs a command with cwd and returns exit code', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_exec_helper_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      final marker = File(p.join(temp.path, 'marker.txt'));
      final result = await runProcess(
        ['sh', '-c', 'printf ok > marker.txt'],
        workingDirectory: temp.path,
        inheritStdio: false,
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(marker.readAsStringSync(), 'ok');
    });

    test('merges RIPPLE_* into the child environment', () async {
      final result = await runProcess(
        ['printenv', ripplePackageNameEnvVar],
        workingDirectory: Directory.current.path,
        environment: const {ripplePackageNameEnvVar: 'ui'},
        inheritStdio: false,
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout.trim(), 'ui');
    });

    test('propagates non-zero exit codes', () async {
      final result = await runProcess(
        ['sh', '-c', 'exit 7'],
        workingDirectory: Directory.current.path,
        inheritStdio: false,
      );

      expect(result.exitCode, 7);
    });
  });
}
