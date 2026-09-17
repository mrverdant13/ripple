/// Format helpers for `ripple list` output (`paths`, `json`, `mermaid`).
library;

import 'dart:convert';

import 'package:pubspec_parse/pubspec_parse.dart';

import 'config.dart';
import 'discovery.dart';
import 'graph.dart';

/// Supported `--format` values for `ripple list`.
const listFormatPaths = 'paths';

/// JSON array of package objects (see [packageListEntry]).
const listFormatJson = 'json';

/// Mermaid `flowchart TD` of workspace edges among selected packages.
const listFormatMermaid = 'mermaid';

/// Allowed `--format` values, in help / validation order.
const listFormatValues = [
  listFormatPaths,
  listFormatJson,
  listFormatMermaid,
];

/// `"flutter"` when [pubspec] declares `environment.flutter`, else `"dart"`.
///
/// Same signal as [FilterSdk] / `--sdk`. A `flutter` SDK dependency alone
/// does not make a package Flutter.
String packageSdkLabel(Pubspec pubspec) {
  return pubspec.environment.containsKey('flutter')
      ? packageSdkFlutter
      : packageSdkDart;
}

/// One JSON object for a selected package (CI matrix / inspect).
///
/// [workspaceDependencies] / [workspaceDependents] use package **names**,
/// ordered by the dependency package's relative path. Hosted deps are omitted
/// (they are not workspace graph edges).
Map<String, Object?> packageListEntry(
  RipplePackage package,
  WorkspaceGraph graph,
) {
  final pubspec = resolvePackagePubspec(package);
  return {
    'name': package.name,
    'path': package.relativePath,
    'version': pubspec.version?.toString(),
    'sdk': packageSdkLabel(pubspec),
    'workspaceDependencies': [
      for (final dep in graph.dependenciesOf(package)) dep.name,
    ],
    'workspaceDependents': [
      for (final dep in graph.dependentsOf(package)) dep.name,
    ],
  };
}

/// Formats [packages] as a JSON array string (stable order preserved).
String formatPackageListJson(
  List<RipplePackage> packages,
  WorkspaceGraph graph,
) {
  final entries = [
    for (final package in packages) packageListEntry(package, graph),
  ];
  return jsonEncode(entries);
}

/// Formats [packages] as a Mermaid flowchart of **workspace** edges only.
///
/// Every selected package is emitted as a node so isolates appear. An edge
/// `A --> B` is emitted when both ends are in [packages].
String formatPackageListMermaid(
  List<RipplePackage> packages,
  WorkspaceGraph graph,
) {
  final selected = {
    for (final package in packages) package.relativePath,
  };
  final buffer = StringBuffer('flowchart TD\n');
  for (final package in packages) {
    buffer.writeln('  ${package.name}');
  }
  for (final package in packages) {
    for (final dep in graph.dependenciesOf(package)) {
      if (!selected.contains(dep.relativePath)) {
        continue;
      }
      buffer.writeln('  ${package.name} --> ${dep.name}');
    }
  }
  return buffer.toString();
}
