import 'finish_reason.dart';

/// Immutable record of one upstream provider attempt.
///
/// The router appends an [AttemptLog] for every try, including failures that
/// trigger failover, retries of the same provider, providers it skipped, and
/// replies served from a response cache, so callers can inspect latency and
/// errors after the fact.
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
    this.finishReason,
    this.timeToFirstTokenMs,
    this.retry = 0,
    this.skipReason,
    this.fromCache = false,
    this.keyIndex,
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

  /// Why the provider stopped, when it said so.
  ///
  /// [FinishReason.length] on a successful attempt means the reply was cut
  /// off at `ProviderConfig.maxOutputTokens`.
  final FinishReason? finishReason;

  /// Milliseconds from sending the request to the first text chunk.
  ///
  /// Null when no text arrived.
  final int? timeToFirstTokenMs;

  /// Zero for the first try of a provider, then 1, 2, and so on for each
  /// retry under a `RetryPolicy`.
  final int retry;

  /// Why the router skipped this provider without calling it, or null when
  /// it was called.
  ///
  /// Reasons include an open circuit breaker, an exhausted budget, and an
  /// attachment the provider cannot take.
  final String? skipReason;

  /// Whether the reply came from a `ResponseCache` instead of a provider.
  final bool fromCache;

  /// Position of the API key used, in `ProviderConfig.allKeys`, or null when
  /// the provider has a single key. The key itself is never logged.
  final int? keyIndex;

  /// Whether the router skipped this provider. See [skipReason].
  bool get isSkipped => skipReason != null;

  @override
  String toString() {
    return 'AttemptLog(providerName: $providerName, model: $model, '
        'timestamp: ${timestamp.toIso8601String()}, latencyMs: $latencyMs, '
        'isSuccess: $isSuccess, error: $error, statusCode: $statusCode, '
        'finishReason: ${finishReason?.name}, '
        'timeToFirstTokenMs: $timeToFirstTokenMs, retry: $retry, '
        'skipReason: $skipReason, fromCache: $fromCache'
        '${keyIndex == null ? '' : ', keyIndex: $keyIndex'})';
  }
}
