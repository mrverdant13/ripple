/// Resolve named scripts from config and map them to run/exec execution.
library;

import 'config.dart';

/// Looks up [name] in [config.scripts].
///
/// Throws [RippleConfigException] when the script is missing. The error names
/// the unknown key and lists available script ids when any are defined.
RippleScript resolveScript(RippleConfig config, String name) {
  final script = config.scripts[name];
  if (script != null) {
    return script;
  }

  final known = config.scripts.keys;
  final knownList = known.isEmpty ? '(none)' : known.join(', ');
  throw RippleConfigException(
    'Unknown script "$name". Available scripts: $knownList',
  );
}

/// Splits a script command string into an executable plus arguments.
///
/// Supports whitespace separation and single/double quotes. Does not invoke a
/// shell — the result is suitable for [runProcess]. Throws
/// [RippleConfigException] when the command is empty or quoting is unbalanced.
List<String> parseScriptCommand(String command) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    throw const RippleConfigException('Script command must not be empty.');
  }

  final args = <String>[];
  final buffer = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var escape = false;
  var tokenStarted = false;

  void flush() {
    if (!tokenStarted) {
      return;
    }
    args.add(buffer.toString());
    buffer.clear();
    tokenStarted = false;
  }

  for (final unit in trimmed.runes) {
    final char = String.fromCharCode(unit);

    if (escape) {
      buffer.write(char);
      tokenStarted = true;
      escape = false;
      continue;
    }

    if (char == r'\' && !inSingle) {
      escape = true;
      tokenStarted = true;
      continue;
    }

    if (char == "'" && !inDouble) {
      inSingle = !inSingle;
      tokenStarted = true;
      continue;
    }

    if (char == '"' && !inSingle) {
      inDouble = !inDouble;
      tokenStarted = true;
      continue;
    }

    if (!inSingle && !inDouble && _isWhitespace(char)) {
      flush();
      continue;
    }

    buffer.write(char);
    tokenStarted = true;
  }

  if (escape) {
    throw const RippleConfigException(
      'Invalid script command: trailing escape character.',
    );
  }
  if (inSingle || inDouble) {
    throw const RippleConfigException(
      'Invalid script command: unmatched quote.',
    );
  }

  flush();

  if (args.isEmpty) {
    throw const RippleConfigException('Script command must not be empty.');
  }

  return List<String>.unmodifiable(args);
}

bool _isWhitespace(String char) =>
    char == ' ' || char == '\t' || char == '\n' || char == '\r';
