import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/provider_config.dart';
import 'openai_adapter.dart';

/// Streams OpenRouter chat completions.
///
/// OpenRouter accepts the OpenAI chat-completions request and SSE shape.
/// The default root is [defaultBase]. [ProviderConfig.model] is an
/// OpenRouter slug such as `openai/gpt-4o-mini`. A non-null
/// [ProviderConfig.baseUrl] replaces [defaultBase].
class OpenRouterAdapter extends OpenAiAdapter {
  /// Creates an OpenRouter adapter.
  ///
  /// [client] is optional; see [OpenAiAdapter].
  OpenRouterAdapter({super.client});

  /// Default OpenRouter API root. The chat route is appended by [OpenAiAdapter].
  static const defaultBase = 'https://openrouter.ai/api/v1';

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    final resolved =
        config.baseUrl == null ? config.copyWith(baseUrl: defaultBase) : config;
    return super.streamCompletion(config: resolved, messages: messages);
  }
}
