/// One user or assistant turn sent to an upstream model.
enum ChatTurnRole {
  /// Text the user sent.
  user,

  /// Text an assistant already produced.
  assistant,
}

/// A single chat message in provider request order.
class ChatTurn {
  /// Creates a turn with [role] and [text].
  const ChatTurn({required this.role, required this.text});

  /// Who produced [text].
  final ChatTurnRole role;

  /// Message body sent to the provider.
  final String text;

  /// OpenAI and Anthropic message object for this turn.
  Map<String, Object?> toOpenAiMessage() {
    return <String, Object?>{
      'role': role == ChatTurnRole.user ? 'user' : 'assistant',
      'content': text,
    };
  }

  /// Gemini `contents` entry for this turn.
  ///
  /// Gemini names the assistant role `model`.
  Map<String, Object?> toGeminiContent() {
    return <String, Object?>{
      'role': role == ChatTurnRole.user ? 'user' : 'model',
      'parts': <Object?>[
        <String, Object?>{'text': text},
      ],
    };
  }
}
