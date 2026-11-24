/// A failure dartbrew reports to the user as [message], ending the command
/// with [exitCode].
///
/// Commands print [message] to standard error and exit with [exitCode];
/// nothing else interprets the failure.
final class DartbrewException implements Exception {
  final int exitCode;
  final String message;

  const DartbrewException(this.exitCode, this.message);

  @override
  String toString() => message;
}
