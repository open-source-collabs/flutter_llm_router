import '../exceptions/router_exceptions.dart';
import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/finish_reason.dart';
import '../models/provider_capabilities.dart';
import '../models/provider_config.dart';
import '../models/tool.dart';
import '../models/turn_attachment.dart';
import 'base_adapter.dart';

/// Streams Gemini `streamGenerateContent` Server-Sent Events.
///
/// Text is taken from each candidate part. The API key is sent in the
/// `x-goog-api-key` header. [ProviderConfig.maxOutputTokens] is sent as
/// `generationConfig.maxOutputTokens` and the system prompt as
/// `systemInstruction`. Images, PDFs, audio, and video are sent as
/// `inlineData`. An `error` object or a blocked prompt throws a retryable
/// failure. `finishReason` is reported as an [AdapterFinish]. Thinking
/// tokens count as output tokens.
class GeminiAdapter extends BaseLlmAdapter {
  /// Creates a Gemini adapter.
  ///
  /// [client] is optional; see [BaseLlmAdapter].
  GeminiAdapter({super.client});

  static const _defaultBase =
      'https://generativelanguage.googleapis.com/v1beta';

  @override
  ProviderCapabilities get capabilities =>
      const ProviderCapabilities(<AttachmentKind>{
        AttachmentKind.image,
        AttachmentKind.pdf,
        AttachmentKind.audio,
        AttachmentKind.video,
      });

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    final endpoint = resolveProviderUrl(
      config.baseUrl,
      _defaultBase,
      'models/${Uri.encodeComponent(config.model)}:streamGenerateContent',
    ).replace(queryParameters: const <String, String>{'alt': 'sse'});
    final settings = config.settings;

    final payloads = postSse(
      url: endpoint,
      headers: <String, String>{
        'x-goog-api-key': config.apiKey,
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        ...config.headers,
      },
      body: <String, Object?>{
        if (settings.hasSystemPrompt)
          'systemInstruction': <String, Object?>{
            'parts': <Object?>[
              <String, Object?>{'text': settings.systemPrompt},
            ],
          },
        'generationConfig': <String, Object?>{
          'maxOutputTokens': config.maxOutputTokens,
          'temperature': ?settings.temperature,
          'topP': ?settings.topP,
          if (settings.hasStopSequences)
            'stopSequences': settings.stopSequences,
          if (settings.responseSchema != null)
            'responseMimeType': 'application/json',
        },
        if (settings.hasTools)
          'tools': <Object?>[
            <String, Object?>{
              'functionDeclarations': <Object?>[
                for (final tool in settings.tools!)
                  <String, Object?>{
                    'name': tool.name,
                    'description': tool.description,
                    'parameters': tool.parameters,
                  },
              ],
            },
          ],
        'contents': <Object?>[
          for (final message in messages) message.toGeminiContent(),
        ],
      },
      timeout: config.timeout,
      idleTimeout: config.idleTimeout,
      deadline: config.deadline,
    );
    var callCount = 0;
    return payloads.expand(
      (payload) => _chunks(payload, () => 'gemini_call_${callCount++}'),
    );
  }

  /// Also treats Gemini's HTTP 400 `API_KEY_INVALID` as provider-scoped.
  @override
  bool isProviderScopedFailure(int statusCode, String body) {
    return super.isProviderScopedFailure(statusCode, body) ||
        (statusCode == 400 && body.contains('API_KEY_INVALID'));
  }

  List<AdapterChunk> _chunks(String payload, String Function() nextCallId) {
    final json = decodeSseObject(payload);
    final error = json['error'];
    if (error != null) throwStreamError(error);
    final feedback = json['promptFeedback'];
    if (feedback is Map<String, dynamic> && feedback['blockReason'] != null) {
      throwStreamError('Gemini blocked the prompt: ${feedback['blockReason']}');
    }
    final usage = _usage(json);
    final text = _partText(json);
    final calls = _functionCalls(json, nextCallId);
    final finish = _finish(json);
    return <AdapterChunk>[
      ?usage,
      if (text != null) AdapterText(text),
      ...calls,
      ?finish,
    ];
  }

  /// Reads `functionCall` parts, which Gemini sends whole, keeping each
  /// part's `thoughtSignature` so it can be sent back.
  List<AdapterToolCall> _functionCalls(
    Map<String, dynamic> json,
    String Function() nextCallId,
  ) {
    final candidates = json['candidates'];
    if (candidates is! List<dynamic> || candidates.isEmpty) {
      return const <AdapterToolCall>[];
    }
    final candidate = candidates.first;
    if (candidate is! Map<String, dynamic>) return const <AdapterToolCall>[];
    final content = candidate['content'];
    if (content is! Map<String, dynamic>) return const <AdapterToolCall>[];
    final parts = content['parts'];
    if (parts is! List<dynamic>) return const <AdapterToolCall>[];
    return <AdapterToolCall>[
      for (final part in parts)
        if (part is Map<String, dynamic> &&
            part['functionCall'] is Map<String, dynamic>)
          _functionCall(
            part['functionCall'] as Map<String, dynamic>,
            part['thoughtSignature'],
            nextCallId,
          ),
    ];
  }

  AdapterToolCall _functionCall(
    Map<String, dynamic> call,
    Object? signature,
    String Function() nextCallId,
  ) {
    final args = call['args'];
    if (args != null && args is! Map<String, dynamic>) {
      throw const RetryableLlmException(
        'Tool call arguments were not a JSON object',
      );
    }
    final vendorId = call['id'];
    return AdapterToolCall(
      ToolCall(
        id: vendorId is String ? vendorId : nextCallId(),
        name: call['name'] as String? ?? '',
        arguments: (args as Map<String, dynamic>?) ?? <String, Object?>{},
        providerData: <String, Object?>{
          if (vendorId is String) 'geminiCallId': vendorId,
          if (signature is String) 'thoughtSignature': signature,
        },
      ),
    );
  }

  AdapterUsage? _usage(Map<String, dynamic> json) {
    final usage = json['usageMetadata'];
    if (usage is! Map<String, dynamic>) return null;
    final input = AdapterUsage.count(usage['promptTokenCount']);
    final candidates = AdapterUsage.count(usage['candidatesTokenCount']);
    final thoughts = AdapterUsage.count(usage['thoughtsTokenCount']);
    final cached = AdapterUsage.count(usage['cachedContentTokenCount']);
    final output = candidates == null && thoughts == null
        ? null
        : (candidates ?? 0) + (thoughts ?? 0);
    if (input == null && output == null) return null;
    return AdapterUsage(
      inputTokens: input,
      outputTokens: output,
      cachedInputTokens: cached,
    );
  }

  AdapterFinish? _finish(Map<String, dynamic> json) {
    final candidates = json['candidates'];
    if (candidates is! List<dynamic> || candidates.isEmpty) return null;
    final candidate = candidates.first;
    if (candidate is! Map<String, dynamic>) return null;
    final reason = FinishReason.fromGemini(candidate['finishReason']);
    return reason == null ? null : AdapterFinish(reason);
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
        if (part['thought'] == true) continue;
        final text = part['text'];
        if (text is String && text.isNotEmpty) buffer.write(text);
      }
    }
    if (buffer.isEmpty) return null;
    return buffer.toString();
  }
}
