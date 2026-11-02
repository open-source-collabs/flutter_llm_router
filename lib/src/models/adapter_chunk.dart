import 'finish_reason.dart';
import 'tool.dart';

/// One event from a provider stream.
///
/// Adapters yield [AdapterText] for visible tokens, [AdapterUsage] when the
/// provider reports a token count, [AdapterFinish] when it says why it
/// stopped, and [AdapterToolCall] when the model calls a tool. The router
/// shows only the text.
sealed class AdapterChunk {
  /// Creates a stream event.
  const AdapterChunk();
}

/// A visible text fragment from the provider.
final class AdapterText extends AdapterChunk {
  /// Creates a text fragment.
  const AdapterText(this.text);

  /// Characters to append to the assistant reply.
  final String text;
}

/// Token counts reported by the provider.
///
/// Either count may be omitted when that side of the usage object has not
/// arrived yet. A later event replaces the side it includes.
final class AdapterUsage extends AdapterChunk {
  /// Creates a usage report.
  ///
  /// Counts must be zero or positive when present. [cachedInputTokens] is
  /// the part of [inputTokens] served from the provider's prompt cache.
  const AdapterUsage({
    this.inputTokens,
    this.outputTokens,
    this.cachedInputTokens,
  }) : assert(inputTokens == null || inputTokens >= 0),
       assert(outputTokens == null || outputTokens >= 0),
       assert(cachedInputTokens == null || cachedInputTokens >= 0);

  /// Prompt tokens, including cached ones, when this event includes them.
  final int? inputTokens;

  /// Completion tokens, including thinking tokens, when this event includes
  /// them.
  final int? outputTokens;

  /// Prompt tokens read from the provider's cache, when reported.
  final int? cachedInputTokens;

  /// Reads a non-negative token count from JSON, or returns null.
  static int? count(Object? value) {
    if (value is int && value >= 0) return value;
    if (value is num && value >= 0) return value.toInt();
    return null;
  }
}

/// The provider's reason for ending the reply.
final class AdapterFinish extends AdapterChunk {
  /// Creates a finish event.
  const AdapterFinish(this.reason);

  /// Normalised stop reason.
  final FinishReason reason;
}

/// A complete tool call from the provider.
///
/// Adapters assemble streamed argument fragments and yield one
/// [AdapterToolCall] per call once its arguments are complete.
final class AdapterToolCall extends AdapterChunk {
  /// Creates a tool call event.
  const AdapterToolCall(this.call);

  /// The call to run.
  final ToolCall call;
}
