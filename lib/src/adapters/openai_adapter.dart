import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/provider_config.dart';
import 'base_adapter.dart';

/// Streams OpenAI chat-completions Server-Sent Events.
///
/// Each yielded string is one `choices[0].delta.content` fragment. Role
/// chunks and the `[DONE]` sentinel produce no text.
class OpenAiAdapter extends BaseLlmAdapter {
  /// Creates an OpenAI adapter.
  ///
  /// [client] is optional; see [BaseLlmAdapter].
  OpenAiAdapter({super.client});

  static const _defaultBase = 'https://api.openai.com/v1';

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) async* {
    final payloads = postSse(
      url: resolveProviderUrl(
        config.baseUrl,
        _defaultBase,
        'chat/completions',
      ),
      headers: <String, String>{
        'authorization': 'Bearer ${config.apiKey}',
        'content-type': 'application/json',
        'accept': 'text/event-stream',
      },
      body: <String, Object?>{
        'model': config.model,
        'stream': true,
        'stream_options': <String, Object?>{'include_usage': true},
        'max_tokens': config.maxOutputTokens,
        'messages': <Object?>[
          for (final message in messages) message.toOpenAiMessage(),
        ],
      },
      timeout: config.timeout,
    );

    await for (final payload in payloads) {
      final json = decodeSseObject(payload);
      final usage = _usage(json);
      if (usage != null) yield usage;
      final text = _deltaText(json);
      if (text != null) yield AdapterText(text);
    }
  }

  AdapterUsage? _usage(Map<String, dynamic> json) {
    final usage = json['usage'];
    if (usage is! Map<String, dynamic>) return null;
    final input = AdapterUsage.count(usage['prompt_tokens']);
    final output = AdapterUsage.count(usage['completion_tokens']);
    if (input == null && output == null) return null;
    return AdapterUsage(inputTokens: input, outputTokens: output);
  }

  String? _deltaText(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List<dynamic> || choices.isEmpty) return null;
    final choice = choices.first;
    if (choice is! Map<String, dynamic>) return null;
    final delta = choice['delta'];
    if (delta is! Map<String, dynamic>) return null;
    final content = delta['content'];
    if (content is! String || content.isEmpty) return null;
    return content;
  }
}
