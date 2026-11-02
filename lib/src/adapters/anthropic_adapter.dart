import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/finish_reason.dart';
import '../models/provider_capabilities.dart';
import '../models/provider_config.dart';
import '../models/tool.dart';
import '../models/turn_attachment.dart';
import 'base_adapter.dart';

/// Streams Anthropic Messages Server-Sent Events.
///
/// Text is taken from `content_block_delta` events whose delta type is
/// `text_delta`. An `error` event, such as `overloaded_error`, throws a
/// retryable failure. `stop_reason` is reported as an [AdapterFinish]. Other
/// event types are ignored. Requests send [ProviderConfig.maxOutputTokens]
/// as `max_tokens`, which the Messages API requires, and the system prompt
/// as the top-level `system` field. Images are sent as `image` blocks and
/// PDFs as `document` blocks.
///
/// Web builds send `anthropic-dangerous-direct-browser-access`, which the
/// API needs before it accepts a browser (CORS) request.
class AnthropicAdapter extends BaseLlmAdapter {
  /// Creates an Anthropic adapter.
  ///
  /// [client] is optional; see [BaseLlmAdapter].
  AnthropicAdapter({super.client});

  static const _defaultBase = 'https://api.anthropic.com/v1';
  static const _isWeb = bool.fromEnvironment('dart.library.js_interop');

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    <AttachmentKind>{AttachmentKind.image, AttachmentKind.pdf},
  );

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    final settings = config.settings;
    final payloads = postSse(
      url: resolveProviderUrl(config.baseUrl, _defaultBase, 'messages'),
      headers: <String, String>{
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        if (_isWeb) 'anthropic-dangerous-direct-browser-access': 'true',
        ...config.headers,
      },
      body: <String, Object?>{
        'model': config.model,
        'max_tokens': config.maxOutputTokens,
        'stream': true,
        if (settings.hasSystemPrompt) 'system': settings.systemPrompt,
        'temperature': ?settings.temperature,
        'top_p': ?settings.topP,
        if (settings.hasStopSequences) 'stop_sequences': settings.stopSequences,
        if (settings.hasTools)
          'tools': <Object?>[
            for (final tool in settings.tools!)
              <String, Object?>{
                'name': tool.name,
                'description': tool.description,
                'input_schema': tool.parameters,
              },
          ],
        'messages': <Object?>[
          for (final message in messages) message.toAnthropicMessage(),
        ],
      },
      timeout: config.timeout,
      idleTimeout: config.idleTimeout,
      deadline: config.deadline,
    );
    final calls = <int, _PartialToolUse>{};
    return payloads.expand((payload) => _chunks(payload, calls));
  }

  /// Also treats a 400 for low credit balance as provider-scoped.
  @override
  bool isProviderScopedFailure(int statusCode, String body) {
    return super.isProviderScopedFailure(statusCode, body) ||
        (statusCode == 400 && body.contains('credit balance'));
  }

  List<AdapterChunk> _chunks(String payload, Map<int, _PartialToolUse> calls) {
    final json = decodeSseObject(payload);
    if (json['type'] == 'error') {
      final error = json['error'];
      final overloaded =
          error is Map<String, dynamic> && error['type'] == 'overloaded_error';
      throwStreamError(error, statusCode: overloaded ? 529 : null);
    }
    final usage = _usage(json);
    final text = _deltaText(json);
    final toolCall = _toolUse(json, calls);
    final finish = _finish(json);
    return <AdapterChunk>[
      ?usage,
      if (text != null) AdapterText(text),
      ?toolCall,
      ?finish,
    ];
  }

  /// Tracks `tool_use` blocks and returns a call when its block stops.
  AdapterToolCall? _toolUse(
    Map<String, dynamic> json,
    Map<int, _PartialToolUse> calls,
  ) {
    final index = json['index'];
    if (index is! int) return null;
    switch (json['type']) {
      case 'content_block_start':
        final block = json['content_block'];
        if (block is Map<String, dynamic> && block['type'] == 'tool_use') {
          calls[index] = _PartialToolUse(
            id: block['id'] as String? ?? 'toolu_$index',
            name: block['name'] as String? ?? '',
          );
        }
      case 'content_block_delta':
        final delta = json['delta'];
        final call = calls[index];
        if (call != null &&
            delta is Map<String, dynamic> &&
            delta['type'] == 'input_json_delta' &&
            delta['partial_json'] is String) {
          call.input.write(delta['partial_json'] as String);
        }
      case 'content_block_stop':
        final call = calls.remove(index);
        if (call == null) return null;
        return AdapterToolCall(
          ToolCall(
            id: call.id,
            name: call.name,
            arguments: decodeToolArguments(call.input.toString()),
          ),
        );
    }
    return null;
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
      // Anthropic reports cache reads and writes apart from input_tokens.
      final cacheRead = AdapterUsage.count(usage['cache_read_input_tokens']);
      final cacheWrite = AdapterUsage.count(
        usage['cache_creation_input_tokens'],
      );
      return AdapterUsage(
        inputTokens: input + (cacheRead ?? 0) + (cacheWrite ?? 0),
        cachedInputTokens: cacheRead,
      );
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

  AdapterFinish? _finish(Map<String, dynamic> json) {
    if (json['type'] != 'message_delta') return null;
    final delta = json['delta'];
    if (delta is! Map<String, dynamic>) return null;
    final reason = FinishReason.fromAnthropic(delta['stop_reason']);
    return reason == null ? null : AdapterFinish(reason);
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

/// A `tool_use` block whose input is still streaming in.
class _PartialToolUse {
  _PartialToolUse({required this.id, required this.name});

  final String id;
  final String name;
  final StringBuffer input = StringBuffer();
}
