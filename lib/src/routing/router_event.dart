import '../models/attempt_log.dart';
import 'provider_health.dart';

/// Something that happened while the router served a request.
///
/// Listen to `RouterLlmProvider.events` to feed logging, analytics, or
/// tracing such as Sentry, Firebase, or OpenTelemetry. Every event of one
/// request shares [requestId]. Error text is redacted by default; see
/// `RouterLlmProvider.redactEventErrors`.
sealed class RouterEvent {
  /// Creates an event for request [requestId].
  RouterEvent(this.requestId) : timestamp = DateTime.now();

  /// Identifies the request, increasing from 1 per router. Zero for events
  /// not tied to one request.
  final int requestId;

  /// When the event happened.
  final DateTime timestamp;
}

/// A `generateStream` or `sendMessageStream` call started routing.
final class RequestStarted extends RouterEvent {
  /// Creates the event.
  RequestStarted(super.requestId, {required this.providerOrder});

  /// `ProviderConfig.id` values in the order the router will try them.
  final List<String> providerOrder;
}

/// The router is about to call a provider.
final class AttemptStarted extends RouterEvent {
  /// Creates the event.
  AttemptStarted(
    super.requestId, {
    required this.providerName,
    required this.model,
    required this.retry,
  });

  /// `ProviderConfig.name` of the provider.
  final String providerName;

  /// Model id sent.
  final String model;

  /// Zero for the first try, then 1, 2, and so on for retries.
  final int retry;
}

/// An attempt ended, was skipped, or was served from the cache.
///
/// [log] matches the entry in `RouterLlmProvider.lastAttemptLogs`, except
/// that its error is redacted when `redactEventErrors` is true.
final class AttemptFinished extends RouterEvent {
  /// Creates the event.
  AttemptFinished(super.requestId, {required this.log});

  /// The attempt record.
  final AttemptLog log;
}

/// The router will retry the same provider after [delay].
final class RetryScheduled extends RouterEvent {
  /// Creates the event.
  RetryScheduled(
    super.requestId, {
    required this.providerName,
    required this.model,
    required this.retry,
    required this.delay,
  });

  /// `ProviderConfig.name` of the provider.
  final String providerName;

  /// Model id.
  final String model;

  /// The retry about to run, starting at 1.
  final int retry;

  /// Wait before the retry.
  final Duration delay;
}

/// A provider's circuit breaker changed state.
final class CircuitStateChanged extends RouterEvent {
  /// Creates the event. [requestId] is the request whose result caused the
  /// change, or zero.
  CircuitStateChanged(
    super.requestId, {
    required this.providerId,
    required this.from,
    required this.to,
  });

  /// `ProviderConfig.id` of the provider.
  final String providerId;

  /// Previous state.
  final CircuitState from;

  /// New state.
  final CircuitState to;
}

/// Token usage was recorded in the `CostTracker`.
final class UsageRecorded extends RouterEvent {
  /// Creates the event.
  UsageRecorded(
    super.requestId, {
    required this.providerName,
    required this.model,
    required this.inputTokens,
    required this.cachedInputTokens,
    required this.outputTokens,
    required this.costUsd,
    required this.estimated,
  });

  /// `ProviderConfig.name` of the provider.
  final String providerName;

  /// Model id.
  final String model;

  /// Input tokens, including cached ones.
  final int inputTokens;

  /// Cached input tokens.
  final int cachedInputTokens;

  /// Output tokens.
  final int outputTokens;

  /// USD added to the tracker.
  final double costUsd;

  /// Whether either count was estimated from text length because the
  /// provider did not report it.
  final bool estimated;
}

/// The router ran a tool the model called.
final class ToolCallFinished extends RouterEvent {
  /// Creates the event.
  ToolCallFinished(
    super.requestId, {
    required this.toolName,
    required this.callId,
    required this.duration,
    required this.isError,
  });

  /// `ToolDefinition.name` of the tool.
  final String toolName;

  /// `ToolCall.id` of the call.
  final String callId;

  /// Time the handler took.
  final Duration duration;

  /// Whether the handler threw, or the tool was unknown.
  final bool isError;
}

/// A request ended.
final class RequestFinished extends RouterEvent {
  /// Creates the event.
  RequestFinished(
    super.requestId, {
    required this.outcome,
    required this.latency,
    this.errorType,
    this.errorMessage,
  });

  /// How the request ended.
  final RequestOutcome outcome;

  /// Time from start to end.
  final Duration latency;

  /// Runtime type of the error, when [outcome] is [RequestOutcome.failed].
  final String? errorType;

  /// Error message, redacted when `redactEventErrors` is true.
  final String? errorMessage;
}

/// How a request ended.
enum RequestOutcome {
  /// A provider or the cache produced the full reply.
  succeeded,

  /// The caller cancelled the stream, or the router was disposed.
  cancelled,

  /// The stream ended with an error.
  failed,
}
