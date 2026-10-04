/// Immutable record of one upstream provider attempt.
///
/// The router appends an [AttemptLog] for every try, including failures that
/// trigger failover, so callers can inspect latency and errors after the fact.
class AttemptLog {
  /// Creates a record of a single provider attempt.
  const AttemptLog({
    required this.providerName,
    required this.model,
    required this.timestamp,
    required this.latencyMs,
    required this.isSuccess,
    this.error,
    this.statusCode,
  });

  /// `ProviderConfig.name` of the upstream that was called.
  final String providerName;

  /// Model id sent on this attempt.
  final String model;

  /// Time the attempt finished and the log was recorded.
  final DateTime timestamp;

  /// Round-trip time of the attempt, in milliseconds.
  final int latencyMs;

  /// Whether the upstream returned a usable response.
  final bool isSuccess;

  /// Failure detail when [isSuccess] is false.
  ///
  /// Null on a successful attempt.
  final String? error;

  /// HTTP status returned by the upstream, when the transport provided one.
  final int? statusCode;

  @override
  String toString() {
    return 'AttemptLog(providerName: $providerName, model: $model, '
        'timestamp: ${timestamp.toIso8601String()}, latencyMs: $latencyMs, '
        'isSuccess: $isSuccess, error: $error, statusCode: $statusCode)';
  }
}
