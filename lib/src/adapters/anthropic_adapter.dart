import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/provider_config.dart';
import 'base_adapter.dart';

/// Streams Anthropic Messages Server-Sent Events.
///
/// Text is taken from `content_block_delta` events whose delta type is
/// `text_delta`. Other event types are ignored. Requests send
/// [ProviderConfig.maxOutputTokens] as `max_tokens`, which the Messages API
/// requires.
class AnthropicAdapter extends BaseLlmAdapter {
  /// Creates an Anthropic adapter.
  ///
  /// [client] is optional; see [BaseLlmAdapter].
  AnthropicAdapter({super.client});

  static const _defaultBase = 'https://api.anthropic.com/v1';

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) async* {
    final payloads = postSse(
      url: resolveProviderUrl(config.baseUrl, _defaultBase, 'messages'),
      headers: <String, String>{
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        'accept': 'text/event-stream',
      },
      body: <String, Object?>{
        'model': config.model,
        'max_tokens': config.maxOutputTokens,
        'stream': true,
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
    final type = json['type'];
    if (type == 'message_start') {
      final message = json['message'];
      if (message is! Map<String, dynamic>) return null;
      final usage = message['usage'];
      if (usage is! Map<String, dynamic>) return null;
      final input = AdapterUsage.count(usage['input_tokens']);
      if (input == null) return null;
      return AdapterUsage(inputTokens: input);
    }
    if (type == 'message_delta') {
      final usage = json['usage'];
      if (usage is! Map<String, dynamic>) return null;
      final output = AdapterUsage.count(usage['output_tokens']);
      if (output == null) return null;
      return AdapterUsage(outputTokens: output);
    }
    return null;
  }

  String? _deltaText(Map<String, dynamic> json) {
    if (json['type'] != 'content_block_delta') return null;
    final delta = json['delta'];
    if (delta is! Map<String, dynamic>) return null;
    if (delta['type'] != 'text_delta') return null;
    final text = delta['text'];
    if (text is! String || text.isEmpty) return null;
    return text;
  }
}
