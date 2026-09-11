import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/exec.dart';
import 'package:ripple_cli/src/replacements.dart';
import 'package:test/test.dart';

void main() {
  const vars = {
    rippleRootPathEnvVar: '/repo',
    ripplePackagePathEnvVar: '/repo/packages/ui',
    ripplePackageNameEnvVar: 'ui',
  };

  List<String> expand(
    List<String> command, {
    Map<String, String> replacements = const {'dart': 'fvm dart'},
    Map<String, String> environment = vars,
  }) {
    return expandReplacements(
      command,
      replacements: replacements,
      vars: environment,
    );
  }

  group('expandReplacements', () {
    test('returns an empty list for an empty command', () {
      expect(expand(const []), isEmpty);
    });

    test('leaves args without placeholders unchanged', () {
      expect(
        expand(const ['dart', 'analyze', '.']),
        ['dart', 'analyze', '.'],
      );
    });

    test('splices a multi-word value as separate argv tokens', () {
      expect(
        expand(const ['{{dart}}', 'analyze', '.']),
        ['fvm', 'dart', 'analyze', '.'],
      );
    });

    test('reuses a parsed value when the same key appears twice', () {
      expect(
        expand(const ['{{dart}}', '{{dart}}']),
        ['fvm', 'dart', 'fvm', 'dart'],
      );
    });

    test('splices a single-word value as one token', () {
      expect(
        expand(
          const ['{{dart}}', 'analyze', '.'],
          replacements: const {'dart': '/opt/dart/bin/dart'},
        ),
        ['/opt/dart/bin/dart', 'analyze', '.'],
      );
    });

    test('attaches prefix and suffix around spliced tokens', () {
      expect(
        expand(const ['pre-{{dart}}-post']),
        ['pre-fvm', 'dart-post'],
      );
    });

    test('attaches prefix and suffix around a single-token value', () {
      expect(
        expand(
          const ['pre-{{dart}}-post'],
          replacements: const {'dart': 'echo'},
        ),
        ['pre-echo-post'],
      );
    });

    test('drops a trailing empty value token after splice', () {
      expect(
        expand(
          const ['{{dart}}'],
          replacements: const {'dart': "fvm ''"},
        ),
        ['fvm'],
      );
    });

    test('splices three-or-more value tokens with prefix and suffix', () {
      expect(
        expand(
          const ['pre-{{coverde}}-post'],
          replacements: const {'coverde': 'dart run coverde'},
        ),
        ['pre-dart', 'run', 'coverde-post'],
      );
    });

    test('expands multiple placeholders in one token', () {
      expect(
        expand(
          const ['{{dart}}-{{flutter}}'],
          replacements: const {
            'dart': 'fvm dart',
            'flutter': 'fvm flutter',
          },
        ),
        ['fvm', 'dart-fvm', 'flutter'],
      );
    });

    test('trims inner placeholder spacing', () {
      expect(
          expand(const ['{{ dart }}', 'analyze']), ['fvm', 'dart', 'analyze']);
    });

    test('does not rescan spliced tokens', () {
      expect(
        expand(
          const ['{{dart}}', 'analyze'],
          replacements: const {
            'dart': 'fvm dart',
            'fvm': 'SHOULD_NOT_APPEAR',
          },
        ),
        ['fvm', 'dart', 'analyze'],
      );
    });

    test('expands placeholders inside replacement values', () {
      expect(
        expand(
          const ['{{dart}}'],
          replacements: const {
            'dart': '{{flutter}}',
            'flutter': 'fvm flutter',
          },
        ),
        ['fvm', 'flutter'],
      );
    });

    test('composes coverde from dart', () {
      expect(
        expand(
          const ['{{coverde}}', 'check'],
          replacements: const {
            'dart': 'fvm dart',
            'coverde': '{{dart}} run coverde',
          },
        ),
        ['fvm', 'dart', 'run', 'coverde', 'check'],
      );
    });

    test('expands a longer placeholder chain', () {
      expect(
        expand(
          const ['{{a}}'],
          replacements: const {
            'a': '{{b}} x',
            'b': '{{c}} y',
            'c': 'z',
          },
        ),
        ['z', 'y', 'x'],
      );
    });

    test('attaches prefix and suffix around a nested multi-token value', () {
      expect(
        expand(
          const ['pre-{{coverde}}-post'],
          replacements: const {
            'dart': 'fvm dart',
            'coverde': '{{dart}} run coverde',
          },
        ),
        ['pre-fvm', 'dart', 'run', 'coverde-post'],
      );
    });

    test('uses the merged map so an override of dart flows into coverde', () {
      const config = RippleConfig(
        rootPath: '/repo',
        replacements: {
          'dart': 'fvm dart',
          'coverde': '{{dart}} run coverde',
        },
        replacementOverrides: [
          ReplacementOverride(
            filters: FilterAnd([
              FilterMatch(['legacy']),
            ]),
            replacements: {'dart': 'puro dart'},
          ),
        ],
      );
      const legacy = RipplePackage(
        name: 'legacy',
        path: '/repo/packages/legacy',
        relativePath: 'packages/legacy',
      );

      expect(
        expand(
          const ['{{coverde}}'],
          replacements: resolveReplacements(config: config, package: legacy),
        ),
        ['puro', 'dart', 'run', 'coverde'],
      );
    });

    test('rejects a self-referential replacement', () {
      expect(
        () => expand(
          const ['{{dart}}'],
          replacements: const {'dart': '{{dart}}'},
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Circular replacement reference'),
              contains('dart -> dart'),
            ),
          ),
        ),
      );
    });

    test('rejects a two-key replacement cycle', () {
      expect(
        () => expand(
          const ['{{dart}}'],
          replacements: const {
            'dart': '{{coverde}}',
            'coverde': '{{dart}} run coverde',
          },
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Circular replacement reference'),
              contains('dart -> coverde -> dart'),
            ),
          ),
        ),
      );
    });

    test('rejects a longer replacement cycle', () {
      expect(
        () => expand(
          const ['{{a}}'],
          replacements: const {
            'a': '{{b}}',
            'b': '{{c}}',
            'c': '{{a}}',
          },
        ),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Circular replacement reference'),
              contains('a -> b -> c -> a'),
            ),
          ),
        ),
      );
    });

    test('substitutes \$RIPPLE_* inside replacement values', () {
      expect(
        expand(
          const ['{{dart}}'],
          replacements: const {
            'dart': r'$RIPPLE_PACKAGE_PATH/.fvm/flutter_sdk/bin/dart',
          },
        ),
        ['/repo/packages/ui/.fvm/flutter_sdk/bin/dart'],
      );
    });

    test('resolveCommandReplacements substitutes vars then expands', () {
      expect(
        resolveCommandReplacements(
          const [r'{{dart}}', r'$RIPPLE_PACKAGE_NAME'],
          replacements: const {'dart': 'fvm dart'},
          vars: vars,
        ),
        ['fvm', 'dart', 'ui'],
      );
    });

    test('rejects an unknown replacement key', () {
      expect(
        () => expand(const ['{{darrt}}']),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('darrt'), contains('Known replacements: dart')),
          ),
        ),
      );
    });

    test('rejects an unknown key when the map is empty', () {
      expect(
        () => expand(const ['{{dart}}'], replacements: const {}),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('dart'), contains('(none)')),
          ),
        ),
      );
    });

    test('rejects an empty placeholder', () {
      expect(
        () => expand(const ['{{}}']),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('must contain a key'),
          ),
        ),
      );
    });

    test('rejects a whitespace-only placeholder', () {
      expect(
        () => expand(const ['{{   }}']),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('must contain a key'),
          ),
        ),
      );
    });

    test('rejects nested placeholders', () {
      expect(
        () => expand(const ['{{foo{{bar}}}}']),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('nested'),
          ),
        ),
      );
    });

    test('rejects an unclosed placeholder', () {
      expect(
        () => expand(const ['{{dart']),
        throwsA(
          isA<RippleConfigException>().having(
            (e) => e.message,
            'message',
            contains('Unclosed'),
          ),
        ),
      );
    });

    test('rejects a replacement value with unmatched quotes', () {
      expect(
        () => expand(
          const ['{{dart}}'],
          replacements: const {'dart': "fvm 'dart"},
        ),
        throwsA(isA<RippleConfigException>()),
      );
    });
  });

  group('resolveReplacements', () {
    const core = RipplePackage(
      name: 'core',
      path: '/repo/packages/core',
      relativePath: 'packages/core',
    );
    const legacy = RipplePackage(
      name: 'legacy',
      path: '/repo/packages/legacy',
      relativePath: 'packages/legacy',
    );

    const config = RippleConfig(
      rootPath: '/repo',
      replacements: {
        'dart': 'fvm dart',
        'flutter': 'fvm flutter',
      },
      replacementOverrides: [
        ReplacementOverride(
          filters: FilterAnd([
            FilterMatch(['legacy']),
          ]),
          replacements: {'dart': 'puro dart'},
        ),
        ReplacementOverride(
          filters: FilterAnd([
            FilterMatch(['legacy']),
          ]),
          replacements: {'dart': 'SHOULD_NOT_WIN'},
        ),
      ],
    );

    test('returns defaults when package is omitted (run:)', () {
      expect(
        resolveReplacements(config: config),
        {
          'dart': 'fvm dart',
          'flutter': 'fvm flutter',
        },
      );
    });

    test('returns defaults when no override matches', () {
      expect(
        resolveReplacements(config: config, package: core),
        {
          'dart': 'fvm dart',
          'flutter': 'fvm flutter',
        },
      );
    });

    test('first matching override wins and shallow-merges', () {
      expect(
        resolveReplacements(config: config, package: legacy),
        {
          'dart': 'puro dart',
          'flutter': 'fvm flutter',
        },
      );
    });

    test('returns defaults when there are no overrides', () {
      const bare = RippleConfig(
        rootPath: '/repo',
        replacements: {'dart': 'dart'},
      );
      expect(
        resolveReplacements(config: bare, package: core),
        {'dart': 'dart'},
      );
    });

    test('uses provided group membership for group filters', () {
      const grouped = RippleConfig(
        rootPath: '/repo',
        replacements: {'dart': 'fvm dart'},
        packages: RipplePackages(
          groups: {
            'puro': ['packages/core'],
          },
        ),
        replacementOverrides: [
          ReplacementOverride(
            filters: FilterAnd([
              FilterGroup('puro'),
            ]),
            replacements: {'dart': 'puro dart'},
          ),
        ],
      );

      expect(
        resolveReplacements(
          config: grouped,
          package: core,
          workspacePackages: const [core, legacy],
        ),
        {'dart': 'puro dart'},
      );
      expect(
        resolveReplacements(
          config: grouped,
          package: core,
          groupMembership: const {
            'puro': [core],
          },
        ),
        {'dart': 'puro dart'},
      );
      expect(
        resolveReplacements(
          config: grouped,
          package: legacy,
          groupMembership: const {
            'puro': [core],
          },
        ),
        {'dart': 'fvm dart'},
      );
    });
  });
}
