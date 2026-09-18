import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:ripple_cli/src/commands/commands.dart';
import 'package:ripple_cli/src/config.dart';
import 'package:ripple_cli/src/doctor.dart';

/// {@template ripple_cli.doctor_command}
/// `ripple doctor` — report read-only workspace hygiene findings.
/// {@endtemplate}
class DoctorCommand extends RippleCommand {
  /// {@macro ripple_cli.doctor_command}
  DoctorCommand() {
    argParser
      ..addOption(
        formatOptionName,
        help: 'Output format: text (default) or json.',
        allowed: doctorFormatValues,
        allowedHelp: {
          doctorFormatText: 'Human-readable findings (default).',
          doctorFormatJson: 'JSON object with packageCount and findings.',
        },
        defaultsTo: doctorFormatText,
      )
      ..addFlag(
        constraintsFlagName,
        negatable: false,
        help: 'Also report workspace dependency constraints that do not allow '
            "the target package's current pubspec version.",
      );
  }

  /// Option name for `--format`.
  static const formatOptionName = 'format';

  /// Flag name for `--constraints`.
  static const constraintsFlagName = 'constraints';

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Report read-only workspace hygiene findings for the Ripple root.';

  @override
  bool get takesArguments => false;

  @override
  Future<void> run() async {
    final format = argResults!.option(formatOptionName)!;
    if (!doctorFormatValues.contains(format)) {
      throw UsageException(
        'Invalid --$formatOptionName "$format". '
        'Allowed: ${doctorFormatValues.join(', ')}.',
        usage,
      );
    }

    final config = loadRippleConfig();
    final report = runDoctor(
      config,
      checkConstraints: argResults!.flag(constraintsFlagName),
    );

    if (format == doctorFormatJson) {
      stdout.writeln(formatDoctorJson(report));
    } else {
      stdout.writeln(formatDoctorText(report));
    }

    if (report.hasErrors) {
      exitCode = 1;
    }
  }
}

/// Default / human `--format` value for [DoctorCommand].
const doctorFormatText = 'text';

/// JSON `--format` value for [DoctorCommand].
const doctorFormatJson = 'json';

/// Allowed `--format` values for [DoctorCommand].
const doctorFormatValues = [doctorFormatText, doctorFormatJson];
