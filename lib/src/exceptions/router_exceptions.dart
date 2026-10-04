import '../models/attempt_log.dart';

/// Failure raised by the router or one of its streaming adapters.
///
/// Subclasses distinguish transient failures, which another provider may
/// survive, from failures that should stop the chain.
abstract class LlmRouterException implements Exception {
  /// Creates an exception with a human-readable [message].
  ///
  /// [statusCode] is the HTTP status when the failure came from a response.
  /// [cause] is the underlying error, when there is one.
  const LlmRouterException(this.message, {this.statusCode, this.cause});

  /// Human-readable description of the failure.
  final String message;

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
  const RetryableLlmException(super.message, {super.statusCode, super.cause});
}

/// Permanent failure for this request. Retrying the same call will not help.
///
/// Typical causes are HTTP 401, HTTP 403, and HTTP 400 invalid prompts.
class TerminalLlmException extends LlmRouterException {
  /// Creates a terminal failure.
  const TerminalLlmException(super.message, {super.statusCode, super.cause});
}

/// Every configured provider failed before a response was produced.
class AllProvidersFailedException extends LlmRouterException {
  /// Creates an exception that retains each provider [attempts] record.
  ///
  /// [attempts] is stored unmodifiable. [message] defaults to a summary that
  /// includes the attempt count.
  AllProvidersFailedException(
    List<AttemptLog> attempts, {
    String? message,
  })  : attempts = List<AttemptLog>.unmodifiable(attempts),
        super(message ?? 'All providers failed (${attempts.length} attempts)');

  /// Attempt records in the order the providers were called.
  final List<AttemptLog> attempts;

  @override
  String toString() => '${super.toString()} attempts=${attempts.length}';
}
