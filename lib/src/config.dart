/// Load and validate `ripple.yaml` from a consumer repository.
library;

import 'dart:io';

import 'package:checked_yaml/checked_yaml.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;

/// Thrown when `ripple.yaml` cannot be found, read, parsed, or validated.
class RippleConfigException implements Exception {
  /// Creates a config error with a human-readable [message].
  const RippleConfigException(this.message);

  /// Description of what went wrong.
  final String message;

  @override
  String toString() => 'RippleConfigException: $message';
}

/// How a named script executes.
///
/// - [ScriptKind.run]: execute once with cwd = the Ripple config root
///   (the directory that contains `ripple.yaml`).
/// - [ScriptKind.exec]: execute once per matching package with cwd = that
///   package's directory.
enum ScriptKind {
  /// Run once at the Ripple config root.
  run,

  /// Run once per matching package.
  exec,
}

/// Filters declared on an `exec:` script.
///
/// Stored as data here; callers apply these filters when selecting packages.
class ScriptFilters {
  /// Creates script filters from config.
  const ScriptFilters({
    this.dirExists = const [],
    this.fileExists = const [],
    this.dependsOn = const [],
    this.group,
    this.match = const [],
    this.noMatch = const [],
  });

  /// Relative directory paths that must exist under each package root.
  final List<String> dirExists;

  /// Relative file paths that must exist under each package root.
  final List<String> fileExists;

  /// Direct dependency names that must appear in the package pubspec.
  final List<String> dependsOn;

  /// Named group from `packages.groups`; package must be a member.
  final String? group;

  /// Package-name globs; package must match at least one when non-empty.
  final List<String> match;

  /// Package-name globs; package must match none when non-empty.
  final List<String> noMatch;
}

/// A named script from the `scripts` map in `ripple.yaml`.
///
/// Exactly one of `run:` or `exec:` is allowed per script (XOR). A `run:`
/// script must not declare `filters`.
///
/// [commands] is one or more argv command strings run sequentially (fail-fast
/// between steps). A bare string in YAML is normalized to a single-element
/// list; a YAML list is multiple steps.
class RippleScript {
  /// Creates a validated script entry.
  const RippleScript({
    required this.name,
    required this.kind,
    required this.commands,
    this.filters,
  }) : assert(
          kind == ScriptKind.exec || filters == null,
          'run: scripts must not declare filters',
        );

  /// Key under `scripts:` (may contain dots, e.g. `format.ci`).
  final String name;

  /// Whether this script runs once at the root or once per package.
  final ScriptKind kind;

  /// Command strings from `run:` or `exec:` (string or YAML list).
  ///
  /// Each entry is split into an executable plus arguments at execution time.
  /// Steps run in order and stop on the first non-zero exit.
  final List<String> commands;

  /// Optional filters; only valid when [kind] is [ScriptKind.exec].
  final ScriptFilters? filters;
}

/// Package discovery settings under `packages:`.
class RipplePackages {
  /// Creates package include/exclude/group settings.
  const RipplePackages({
    this.include = const [],
    this.exclude = const [],
    this.groups = const {},
  });

  /// Glob patterns (relative to the Ripple root) for candidate package dirs.
  final List<String> include;

  /// Glob patterns to subtract from include matches.
  final List<String> exclude;

  /// Named sets of path globs for group filtering.
  final Map<String, List<String>> groups;
}

/// Typed model for a loaded `ripple.yaml`.
class RippleConfig {
  /// Creates a config bound to the directory that contained `ripple.yaml`.
  const RippleConfig({
    required this.rootPath,
    this.name,
    this.packages = const RipplePackages(),
    this.scripts = const {},
  });

  /// Absolute path of the directory containing `ripple.yaml`.
  final String rootPath;

  /// Optional display name from the top-level `name` key.
  final String? name;

  /// Package include/exclude/group settings.
  final RipplePackages packages;

  /// Named scripts keyed by script id.
  final Map<String, RippleScript> scripts;
}

/// File name sought when discovering the Ripple config root.
const rippleYamlFileName = 'ripple.yaml';

/// Walks upward from [start] until a `ripple.yaml` is found.
///
/// Returns the absolute path of that file. Throws [RippleConfigException] if
/// none exists between [start] and the filesystem root.
String findRippleYamlPath({Directory? start}) {
  var dir = (start ?? Directory.current).absolute;
  while (true) {
    final candidate = File(p.join(dir.path, rippleYamlFileName));
    if (candidate.existsSync()) {
      return candidate.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw RippleConfigException(
        'No $rippleYamlFileName found from ${start?.path ?? Directory.current.path} '
        'up to the filesystem root.',
      );
    }
    dir = parent;
  }
}

/// Loads, parses, and validates the nearest ancestor `ripple.yaml`.
///
/// The returned [RippleConfig.rootPath] is the directory containing that file.
RippleConfig loadRippleConfig({Directory? start}) {
  final yamlPath = findRippleYamlPath(start: start);
  final file = File(yamlPath);
  late final String contents;
  try {
    contents = file.readAsStringSync();
  } on FileSystemException catch (error) {
    throw RippleConfigException(
      'Failed to read $yamlPath: ${error.message}',
    );
  }
  return parseRippleYaml(
    contents,
    rootPath: p.dirname(yamlPath),
    sourceUrl: p.toUri(yamlPath),
  );
}

/// Parses and validates [yamlContent] as a `ripple.yaml` document.
///
/// [rootPath] is the directory that contains the config file (not the file
/// path itself). Throws [RippleConfigException] for invalid YAML or schema
/// violations (including script `run`/`exec` XOR and `filters` on `run:`).
RippleConfig parseRippleYaml(
  String yamlContent, {
  required String rootPath,
  Uri? sourceUrl,
}) {
  try {
    return checkedYamlDecode(
      yamlContent,
      (Map<dynamic, dynamic>? map) {
        if (map == null) {
          throw CheckedFromJsonException(
            <String, dynamic>{},
            null,
            'RippleConfig',
            'ripple.yaml must be a non-null YAML map',
          );
        }
        return _configFromMap(map, rootPath: rootPath);
      },
      sourceUrl: sourceUrl,
    );
  } on ParsedYamlException catch (error) {
    throw RippleConfigException(_parsedYamlMessage(error));
  } on CheckedFromJsonException catch (error) {
    throw RippleConfigException(_checkedFromJsonMessage(error));
  }
}

RippleConfig _configFromMap(
  Map<dynamic, dynamic> map, {
  required String rootPath,
}) {
  final name = _optionalString(map, 'name', 'RippleConfig');
  final packages = _packagesFromValue(map['packages'], map);
  final scripts = _scriptsFromValue(map['scripts'], map);
  return RippleConfig(
    rootPath: rootPath,
    name: name,
    packages: packages,
    scripts: scripts,
  );
}

RipplePackages _packagesFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const RipplePackages();
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'packages',
      'RippleConfig',
      'Expected a map',
    );
  }
  final Map<dynamic, dynamic> map = value;
  return RipplePackages(
    include: _stringList(map, 'include', 'RipplePackages'),
    exclude: _stringList(map, 'exclude', 'RipplePackages'),
    groups: _groupsFromValue(map['groups'], map),
  );
}

Map<String, List<String>> _groupsFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const {};
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'groups',
      'RipplePackages',
      'Expected a map of group name to path-glob lists',
    );
  }
  final groups = <String, List<String>>{};
  final Map<dynamic, dynamic> map = value;
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw CheckedFromJsonException(
        map,
        key?.toString(),
        'RipplePackages',
        'Group names must be strings',
      );
    }
    groups[key] = _stringListAt(
      map,
      key,
      entry.value,
      'RipplePackages.groups',
    );
  }
  return Map<String, List<String>>.unmodifiable(groups);
}

Map<String, RippleScript> _scriptsFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return const {};
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'scripts',
      'RippleConfig',
      'Expected a map of script name to script definition',
    );
  }
  final scripts = <String, RippleScript>{};
  final Map<dynamic, dynamic> map = value;
  for (final entry in map.entries) {
    final key = entry.key;
    if (key is! String) {
      throw CheckedFromJsonException(
        map,
        key?.toString(),
        'RippleConfig',
        'Script names must be strings',
      );
    }
    scripts[key] = _scriptFromValue(key, entry.value, map);
  }
  return Map<String, RippleScript>.unmodifiable(scripts);
}

RippleScript _scriptFromValue(
  String name,
  Object? value,
  Map<dynamic, dynamic> scriptsMap,
) {
  if (value is! Map) {
    throw CheckedFromJsonException(
      scriptsMap,
      name,
      'RippleScript',
      'Script "$name" must be a map',
    );
  }
  final Map<dynamic, dynamic> map = value;
  final hasRun = map['run'] != null;
  final hasExec = map['exec'] != null;

  if (hasRun == hasExec) {
    throw CheckedFromJsonException(
      map,
      hasRun ? 'run' : 'exec',
      'RippleScript',
      'Script "$name" must declare exactly one of `run:` or `exec:`',
    );
  }

  final filtersValue = map['filters'];
  if (hasRun && filtersValue != null) {
    throw CheckedFromJsonException(
      map,
      'filters',
      'RippleScript',
      'Script "$name" uses `run:` and must not declare `filters`',
    );
  }

  final kindKey = hasRun ? 'run' : 'exec';
  final commands = _commandsFromValue(
    map[kindKey],
    map: map,
    key: kindKey,
    scriptName: name,
  );

  return RippleScript(
    name: name,
    kind: hasRun ? ScriptKind.run : ScriptKind.exec,
    commands: commands,
    filters: hasExec ? _filtersFromValue(filtersValue, map) : null,
  );
}

/// Parses a `run:` / `exec:` value as a non-empty string or list of strings.
///
/// Rejects empty lists, non-string items, blank command strings, and command
/// strings that contain unquoted `&&` (use a YAML list instead, or `sh -c`
/// when a real shell is required).
List<String> _commandsFromValue(
  Object? value, {
  required Map<dynamic, dynamic> map,
  required String key,
  required String scriptName,
}) {
  late final List<String> raw;
  if (value is String) {
    raw = [value];
  } else if (value is List) {
    if (value.isEmpty) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleScript',
        'Script "$scriptName" `$key:` must be a non-empty string or list',
      );
    }
    raw = <String>[];
    for (var i = 0; i < value.length; i++) {
      final element = value[i];
      if (element is! String) {
        throw CheckedFromJsonException(
          map,
          key,
          'RippleScript',
          'Script "$scriptName" `$key:` must be a string or list of strings '
              '(index $i)',
        );
      }
      raw.add(element);
    }
  } else {
    throw CheckedFromJsonException(
      map,
      key,
      'RippleScript',
      'Script "$scriptName" `$key:` must be a string or list of strings',
    );
  }

  final commands = <String>[];
  for (var i = 0; i < raw.length; i++) {
    final command = raw[i];
    if (command.trim().isEmpty) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleScript',
        raw.length == 1
            ? 'Script "$scriptName" command must be a non-empty string'
            : 'Script "$scriptName" `$key:` step ${i + 1} must be a non-empty '
                'string',
      );
    }
    if (_containsUnquotedAnd(command)) {
      throw CheckedFromJsonException(
        map,
        key,
        'RippleScript',
        'Script "$scriptName" command must not contain unquoted `&&`. '
            'Use a YAML list of steps under `$key:`, or wrap shell compound '
            "commands in `sh -c '…'`.",
      );
    }
    commands.add(command);
  }

  return List<String>.unmodifiable(commands);
}

/// Returns true when [command] contains `&&` outside of single/double quotes.
bool _containsUnquotedAnd(String command) {
  var inSingle = false;
  var inDouble = false;
  var escape = false;

  for (var i = 0; i < command.length; i++) {
    final char = command[i];

    if (escape) {
      escape = false;
      continue;
    }

    if (char == r'\' && !inSingle) {
      escape = true;
      continue;
    }

    if (char == "'" && !inDouble) {
      inSingle = !inSingle;
      continue;
    }

    if (char == '"' && !inSingle) {
      inDouble = !inDouble;
      continue;
    }

    if (!inSingle &&
        !inDouble &&
        char == '&' &&
        i + 1 < command.length &&
        command[i + 1] == '&') {
      return true;
    }
  }

  return false;
}

ScriptFilters? _filtersFromValue(
  Object? value,
  Map<dynamic, dynamic> parent,
) {
  if (value == null) {
    return null;
  }
  if (value is! Map) {
    throw CheckedFromJsonException(
      parent,
      'filters',
      'RippleScript',
      'Expected a map',
    );
  }
  final Map<dynamic, dynamic> map = value;
  return ScriptFilters(
    dirExists: _stringList(map, 'dirExists', 'ScriptFilters'),
    fileExists: _stringList(map, 'fileExists', 'ScriptFilters'),
    dependsOn: _stringList(map, 'dependsOn', 'ScriptFilters'),
    group: _optionalString(map, 'group', 'ScriptFilters'),
    match: _stringList(map, 'match', 'ScriptFilters'),
    noMatch: _stringList(map, 'noMatch', 'ScriptFilters'),
  );
}

String? _optionalString(
  Map<dynamic, dynamic> map,
  String key,
  String className,
) {
  final value = map[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw CheckedFromJsonException(
      map,
      key,
      className,
      'Expected a string',
    );
  }
  return value;
}

List<String> _stringList(
  Map<dynamic, dynamic> map,
  String key,
  String className,
) {
  return _stringListAt(map, key, map[key], className);
}

List<String> _stringListAt(
  Map<dynamic, dynamic> map,
  String key,
  Object? value,
  String className,
) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw CheckedFromJsonException(
      map,
      key,
      className,
      'Expected a list of strings',
    );
  }
  final result = <String>[];
  for (var i = 0; i < value.length; i++) {
    final element = value[i];
    if (element is! String) {
      throw CheckedFromJsonException(
        map,
        key,
        className,
        'Expected a list of strings (index $i)',
      );
    }
    result.add(element);
  }
  return List<String>.unmodifiable(result);
}

String _parsedYamlMessage(ParsedYamlException error) {
  final formatted = error.formattedMessage;
  if (formatted != null && formatted.isNotEmpty) {
    return formatted;
  }
  if (error.message.isNotEmpty) {
    return error.message;
  }
  return error.toString();
}

String _checkedFromJsonMessage(CheckedFromJsonException error) {
  final key = error.key;
  final message = error.message;
  if (key != null && message != null) {
    return 'Invalid `$key`: $message';
  }
  if (message != null) {
    return message;
  }
  return error.toString();
}
