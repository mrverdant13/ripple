/// Expand `{{key}}` placeholders from a `replacements` map.
library;

import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/discovery.dart';
import 'package:ripple_cli/src/exec.dart';
import 'package:ripple_cli/src/filters.dart';
import 'package:ripple_cli/src/scripts.dart';

/// Resolves the replacement map for a `run:` invocation or one [package].
///
/// [package] `null` (root `run:` scripts) returns [RippleConfig.replacements]
/// only. Otherwise the first matching [RippleConfig.replacementOverrides]
/// entry is shallow-merged on top. Unspecified keys fall through.
Map<String, String> resolveReplacements({
  required RippleConfig config,
  RipplePackage? package,
  List<RipplePackage> workspacePackages = const [],
  Map<String, List<RipplePackage>>? groupMembership,
}) {
  final merged = Map<String, String>.from(config.replacements);
  if (package == null || config.replacementOverrides.isEmpty) {
    return Map<String, String>.unmodifiable(merged);
  }

  final groups = groupMembership ??
      resolvePackageGroups(config, packages: workspacePackages);

  for (final override in config.replacementOverrides) {
    final matches = filterPackages(
      [package],
      config: config,
      criteria: PackageFilterCriteria(expression: override.filters),
      groupMembership: groups,
    );
    if (matches.isNotEmpty) {
      merged.addAll(override.replacements);
      break;
    }
  }
  return Map<String, String>.unmodifiable(merged);
}

/// Substitutes `$RIPPLE_*` in [command], then expands `{{key}}` placeholders.
List<String> resolveCommandReplacements(
  List<String> command, {
  required Map<String, String> replacements,
  required Map<String, String> vars,
}) {
  return expandReplacements(
    substituteRippleVars(command, vars: vars),
    replacements: replacements,
    vars: vars,
  );
}

/// Expands `{{key}}` placeholders in [command].
///
/// [command] should already have `$RIPPLE_*` substitution applied. Replacement
/// **values** still receive `$RIPPLE_*` substitution via [vars], then are
/// parsed like script steps. Placeholders inside those values are expanded
/// recursively. Bare tokens and spliced argv are not treated as keys.
///
/// Unknown keys, empty `{{}}`, nested `{{`, unclosed `{{`, and circular
/// references throw [RippleConfigException].
List<String> expandReplacements(
  List<String> command, {
  required Map<String, String> replacements,
  required Map<String, String> vars,
}) {
  if (command.isEmpty) {
    return const [];
  }

  final expandedValues = <String, List<String>>{};

  List<String>? tokensFor(String key, List<String> stack) {
    if (stack.contains(key)) {
      final cycle = [...stack, key].join(' -> ');
      throw RippleConfigException(
        'Circular replacement reference: $cycle',
      );
    }
    final cached = expandedValues[key];
    if (cached != null) {
      return cached;
    }
    final raw = replacements[key];
    if (raw == null) {
      return null;
    }
    final tokens = parseScriptCommand(
      substituteRippleVars([raw], vars: vars).single,
    );
    final nextStack = [...stack, key];
    final expanded = <String>[];
    for (final token in tokens) {
      expanded.addAll(
        _expandArg(
          token,
          tokensFor: (nestedKey) => tokensFor(nestedKey, nextStack),
          knownKeys: replacements.keys,
        ),
      );
    }
    expandedValues[key] = expanded;
    return expanded;
  }

  final result = <String>[];
  for (final arg in command) {
    result.addAll(
      _expandArg(
        arg,
        tokensFor: (key) => tokensFor(key, const []),
        knownKeys: replacements.keys,
      ),
    );
  }
  return List<String>.unmodifiable(result);
}

class _PlaceholderSpan {
  const _PlaceholderSpan({
    required this.start,
    required this.end,
    required this.key,
  });

  /// Index of the opening `{{`.
  final int start;

  /// Index after the closing `}}`.
  final int end;

  /// Trimmed inner key.
  final String key;
}

List<String> _expandArg(
  String arg, {
  required List<String>? Function(String key) tokensFor,
  required Iterable<String> knownKeys,
}) {
  final spans = _findPlaceholderSpans(arg);
  if (spans.isEmpty) {
    return [arg];
  }

  final tokens = <String>[];
  var carry = arg.substring(0, spans.first.start);

  for (var i = 0; i < spans.length; i++) {
    final span = spans[i];
    final valueTokens = tokensFor(span.key);
    if (valueTokens == null) {
      final knownList = knownKeys.isEmpty ? '(none)' : knownKeys.join(', ');
      throw RippleConfigException(
        'Unknown replacement "${span.key}". Known replacements: $knownList',
      );
    }

    final nextStart = i + 1 < spans.length ? spans[i + 1].start : arg.length;
    final suffix = arg.substring(span.end, nextStart);

    if (valueTokens.length == 1) {
      carry = '$carry${valueTokens.first}$suffix';
      continue;
    }

    tokens.add('$carry${valueTokens.first}');
    tokens.addAll(valueTokens.sublist(1, valueTokens.length - 1));
    carry = '${valueTokens.last}$suffix';
  }

  if (carry.isNotEmpty) {
    tokens.add(carry);
  }
  return tokens;
}

List<_PlaceholderSpan> _findPlaceholderSpans(String arg) {
  final spans = <_PlaceholderSpan>[];
  var index = 0;
  while (index < arg.length) {
    final start = arg.indexOf('{{', index);
    if (start < 0) {
      break;
    }
    final innerStart = start + 2;
    final close = arg.indexOf('}}', innerStart);
    if (close < 0) {
      throw RippleConfigException(
        'Unclosed replacement placeholder in "$arg"',
      );
    }
    final nested = arg.indexOf('{{', innerStart);
    if (nested >= 0 && nested < close) {
      throw RippleConfigException(
        'Replacement placeholder must not contain nested `{{` in "$arg"',
      );
    }
    final key = arg.substring(innerStart, close).trim();
    if (key.isEmpty) {
      throw const RippleConfigException(
        'Replacement placeholder {{}} must contain a key',
      );
    }
    spans.add(
      _PlaceholderSpan(
        start: start,
        end: close + 2,
        key: key,
      ),
    );
    index = close + 2;
  }
  return spans;
}
