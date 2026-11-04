import 'dart:math';

import '../exceptions/router_exceptions.dart';

/// When and how long to wait before retrying the same provider.
///
/// The router retries only before any text was shown, and only for
/// transient failures: HTTP 408, 429, and 5xx (including Anthropic's
/// in-stream `overloaded_error`, reported as 529), timeouts, and dropped
/// connections. [ProviderUnavailableLlmException], [TerminalLlmException],
/// and empty replies are never retried. When retries run out, the router
/// fails over to the next provider as usual.
///
/// The wait before retry `n` (counting from zero) is
/// `initialDelay * multiplier^n`, capped at [maxDelay], then varied by up to
/// [jitter] in either direction. A `Retry-After` header replaces that wait
/// when [respectRetryAfter] is true. A `Retry-After` longer than [maxDelay]
/// skips the retry and fails over instead.
class RetryPolicy {
  /// Creates a retry policy.
  ///
  /// [maxRetries] must be zero or positive, [multiplier] at least 1, and
  /// [jitter] between 0 and 1.
  const RetryPolicy({
    this.maxRetries = 2,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 8),
    this.multiplier = 2,
    this.jitter = 0.2,
    this.respectRetryAfter = true,
  }) : assert(maxRetries >= 0),
       assert(multiplier >= 1),
       assert(jitter >= 0 && jitter <= 1);

  /// No retries. The router fails over at the first failure.
  static const RetryPolicy none = RetryPolicy(maxRetries: 0);

  /// Retries after the first try of each provider. Zero disables retries.
  final int maxRetries;

  /// Wait before the first retry, before jitter.
  final Duration initialDelay;

  /// Longest wait before any retry.
  final Duration maxDelay;

  /// Growth factor between consecutive waits.
  final double multiplier;

  /// Random variation as a fraction of the wait, from 0 (none) to 1.
  final double jitter;

  /// Whether a provider's `Retry-After` replaces the computed wait.
  final bool respectRetryAfter;

  /// Whether [failure] is transient enough to retry the same provider.
  bool shouldRetry(LlmRouterException failure) {
    if (failure is! RetryableLlmException) return false;
    if (failure is ProviderUnavailableLlmException) return false;
    final status = failure.statusCode;
    if (status != null && failure.cause == null) {
      return status == 408 || status == 429 || (status >= 500 && status < 600);
    }
    final cause = failure.cause;
    return cause is Exception && cause is! FormatException;
  }

  /// The wait before retry [retry] (0 for the first), or null when the
  /// router should fail over instead.
  ///
  /// [random] supplies jitter and defaults to a shared [Random].
  Duration? delayFor(int retry, LlmRouterException failure, {Random? random}) {
    if (retry >= maxRetries) return null;
    if (respectRetryAfter && failure is RetryableLlmException) {
      final retryAfter = failure.retryAfter;
      if (retryAfter != null) {
        return retryAfter > maxDelay ? null : retryAfter;
      }
    }
    final base = initialDelay.inMicroseconds * pow(multiplier, retry);
    final capped = min(base.toDouble(), maxDelay.inMicroseconds.toDouble());
    final spread = jitter == 0
        ? 0.0
        : ((random ?? _random).nextDouble() * 2 - 1) * jitter * capped;
    return Duration(microseconds: max(0, (capped + spread).round()));
  }

  static final Random _random = Random();
}
