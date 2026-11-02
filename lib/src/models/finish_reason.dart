/// Why a provider stopped generating, normalised across vendors.
enum FinishReason {
  /// The model finished, or hit a stop sequence.
  stop,

  /// The reply hit `ProviderConfig.maxOutputTokens` and is truncated.
  length,

  /// A safety or content filter stopped or blocked the reply.
  contentFilter,

  /// The model asked to call a tool.
  toolCall,

  /// Any other vendor reason.
  other;

  /// Maps an OpenAI-compatible `finish_reason`, or returns null when absent.
  static FinishReason? fromOpenAi(Object? value) {
    return switch (value) {
      null => null,
      'stop' => FinishReason.stop,
      'length' => FinishReason.length,
      'content_filter' => FinishReason.contentFilter,
      'tool_calls' || 'function_call' => FinishReason.toolCall,
      _ => FinishReason.other,
    };
  }

  /// Maps an Anthropic `stop_reason`, or returns null when absent.
  static FinishReason? fromAnthropic(Object? value) {
    return switch (value) {
      null => null,
      'end_turn' || 'stop_sequence' => FinishReason.stop,
      'max_tokens' => FinishReason.length,
      'refusal' => FinishReason.contentFilter,
      'tool_use' => FinishReason.toolCall,
      _ => FinishReason.other,
    };
  }

  /// Maps a Gemini `finishReason`, or returns null when absent.
  static FinishReason? fromGemini(Object? value) {
    return switch (value) {
      null || 'FINISH_REASON_UNSPECIFIED' => null,
      'STOP' => FinishReason.stop,
      'MAX_TOKENS' => FinishReason.length,
      'SAFETY' ||
      'RECITATION' ||
      'BLOCKLIST' ||
      'PROHIBITED_CONTENT' ||
      'SPII' ||
      'IMAGE_SAFETY' => FinishReason.contentFilter,
      'MALFORMED_FUNCTION_CALL' ||
      'UNEXPECTED_TOOL_CALL' => FinishReason.toolCall,
      _ => FinishReason.other,
    };
  }
}
