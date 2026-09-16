import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
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

    test('adds RIPPLE_PACKAGE_VERSION when the pubspec declares a version', () {
      final package = RipplePackage(
        name: 'ui',
        path: '/repo/packages/ui',
        relativePath: 'packages/ui',
        pubspec: Pubspec.parse('name: ui\nversion: 1.2.3\n'),
      );

      expect(
        rippleEnvironment(rootPath: '/repo', package: package),
        {
          rippleRootPathEnvVar: '/repo',
          ripplePackagePathEnvVar: '/repo/packages/ui',
          ripplePackageNameEnvVar: 'ui',
          ripplePackageVersionEnvVar: '1.2.3',
        },
      );
    });

    test('omits RIPPLE_PACKAGE_VERSION when the pubspec has no version', () {
      final package = RipplePackage(
        name: 'ui',
        path: '/repo/packages/ui',
        relativePath: 'packages/ui',
        pubspec: Pubspec.parse('name: ui\n'),
      );

      expect(
        rippleEnvironment(rootPath: '/repo', package: package).containsKey(
          ripplePackageVersionEnvVar,
        ),
        isFalse,
      );
    });
  });

  group('rippleChildEnvironment', () {
    test('strips parent RIPPLE_PACKAGE_VERSION when vars omit it', () {
      expect(
        rippleChildEnvironment(
          const {
            rippleRootPathEnvVar: '/repo',
            ripplePackagePathEnvVar: '/pkg',
            ripplePackageNameEnvVar: 'core',
          },
          parent: const {
            'PATH': '/bin',
            ripplePackageVersionEnvVar: '9.9.9',
            ripplePackageNameEnvVar: 'leaked',
          },
        ),
        {
          'PATH': '/bin',
          rippleRootPathEnvVar: '/repo',
          ripplePackagePathEnvVar: '/pkg',
          ripplePackageNameEnvVar: 'core',
        },
      );
    });

    test('keeps RIPPLE_PACKAGE_VERSION from vars over parent', () {
      expect(
        rippleChildEnvironment(
          const {
            rippleRootPathEnvVar: '/repo',
            ripplePackageVersionEnvVar: '1.2.3',
          },
          parent: const {ripplePackageVersionEnvVar: '9.9.9'},
        )[ripplePackageVersionEnvVar],
        '1.2.3',
      );
    });

    test('strips all parent RIPPLE_PACKAGE_* when vars are root-only', () {
      expect(
        rippleChildEnvironment(
          const {rippleRootPathEnvVar: '/repo'},
          parent: const {
            'HOME': '/home',
            ripplePackagePathEnvVar: '/leaked',
            ripplePackageNameEnvVar: 'leaked',
            ripplePackageVersionEnvVar: '9.9.9',
          },
        ),
        {
          'HOME': '/home',
          rippleRootPathEnvVar: '/repo',
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

    test('formatPackageScopeLabel joins name and relative path', () {
      expect(formatPackageScopeLabel(package), 'ui @ packages/ui');
    });

    test('formatPackageScopeStart / End use plain text without color', () {
      expect(
        formatPackageScopeStart('ui @ packages/ui', color: false),
        '[ripple] ▶ ui @ packages/ui',
      );
      expect(
        formatPackageScopeEnd('ui @ packages/ui', exitCode: 0, color: false),
        '[ripple] ■ ui @ packages/ui  (exit 0)',
      );
      expect(
        formatPackageScopeEnd('ui @ packages/ui', exitCode: 3, color: false),
        '[ripple] ■ ui @ packages/ui  (exit 3)',
      );
      expect(
        formatPackageScopeStart(rootScopeLabel, color: false),
        '[ripple] ▶ (root)',
      );
      expect(
        formatPackageScopeEnd(rootScopeLabel, exitCode: 0, color: false),
        '[ripple] ■ (root)  (exit 0)',
      );
    });

    test('formatPackageScopeStart / End wrap ANSI when color is on', () {
      expect(
        formatPackageScopeStart('ui @ packages/ui', color: true),
        contains('[ripple] ▶ ui @ packages/ui'),
      );
      expect(
        formatPackageScopeStart('ui @ packages/ui', color: true),
        startsWith('\x1B['),
      );
      expect(
        formatPackageScopeEnd('ui @ packages/ui', exitCode: 0, color: true),
        contains('(exit 0)'),
      );
      expect(
        formatPackageScopeEnd('ui @ packages/ui', exitCode: 3, color: true),
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
        '[ripple] ▶ ui @ packages/ui\n'
        '[ripple] ■ ui @ packages/ui  (exit 0)\n',
      );
    });

    test('announceRootScopeStart / End write to the sink', () {
      final sink = StringBuffer();

      announceRootScopeStart(sink: sink, forceColor: false);
      announceRootScopeEnd(exitCode: 0, sink: sink, forceColor: false);

      expect(
        sink.toString(),
        '[ripple] ▶ (root)\n'
        '[ripple] ■ (root)  (exit 0)\n',
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
        '[ripple] ▶ ui @ packages/ui\n'
        '[ripple] ■ ui @ packages/ui  (exit 3)\n',
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
      expect(colored.toString(), contains('[ripple] ▶ ui @ packages/ui'));
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
        '\n[ripple] ▶ ui @ packages/ui\n',
      );
      expect(terminalLineState.atLineStart, isTrue);
    });
  });

  group('announceCommand', () {
    tearDown(() {
      terminalLineState.atLineStart = true;
    });

    test('formatCommandLine joins and quotes args that need it', () {
      expect(formatCommandLine(['dart', 'analyze', '.']), 'dart analyze .');
      expect(formatCommandLine(['printf', '%s', 'hello world']),
          "printf %s 'hello world'");
      expect(
        formatCommandLine(['sh', '-c', "echo 'hi'"]),
        r"sh -c 'echo '\''hi'\'''",
      );
      expect(formatCommandLine(['tool', '']), "tool ''");
    });

    test('formatCommandStart / End use plain text without color', () {
      const command = ['dart', 'analyze', '.'];
      expect(
        formatCommandStart(command, scopeLabel: 'ui', color: false),
        '[ripple][ui] \$ dart analyze .',
      );
      expect(
        formatCommandEnd(
          command,
          scopeLabel: 'ui',
          exitCode: 0,
          color: false,
        ),
        '[ripple][ui] \$ dart analyze .  (exit 0)',
      );
      expect(
        formatCommandEnd(
          command,
          scopeLabel: 'ui',
          exitCode: 3,
          color: false,
        ),
        '[ripple][ui] \$ dart analyze .  (exit 3)',
      );
      expect(
        formatCommandStart(command, scopeLabel: rootScopeLabel, color: false),
        '[ripple][(root)] \$ dart analyze .',
      );
    });

    test('formatCommandStart / End wrap ANSI when color is on', () {
      const command = ['dart', 'test'];
      expect(
        formatCommandStart(command, scopeLabel: 'ui', color: true),
        contains('[ripple][ui] \$ dart test'),
      );
      expect(
        formatCommandStart(command, scopeLabel: 'ui', color: true),
        startsWith('\x1B['),
      );
      expect(
        formatCommandEnd(
          command,
          scopeLabel: 'ui',
          exitCode: 0,
          color: true,
        ),
        contains('(exit 0)'),
      );
      expect(
        formatCommandEnd(
          command,
          scopeLabel: 'ui',
          exitCode: 2,
          color: true,
        ),
        contains('(exit 2)'),
      );
    });

    test('announceCommandStart / End write to the sink', () {
      final sink = StringBuffer();
      const command = ['printenv', 'RIPPLE_PACKAGE_NAME'];

      announceCommandStart(
        command,
        scopeLabel: 'ui',
        sink: sink,
        forceColor: false,
      );
      announceCommandEnd(
        command,
        scopeLabel: 'ui',
        exitCode: 0,
        sink: sink,
        forceColor: false,
      );

      expect(
        sink.toString(),
        '[ripple][ui] \$ printenv RIPPLE_PACKAGE_NAME\n'
        '[ripple][ui] \$ printenv RIPPLE_PACKAGE_NAME  (exit 0)\n',
      );
    });

    test('announceCommand inserts a newline when mid-line and ensure is on',
        () {
      terminalLineState.atLineStart = false;
      final sink = StringBuffer();

      announceCommandStart(
        const ['pwd'],
        scopeLabel: rootScopeLabel,
        sink: sink,
        forceColor: false,
        forceEnsureLineStart: true,
      );

      expect(sink.toString(), '\n[ripple][(root)] \$ pwd\n');
      expect(terminalLineState.atLineStart, isTrue);
    });
  });

  group('resolveQuietMode', () {
    test('is false when neither CLI nor script requests quiet', () {
      expect(resolveQuietMode(cliQuiet: false), isFalse);
      expect(
        resolveQuietMode(cliQuiet: false, scriptQuiet: false),
        isFalse,
      );
    });

    test('is true when CLI or script requests quiet', () {
      expect(resolveQuietMode(cliQuiet: true), isTrue);
      expect(
        resolveQuietMode(cliQuiet: false, scriptQuiet: true),
        isTrue,
      );
      expect(
        resolveQuietMode(cliQuiet: true, scriptQuiet: true),
        isTrue,
      );
    });
  });

  group('writeCapturedChildOutput', () {
    test('writes captured stdout and stderr and updates line state', () {
      final out = StringBuffer();
      final err = StringBuffer();
      terminalLineState.atLineStart = true;

      writeCapturedChildOutput(
        capturedStdout: 'hello',
        capturedStderr: 'warn\n',
        stdoutSink: out,
        stderrSink: err,
      );

      expect(out.toString(), 'hello');
      expect(err.toString(), 'warn\n');
      expect(terminalLineState.atLineStart, isTrue);
    });

    test('ignores empty captures', () {
      final out = StringBuffer();
      final err = StringBuffer();

      writeCapturedChildOutput(
        capturedStdout: '',
        capturedStderr: '',
        stdoutSink: out,
        stderrSink: err,
      );

      expect(out.toString(), isEmpty);
      expect(err.toString(), isEmpty);
    });
  });

  group('substituteRippleVars', () {
    const vars = {
      rippleRootPathEnvVar: '/repo',
      ripplePackagePathEnvVar: '/repo/packages/ui',
      ripplePackageNameEnvVar: 'ui',
      ripplePackageVersionEnvVar: '1.2.3',
    };

    test('substitutes \$VAR and \${VAR} forms', () {
      expect(
        substituteRippleVars(
          [
            'echo',
            r'$RIPPLE_PACKAGE_NAME',
            r'${RIPPLE_PACKAGE_PATH}',
            r'root=$RIPPLE_ROOT_PATH',
            r'$RIPPLE_PACKAGE_VERSION',
          ],
          vars: vars,
        ),
        [
          'echo',
          'ui',
          '/repo/packages/ui',
          'root=/repo',
          '1.2.3',
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

  group('detachSharedStdin', () {
    test('is safe to call when forwarding was never started', () async {
      await detachSharedStdin();
      await detachSharedStdin();
    });
  });

  group('runProcess', () {
    final probeScript = p.join(
      Directory.current.path,
      'test',
      'helpers',
      'probe.dart',
    );

    List<String> probe(List<String> args) => [
          Platform.resolvedExecutable,
          probeScript,
          ...args,
        ];

    test('runs a command with cwd and returns exit code', () async {
      final temp = Directory.systemTemp.createTempSync('ripple_exec_helper_');
      addTearDown(() {
        if (temp.existsSync()) {
          temp.deleteSync(recursive: true);
        }
      });

      final marker = File(p.join(temp.path, 'marker.txt'));
      final result = await runProcess(
        probe(['write-file', 'marker.txt', 'ok']),
        workingDirectory: temp.path,
        inheritStdio: false,
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(marker.readAsStringSync(), 'ok');
    });

    test('merges RIPPLE_* into the child environment', () async {
      final result = await runProcess(
        probe(['env', ripplePackageNameEnvVar]),
        workingDirectory: Directory.current.path,
        environment: const {ripplePackageNameEnvVar: 'ui'},
        inheritStdio: false,
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout.trim(), 'ui');
    });

    test('can omit parent environment variables', () async {
      final result = await runProcess(
        probe(['env-root-only']),
        workingDirectory: Directory.current.path,
        environment: {
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
        probe(['exit', '7']),
        workingDirectory: Directory.current.path,
        inheritStdio: false,
      );

      expect(result.exitCode, 7);
    });
  });

  group('resolveConcurrency', () {
    test('defaults to 1 when CLI and script are absent', () {
      expect(resolveConcurrency(), defaultPackageConcurrency);
      expect(resolveConcurrency(), 1);
    });

    test('prefers CLI over script concurrency', () {
      expect(
        resolveConcurrency(cliConcurrency: 4, scriptConcurrency: 2),
        4,
      );
      expect(resolveConcurrency(scriptConcurrency: 3), 3);
    });

    test('rejects values less than 1', () {
      expect(
        () => resolveConcurrency(cliConcurrency: 0),
        throwsArgumentError,
      );
      expect(
        () => resolveConcurrency(scriptConcurrency: -1),
        throwsArgumentError,
      );
    });
  });

  group('runWithBoundedConcurrency', () {
    test('with concurrency 1 runs items in list order', () async {
      final started = <String>[];
      final exit = await runWithBoundedConcurrency<String>(
        items: const ['a', 'b', 'c'],
        concurrency: 1,
        failFast: false,
        run: (item) async {
          started.add(item);
          await Future<void>.delayed(Duration.zero);
          return 0;
        },
      );

      expect(exit, 0);
      expect(started, ['a', 'b', 'c']);
    });

    test('caps in-flight work at concurrency', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final exit = await runWithBoundedConcurrency<int>(
        items: List<int>.generate(6, (i) => i),
        concurrency: 2,
        failFast: false,
        run: (item) async {
          inFlight++;
          if (inFlight > maxInFlight) {
            maxInFlight = inFlight;
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
          inFlight--;
          return 0;
        },
      );

      expect(exit, 0);
      expect(maxInFlight, 2);
    });

    test('without fail-fast runs every item and returns earliest failure',
        () async {
      final ran = <int>[];
      final exit = await runWithBoundedConcurrency<int>(
        items: const [0, 1, 2, 3],
        concurrency: 2,
        failFast: false,
        run: (item) async {
          ran.add(item);
          await Future<void>.delayed(
            Duration(milliseconds: item == 0 ? 40 : 5),
          );
          return item == 0 || item == 2 ? (item + 10) : 0;
        },
      );

      expect(ran.toSet(), {0, 1, 2, 3});
      // Item 0 fails with 10 and is earliest in list order even if item 2
      // completes first.
      expect(exit, 10);
    });

    test('fail-fast does not start further items after a failure', () async {
      final started = <int>[];
      final exit = await runWithBoundedConcurrency<int>(
        items: const [0, 1, 2, 3],
        concurrency: 2,
        failFast: true,
        run: (item) async {
          started.add(item);
          if (item == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return 9;
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return 0;
        },
      );

      expect(exit, 9);
      expect(started, isNot(contains(3)));
      expect(started.length, lessThan(4));
    });

    test('rejects concurrency less than 1', () async {
      expect(
        () => runWithBoundedConcurrency<int>(
          items: const [1],
          concurrency: 0,
          failFast: false,
          run: (_) async => 0,
        ),
        throwsArgumentError,
      );
    });

    test('returns 0 for an empty list', () async {
      expect(
        await runWithBoundedConcurrency<int>(
          items: const [],
          concurrency: 4,
          failFast: false,
          run: (_) async => 1,
        ),
        0,
      );
    });
  });
}
