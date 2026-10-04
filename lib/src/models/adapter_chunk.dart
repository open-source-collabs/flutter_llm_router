/// One event from a provider stream.
///
/// Adapters yield [AdapterText] for visible tokens and [AdapterUsage] when
/// the provider reports a token count. The router shows only the text.
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
  /// [inputTokens] and [outputTokens] must be zero or positive when present.
  const AdapterUsage({this.inputTokens, this.outputTokens})
      : assert(inputTokens == null || inputTokens >= 0),
        assert(outputTokens == null || outputTokens >= 0);

  /// Prompt tokens, when this event includes them.
  final int? inputTokens;

  /// Completion tokens, when this event includes them.
  final int? outputTokens;

  /// Reads a non-negative token count from JSON, or returns null.
  static int? count(Object? value) {
    if (value is int && value >= 0) return value;
    if (value is num && value >= 0) return value.toInt();
    return null;
  }
}
