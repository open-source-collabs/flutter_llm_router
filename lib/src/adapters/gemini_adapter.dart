import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/provider_config.dart';
import 'base_adapter.dart';

/// Streams Gemini `streamGenerateContent` Server-Sent Events.
///
/// Text is taken from each candidate part. The API key is sent in the
/// `x-goog-api-key` header. [ProviderConfig.maxOutputTokens] is sent as
/// `generationConfig.maxOutputTokens`.
class GeminiAdapter extends BaseLlmAdapter {
  /// Creates a Gemini adapter.
  ///
  /// [client] is optional; see [BaseLlmAdapter].
  GeminiAdapter({super.client});

  static const _defaultBase =
      'https://generativelanguage.googleapis.com/v1beta';

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) async* {
    final endpoint = resolveProviderUrl(
      config.baseUrl,
      _defaultBase,
      'models/${Uri.encodeComponent(config.model)}:streamGenerateContent',
    ).replace(queryParameters: const <String, String>{'alt': 'sse'});

    final payloads = postSse(
      url: endpoint,
      headers: <String, String>{
        'x-goog-api-key': config.apiKey,
        'content-type': 'application/json',
        'accept': 'text/event-stream',
      },
      body: <String, Object?>{
        'generationConfig': <String, Object?>{
          'maxOutputTokens': config.maxOutputTokens,
        },
        'contents': <Object?>[
          for (final message in messages) message.toGeminiContent(),
        ],
      },
      timeout: config.timeout,
    );

    await for (final payload in payloads) {
      final json = decodeSseObject(payload);
      final usage = _usage(json);
      if (usage != null) yield usage;
      final text = _partText(json);
      if (text != null) yield AdapterText(text);
    }
  }

  AdapterUsage? _usage(Map<String, dynamic> json) {
    final usage = json['usageMetadata'];
    if (usage is! Map<String, dynamic>) return null;
    final input = AdapterUsage.count(usage['promptTokenCount']);
    final output = AdapterUsage.count(usage['candidatesTokenCount']);
    if (input == null && output == null) return null;
    return AdapterUsage(inputTokens: input, outputTokens: output);
  }

  String? _partText(Map<String, dynamic> json) {
    final candidates = json['candidates'];
    if (candidates is! List<dynamic> || candidates.isEmpty) return null;
    final buffer = StringBuffer();
    for (final candidate in candidates) {
      if (candidate is! Map<String, dynamic>) continue;
      final content = candidate['content'];
      if (content is! Map<String, dynamic>) continue;
      final parts = content['parts'];
      if (parts is! List<dynamic>) continue;
      for (final part in parts) {
        if (part is! Map<String, dynamic>) continue;
        final text = part['text'];
        if (text is String && text.isNotEmpty) buffer.write(text);
      }
    }
    if (buffer.isEmpty) return null;
    return buffer.toString();
  }
}