import '../models/attempt_log.dart';

/// Failure raised by the router or one of its streaming adapters.
///
/// Subclasses distinguish transient failures, which another provider may
/// survive, from failures that should stop the chain.
abstract class LlmRouterException implements Exception {
  /// Creates an exception with a human-readable [message].
  ///
  /// [statusCode] is the HTTP status when the failure came from a response.
  /// [cause] is the underlying error, when there is one. [redactedMessage]
  /// is [message] without provider-supplied text; see [redactedMessage].
  const LlmRouterException(
    this.message, {
    this.statusCode,
    this.cause,
    String? redactedMessage,
  }) : _redactedMessage = redactedMessage;

  /// Human-readable description of the failure.
  ///
  /// It can include text from the provider's error response, which may echo
  /// part of the prompt.
  final String message;

  final String? _redactedMessage;

  /// [message] without text from the provider's response or from an
  /// underlying error, safe to send to telemetry.
  ///
  /// Built-in adapters set it, for example `HTTP 429` for an error response.
  /// When it was not set, it falls back to [message].
  String get redactedMessage => _redactedMessage ?? message;

  /// HTTP status associated with this failure, when the transport provided one.
  final int? statusCode;

  /// Underlying error that triggered this exception, when there is one.
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// Transient failure. The router should try the next provider.
///
/// Typical causes are HTTP 429, HTTP 503, request timeouts, and dropped
/// sockets.
class RetryableLlmException extends LlmRouterException {
  /// Creates a retryable failure.
  ///
  /// [retryAfter] is how long the provider asked callers to wait, from a
  /// `Retry-After` or `retry-after-ms` response header.
  const RetryableLlmException(
    super.message, {
    super.statusCode,
    super.cause,
    super.redactedMessage,
    this.retryAfter,
  });

  /// Wait the provider asked for before the next request, when it sent one.
  ///
  /// `RetryPolicy` honours it when retrying the same provider.
  final Duration? retryAfter;
}

/// This provider cannot serve requests, but another provider may.
///
/// Typical causes are an invalid or revoked key (HTTP 401), exhausted credit
/// (HTTP 402), a key without access (HTTP 403), and an unknown or retired
/// model (HTTP 404). The router tries the next provider. Retrying the same
/// provider will not help.
class ProviderUnavailableLlmException extends RetryableLlmException {
  /// Creates a failure scoped to one provider.
  const ProviderUnavailableLlmException(
    super.message, {
    super.statusCode,
    super.cause,
    super.redactedMessage,
  });
}

/// A reply to `RouterLlmProvider.generateObject` was not valid JSON, or the
/// decoder rejected it.
///
/// The router fails over to the next provider.
class InvalidStructuredOutputException extends RetryableLlmException {
  /// Creates a structured output failure. [cause] is the parse or decode
  /// error.
  const InvalidStructuredOutputException(
    super.message, {
    super.cause,
    super.redactedMessage,
  });
}

/// Permanent failure for this request. Retrying the same call will not help.
///
/// Typical causes are HTTP 400 invalid prompts, which every provider would
/// reject the same way. When the conversation has image, PDF, audio, or video
/// attachments, the router treats an HTTP 400 as provider-scoped instead,
/// because the model may not accept that media.
class TerminalLlmException extends LlmRouterException {
  /// Creates a terminal failure.
  const TerminalLlmException(
    super.message, {
    super.statusCode,
    super.cause,
    super.redactedMessage,
  });
}

/// A `BudgetPolicy` limit was reached and no provider within budget remained.
///
/// The router throws it before calling any provider, so nothing was spent on
/// this request.
class BudgetExceededException extends LlmRouterException {
  /// Creates a budget failure that retains the [attempts] records, which are
  /// the providers skipped for budget or other reasons.
  BudgetExceededException(
    List<AttemptLog> attempts, {
    required this.spentUsd,
    String message = 'Budget exceeded: no provider within budget remains',
  }) : attempts = List<AttemptLog>.unmodifiable(attempts),
       super(message);

  /// Attempt records, one per provider the router skipped.
  final List<AttemptLog> attempts;

  /// `CostTracker.totalCost` when the request was refused.
  final double spentUsd;
}

/// A provider connection failed and a connectivity probe confirmed the
/// device is offline, so the router stopped instead of failing over.
///
/// [toString] returns only [message], so UI that displays the error as text
/// (such as `LlmChatView`'s default error dialog) shows a readable sentence.
class NoInternetConnectionException extends LlmRouterException {
  /// Creates an offline failure that retains the [attempts] made so far.
  ///
  /// [cause] is the provider failure that triggered the connectivity probe.
  NoInternetConnectionException(
    List<AttemptLog> attempts, {
    String message = defaultMessage,
    super.cause,
  }) : attempts = List<AttemptLog>.unmodifiable(attempts),
       super(message);

  /// Message used when none is given.
  ///
  /// `LlmChatView` passes `onErrorCallback` an `LlmFailureException` whose
  /// message is this exception's [toString], so apps can compare against this
  /// constant to recognize the offline case.
  static const String defaultMessage =
      'No internet connection. Please check your network and try again.';

  /// Attempt records in the order the providers were called.
  final List<AttemptLog> attempts;

  @override
  String toString() => message;
}

/// Every configured provider failed before a response was produced.
class AllProvidersFailedException extends LlmRouterException {
  /// Creates an exception that retains each provider [attempts] record.
  ///
  /// [attempts] is stored unmodifiable. [message] defaults to a summary that
  /// includes the attempt count.
  AllProvidersFailedException(List<AttemptLog> attempts, {String? message})
    : attempts = List<AttemptLog>.unmodifiable(attempts),
      super(message ?? 'All providers failed (${attempts.length} attempts)');

  /// Attempt records in the order the providers were called.
  final List<AttemptLog> attempts;

  @override
  String toString() => '${super.toString()} attempts=${attempts.length}';
}
