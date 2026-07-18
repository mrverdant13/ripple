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

  group('TerminalLineState', () {
    test('observeBytes treats trailing LF or CR as line start', () {
      final state = TerminalLineState();

      state.observeBytes('core-'.codeUnits);
      expect(state.atLineStart, isFalse);

      state.observeBytes('\n'.codeUnits);
      expect(state.atLineStart, isTrue);

      state.observeBytes('x'.codeUnits);
      expect(state.atLineStart, isFalse);
      state.observeBytes('\r'.codeUnits);
      expect(state.atLineStart, isTrue);
    });

    test('ensureLineStart inserts a newline only when mid-line', () {
      final state = TerminalLineState();
      final sink = StringBuffer();

      state.ensureLineStart(sink);
      expect(sink.toString(), isEmpty);

      state.atLineStart = false;
      state.ensureLineStart(sink);
      expect(sink.toString(), '\n');
      expect(state.atLineStart, isTrue);
    });
  });

  group('package scope banners', () {
    const package = RipplePackage(
      name: 'ui',
      path: '/repo/packages/ui',
      relativePath: 'packages/ui',
    );

    tearDown(() {
      terminalLineState.atLineStart = true;
    });

    test('formatPackageScopeStart / End use plain text without color', () {
      expect(
        formatPackageScopeStart('packages/ui', color: false),
        '[ripple] ▶ packages/ui',
      );
      expect(
        formatPackageScopeEnd('packages/ui', exitCode: 0, color: false),
        '[ripple] ■ packages/ui  (exit 0)',
      );
      expect(
        formatPackageScopeEnd('packages/ui', exitCode: 3, color: false),
        '[ripple] ■ packages/ui  (exit 3)',
      );
    });

    test('formatPackageScopeStart / End wrap ANSI when color is on', () {
      expect(
        formatPackageScopeStart('packages/ui', color: true),
        contains('[ripple] ▶ packages/ui'),
      );
      expect(formatPackageScopeStart('packages/ui', color: true),
          startsWith('\x1B['));
      expect(
        formatPackageScopeEnd('packages/ui', exitCode: 0, color: true),
        contains('(exit 0)'),
      );
      expect(
        formatPackageScopeEnd('packages/ui', exitCode: 3, color: true),
        contains('(exit 3)'),
      );
    });

    test('packageScopeBannersUseColor respects NO_COLOR and TERM=dumb', () {
      expect(
        packageScopeBannersUseColor(
          hasTerminal: true,
          environment: const {'NO_COLOR': '1'},
        ),
        isFalse,
      );
      expect(
        packageScopeBannersUseColor(
          hasTerminal: true,
          environment: const {'TERM': 'dumb'},
        ),
        isFalse,
      );
      expect(
        packageScopeBannersUseColor(
          hasTerminal: true,
          environment: const {},
        ),
        isTrue,
      );
      expect(
        packageScopeBannersUseColor(
          hasTerminal: false,
          environment: const {},
        ),
        isFalse,
      );
      expect(
        packageScopeBannersUseColor(environment: const {}),
        isFalse,
      );
      expect(
        packageScopeBannersUseColor(forceColor: true, hasTerminal: false),
        isTrue,
      );
    });

    test('announcePackageScopeStart / End write to the sink', () {
      final sink = StringBuffer();

      announcePackageScopeStart(
        package,
        sink: sink,
        forceColor: false,
      );
      announcePackageScopeEnd(
        package,
        exitCode: 0,
        sink: sink,
        forceColor: false,
      );

      expect(
        sink.toString(),
        '[ripple] ▶ packages/ui\n'
        '[ripple] ■ packages/ui  (exit 0)\n',
      );
    });

    test('resolveBannerHasTerminal defaults non-Stdout sinks to false', () {
      expect(resolveBannerHasTerminal(StringBuffer()), isFalse);
      expect(
        resolveBannerHasTerminal(StringBuffer(), hasTerminal: true),
        isTrue,
      );
      expect(resolveBannerHasTerminal(stderr), stderr.hasTerminal);
      expect(
        resolveBannerHasTerminal(stderr, hasTerminal: false),
        isFalse,
      );
    });

    test('custom sinks stay plain unless forceColor is set', () {
      final plain = StringBuffer();
      announcePackageScopeStart(package, sink: plain);
      announcePackageScopeEnd(package, exitCode: 3, sink: plain);
      expect(plain.toString(), isNot(contains('\x1B[')));
      expect(
        plain.toString(),
        '[ripple] ▶ packages/ui\n'
        '[ripple] ■ packages/ui  (exit 3)\n',
      );

      final colored = StringBuffer();
      announcePackageScopeStart(
        package,
        sink: colored,
        forceColor: true,
      );
      announcePackageScopeEnd(
        package,
        exitCode: 3,
        sink: colored,
        forceColor: true,
      );
      expect(colored.toString(), contains('\x1B['));
      expect(colored.toString(), contains('[ripple] ▶ packages/ui'));
      expect(colored.toString(), contains('(exit 3)'));
    });

    test('shouldEnsureBannerLineStart is only for shared TTYs by default', () {
      final sink = StringBuffer();
      expect(
        shouldEnsureBannerLineStart(
          sink,
          stdoutIsTerminal: true,
          stderrIsTerminal: true,
        ),
        isFalse,
      );
      expect(
        shouldEnsureBannerLineStart(
          stderr,
          stdoutIsTerminal: true,
          stderrIsTerminal: true,
        ),
        isTrue,
      );
      expect(
        shouldEnsureBannerLineStart(
          stderr,
          stdoutIsTerminal: false,
          stderrIsTerminal: true,
        ),
        isFalse,
      );
      expect(
        shouldEnsureBannerLineStart(sink, forceEnsureLineStart: true),
        isTrue,
      );
    });

    test('announce inserts a newline when mid-line and ensure is on', () {
      terminalLineState.atLineStart = false;
      final sink = StringBuffer();

      announcePackageScopeStart(
        package,
        sink: sink,
        forceColor: false,
        forceEnsureLineStart: true,
      );

      expect(
        sink.toString(),
        '\n[ripple] ▶ packages/ui\n',
      );
      expect(terminalLineState.atLineStart, isTrue);
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

    test('does not treat \$VAR as a prefix of a longer token', () {
      expect(
        substituteRippleVars(
          [
            r'$RIPPLE_ROOT_PATH_SUFFIX',
            r'pre_$RIPPLE_ROOT_PATH_x',
            r'$RIPPLE_ROOT_PATH',
            r'${RIPPLE_ROOT_PATH}_ok',
          ],
          vars: vars,
        ),
        [
          r'$RIPPLE_ROOT_PATH_SUFFIX',
          r'pre_$RIPPLE_ROOT_PATH_x',
          '/repo',
          '/repo_ok',
        ],
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

    test('can omit parent environment variables', () async {
      final path = Platform.environment['PATH'];
      expect(path, isNotNull);

      final result = await runProcess(
        [
          'sh',
          '-c',
          'if printenv RIPPLE_PACKAGE_NAME >/dev/null 2>&1; then exit 11; fi; '
              'printenv RIPPLE_ROOT_PATH',
        ],
        workingDirectory: Directory.current.path,
        environment: {
          'PATH': path!,
          rippleRootPathEnvVar: '/repo',
          // Present in this map would be visible; omitting it proves parent
          // values are not inherited when includeParentEnvironment is false.
        },
        inheritStdio: false,
        includeParentEnvironment: false,
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout.trim(), '/repo');
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
