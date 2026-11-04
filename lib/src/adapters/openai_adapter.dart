import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/finish_reason.dart';
import '../models/provider_capabilities.dart';
import '../models/provider_config.dart';
import '../models/tool.dart';
import '../models/turn_attachment.dart';
import 'base_adapter.dart';

/// Streams OpenAI chat-completions Server-Sent Events.
///
/// Each yielded string is one `choices[0].delta.content` fragment. Role
/// chunks and the `[DONE]` sentinel produce no text. An `error` object in
/// the stream throws a retryable failure. `finish_reason` is reported as an
/// [AdapterFinish].
///
/// Requests to `api.openai.com` send [ProviderConfig.maxOutputTokens] as
/// `max_completion_tokens`, which newer models require. Other
/// OpenAI-compatible hosts receive `max_tokens`. The system prompt is sent
/// as a leading `system` message. Images are sent as `image_url` parts and
/// PDFs as `file` parts.
///
/// Subclasses for other OpenAI-compatible hosts override [chatUrl],
/// [authHeaders], and [maxTokensField].
class OpenAiAdapter extends BaseLlmAdapter {
  /// Creates an OpenAI adapter.
  ///
  /// [client] is optional; see [BaseLlmAdapter].
  OpenAiAdapter({super.client});

  static const _defaultBase = 'https://api.openai.com/v1';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    <AttachmentKind>{AttachmentKind.image, AttachmentKind.pdf},
  );

  /// The chat-completions URL for [config].
  Uri chatUrl(ProviderConfig config) {
    return resolveProviderUrl(config.baseUrl, _defaultBase, 'chat/completions');
  }

  /// Headers that authenticate a request for [config].
  Map<String, String> authHeaders(ProviderConfig config) {
    return <String, String>{'authorization': 'Bearer ${config.apiKey}'};
  }

  /// The request field that carries the completion cap for [url].
  String maxTokensField(Uri url) {
    return url.host == 'api.openai.com'
        ? 'max_completion_tokens'
        : 'max_tokens';
  }

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    final url = chatUrl(config);
    final settings = config.settings;

    final payloads = postSse(
      url: url,
      headers: <String, String>{
        ...authHeaders(config),
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        ...config.headers,
      },
      body: <String, Object?>{
        'model': config.model,
        'stream': true,
        if (config.requestStreamUsage)
          'stream_options': <String, Object?>{'include_usage': true},
        maxTokensField(url): config.maxOutputTokens,
        'temperature': ?settings.temperature,
        'top_p': ?settings.topP,
        if (settings.hasStopSequences) 'stop': settings.stopSequences,
        if (settings.hasTools)
          'tools': <Object?>[
            for (final tool in settings.tools!)
              <String, Object?>{
                'type': 'function',
                'function': <String, Object?>{
                  'name': tool.name,
                  'description': tool.description,
                  'parameters': tool.parameters,
                },
              },
          ],
        if (settings.responseSchema case final schema?)
          'response_format': <String, Object?>{
            'type': 'json_schema',
            'json_schema': <String, Object?>{
              'name': schema.name,
              'description': ?schema.description,
              'schema': schema.schema,
              'strict': schema.strict,
            },
          },
        'messages': <Object?>[
          if (settings.hasSystemPrompt)
            <String, Object?>{
              'role': 'system',
              'content': settings.systemPrompt,
            },
          for (final message in messages) ...message.toOpenAiMessages(),
        ],
      },
      timeout: config.timeout,
      idleTimeout: config.idleTimeout,
      deadline: config.deadline,
    );
    return _decode(payloads);
  }

  Stream<AdapterChunk> _decode(Stream<String> payloads) async* {
    final calls = <int, _PartialCall>{};
    await for (final payload in payloads) {
      yield* Stream<AdapterChunk>.fromIterable(_chunks(payload, calls));
    }
    yield* Stream<AdapterChunk>.fromIterable(_flush(calls));
  }

  List<AdapterChunk> _chunks(String payload, Map<int, _PartialCall> calls) {
    final json = decodeSseObject(payload);
    final error = json['error'];
    if (error != null) throwStreamError(error);
    final usage = _usage(json);
    final choice = _firstChoice(json);
    final text = _deltaText(choice);
    _collectToolCalls(choice, calls);
    final finish = FinishReason.fromOpenAi(choice?['finish_reason']);
    return <AdapterChunk>[
      ?usage,
      if (text != null) AdapterText(text),
      if (finish != null) ..._flush(calls),
      if (finish != null) AdapterFinish(finish),
    ];
  }

  /// Appends streamed `tool_calls` fragments, keyed by their index.
  void _collectToolCalls(
    Map<String, dynamic>? choice,
    Map<int, _PartialCall> calls,
  ) {
    final delta = choice?['delta'];
    if (delta is! Map<String, dynamic>) return;
    final fragments = delta['tool_calls'];
    if (fragments is! List<dynamic>) return;
    for (final fragment in fragments) {
      if (fragment is! Map<String, dynamic>) continue;
      final index = fragment['index'] is int
          ? fragment['index'] as int
          : calls.length;
      final call = calls.putIfAbsent(index, _PartialCall.new);
      if (fragment['id'] case final String id) call.id = id;
      final function = fragment['function'];
      if (function is! Map<String, dynamic>) continue;
      if (function['name'] case final String name) call.name += name;
      if (function['arguments'] case final String arguments) {
        call.arguments.write(arguments);
      }
    }
  }

  /// Yields the collected tool calls, in index order, and clears them.
  List<AdapterChunk> _flush(Map<int, _PartialCall> calls) {
    if (calls.isEmpty) return const <AdapterChunk>[];
    final indexes = calls.keys.toList()..sort();
    final chunks = <AdapterChunk>[
      for (final index in indexes)
        AdapterToolCall(
          ToolCall(
            id: calls[index]!.id ?? 'call_$index',
            name: calls[index]!.name,
            arguments: decodeToolArguments(calls[index]!.arguments.toString()),
          ),
        ),
    ];
    calls.clear();
    return chunks;
  }

  AdapterUsage? _usage(Map<String, dynamic> json) {
    var usage = json['usage'];
    if (usage is! Map<String, dynamic>) {
      // Groq reports usage under `x_groq` instead.
      final groq = json['x_groq'];
      usage = groq is Map<String, dynamic> ? groq['usage'] : null;
    }
    if (usage is! Map<String, dynamic>) return null;
    final input = AdapterUsage.count(usage['prompt_tokens']);
    final output = AdapterUsage.count(usage['completion_tokens']);
    final details = usage['prompt_tokens_details'];
    final cached = details is Map<String, dynamic>
        ? AdapterUsage.count(details['cached_tokens'])
        : AdapterUsage.count(usage['prompt_cache_hit_tokens']);
    if (input == null && output == null) return null;
    return AdapterUsage(
      inputTokens: input,
      outputTokens: output,
      cachedInputTokens: cached,
    );
  }

  Map<String, dynamic>? _firstChoice(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List<dynamic> || choices.isEmpty) return null;
    final choice = choices.first;
    return choice is Map<String, dynamic> ? choice : null;
  }

  String? _deltaText(Map<String, dynamic>? choice) {
    final delta = choice?['delta'];
    if (delta is! Map<String, dynamic>) return null;
    final content = delta['content'];
    if (content is! String || content.isEmpty) return null;
    return content;
  }
}

/// A tool call whose fields are still streaming in.
class _PartialCall {
  String? id;
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
