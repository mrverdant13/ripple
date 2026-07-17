import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/scripts.dart';
import 'package:test/test.dart';

void main() {
  group('resolveScript', () {
    const config = RippleConfig(
      rootPath: '/repo',
      scripts: {
        'format.ci': RippleScript(
          name: 'format.ci',
          kind: ScriptKind.run,
          commands: ['dart format .'],
        ),
        'analyze.ci': RippleScript(
          name: 'analyze.ci',
          kind: ScriptKind.exec,
          commands: ['dart analyze .'],
        ),
      },
    );

    test('returns the named script', () {
      final script = resolveScript(config, 'format.ci');
      expect(script.name, 'format.ci');
      expect(script.kind, ScriptKind.run);
      expect(script.commands, ['dart format .']);
    });

    test('lists available scripts when the name is unknown', () {
      expect(
        () => resolveScript(config, 'missing'),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Unknown script "missing"'),
              contains('format.ci'),
              contains('analyze.ci'),
            ),
          ),
        ),
      );
    });

    test('reports (none) when config has no scripts', () {
      const empty = RippleConfig(rootPath: '/repo');
      expect(
        () => resolveScript(empty, 'format.ci'),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            contains('Available scripts: (none)'),
          ),
        ),
      );
    });
  });

  group('parseScriptCommand', () {
    test('splits on whitespace', () {
      expect(
        parseScriptCommand('dart analyze --fatal-infos .'),
        ['dart', 'analyze', '--fatal-infos', '.'],
      );
    });

    test('preserves quoted segments', () {
      expect(
        parseScriptCommand(r'''sh -c 'printf "%s\n" "$NAME"' '''),
        ['sh', '-c', r'printf "%s\n" "$NAME"'],
      );
    });

    test('preserves empty quoted arguments', () {
      expect(parseScriptCommand('echo ""'), ['echo', '']);
      expect(parseScriptCommand("echo ''"), ['echo', '']);
      expect(
        parseScriptCommand(r'''printf "%s" "" '''),
        ['printf', '%s', ''],
      );
    });

    test('supports escaped characters outside quotes', () {
      expect(
        parseScriptCommand(r'echo hello\ world'),
        ['echo', 'hello world'],
      );
    });

    test('rejects empty commands', () {
      expect(
        () => parseScriptCommand('   '),
        throwsA(isA<RippleConfigException>()),
      );
    });

    test('rejects unmatched quotes', () {
      expect(
        () => parseScriptCommand('echo "hello'),
        throwsA(
          isA<RippleConfigException>().having(
            (error) => error.message,
            'message',
            contains('unmatched quote'),
          ),
        ),
      );
    });
  });
}
