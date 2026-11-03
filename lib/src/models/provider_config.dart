import 'generation_settings.dart';
import 'provider_capabilities.dart';
import 'turn_attachment.dart';

/// Configuration for one upstream model in the router's failover chain.
///
/// Prices are USD charged for a single token. A value of `0.000001` is one
/// micro-dollar per token. [calculateCost] multiplies those unit prices by
/// the token counts for an attempt.
///
/// Named constructors such as [ProviderConfig.ollama] and
/// [ProviderConfig.groq] preset the endpoint, adapter, and capabilities of
/// common OpenAI-compatible hosts. Use [copyWith] to change anything else.
class ProviderConfig {
  /// Creates configuration for a single upstream provider.
  ///
  /// [pricePerInputToken] and [pricePerOutputToken] must be zero or positive.
  /// [timeout] defaults to 30 seconds and [idleTimeout] to 60 seconds.
  /// [deadline] is unset by default. [maxOutputTokens] defaults to 1024 and
  /// is the completion cap sent on each attempt. [baseUrl] overrides the
  /// provider's default endpoint when it is non-null. [headers] are added to
  /// every request and replace built-in headers with the same name.
  const ProviderConfig({
    required this.name,
    required this.apiKey,
    required this.model,
    required this.pricePerInputToken,
    required this.pricePerOutputToken,
    this.apiKeys = const <String>[],
    this.pricePerCachedInputToken,
    this.baseUrl,
    this.adapter,
    this.timeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 60),
    this.deadline,
    this.maxOutputTokens = 1024,
    this.requestStreamUsage = true,
    this.headers = const <String, String>{},
    this.settings = const GenerationSettings(),
    this.capabilities,
  }) : assert(pricePerInputToken >= 0),
       assert(pricePerOutputToken >= 0),
       assert(
         pricePerCachedInputToken == null || pricePerCachedInputToken >= 0,
       ),
       assert(maxOutputTokens > 0);

  /// A model served by a local [Ollama](https://ollama.com) server.
  ///
  /// Uses Ollama's OpenAI-compatible endpoint, costs nothing, and allows two
  /// minutes for the first response while the model loads. A local
  /// [baseUrl] never triggers the offline check. [capabilities] defaults to
  /// [ProviderCapabilities.textOnly]; pass [ProviderCapabilities.vision] for
  /// a vision model such as `llava`.
  factory ProviderConfig.ollama({
    required String model,
    String baseUrl = 'http://localhost:11434/v1',
    String name = 'ollama',
    ProviderCapabilities capabilities = ProviderCapabilities.textOnly,
  }) {
    return ProviderConfig(
      name: name,
      apiKey: 'ollama',
      model: model,
      pricePerInputToken: 0,
      pricePerOutputToken: 0,
      baseUrl: baseUrl,
      adapter: 'openai',
      timeout: const Duration(minutes: 2),
      capabilities: capabilities,
    );
  }

  /// A model served by a local [LM Studio](https://lmstudio.ai) server.
  ///
  /// Same behaviour as [ProviderConfig.ollama], on LM Studio's default port.
  factory ProviderConfig.lmStudio({
    required String model,
    String baseUrl = 'http://localhost:1234/v1',
    String name = 'lmstudio',
    ProviderCapabilities capabilities = ProviderCapabilities.textOnly,
  }) {
    return ProviderConfig(
      name: name,
      apiKey: 'lm-studio',
      model: model,
      pricePerInputToken: 0,
      pricePerOutputToken: 0,
      baseUrl: baseUrl,
      adapter: 'openai',
      timeout: const Duration(minutes: 2),
      capabilities: capabilities,
    );
  }

  /// A model on [Groq](https://groq.com)'s OpenAI-compatible API.
  ///
  /// [capabilities] defaults to [ProviderCapabilities.vision]. Pass
  /// [ProviderCapabilities.textOnly] for a model without vision.
  factory ProviderConfig.groq({
    required String apiKey,
    required String model,
    required double pricePerInputToken,
    required double pricePerOutputToken,
    String name = 'groq',
    ProviderCapabilities capabilities = ProviderCapabilities.vision,
  }) {
    return ProviderConfig(
      name: name,
      apiKey: apiKey,
      model: model,
      pricePerInputToken: pricePerInputToken,
      pricePerOutputToken: pricePerOutputToken,
      baseUrl: 'https://api.groq.com/openai/v1',
      adapter: 'openai',
      capabilities: capabilities,
    );
  }

  /// A model on [Mistral](https://mistral.ai)'s chat-completions API.
  ///
  /// Mistral rejects `stream_options`, so [requestStreamUsage] is false. It
  /// still reports usage in the last chunk. [capabilities] defaults to
  /// [ProviderCapabilities.vision].
  factory ProviderConfig.mistral({
    required String apiKey,
    required String model,
    required double pricePerInputToken,
    required double pricePerOutputToken,
    String name = 'mistral',
    ProviderCapabilities capabilities = ProviderCapabilities.vision,
  }) {
    return ProviderConfig(
      name: name,
      apiKey: apiKey,
      model: model,
      pricePerInputToken: pricePerInputToken,
      pricePerOutputToken: pricePerOutputToken,
      baseUrl: 'https://api.mistral.ai/v1',
      adapter: 'openai',
      requestStreamUsage: false,
      capabilities: capabilities,
    );
  }

  /// A model on [DeepSeek](https://deepseek.com)'s OpenAI-compatible API.
  ///
  /// DeepSeek chat models take text only.
  factory ProviderConfig.deepSeek({
    required String apiKey,
    required String model,
    required double pricePerInputToken,
    required double pricePerOutputToken,
    double? pricePerCachedInputToken,
    String name = 'deepseek',
  }) {
    return ProviderConfig(
      name: name,
      apiKey: apiKey,
      model: model,
      pricePerInputToken: pricePerInputToken,
      pricePerOutputToken: pricePerOutputToken,
      pricePerCachedInputToken: pricePerCachedInputToken,
      baseUrl: 'https://api.deepseek.com/v1',
      adapter: 'openai',
      capabilities: ProviderCapabilities.textOnly,
    );
  }

  /// A deployment on Azure OpenAI.
  ///
  /// [endpoint] is the resource URL, such as
  /// `https://my-resource.openai.azure.com`. [deployment] becomes [model],
  /// so logs and cost tracking show it. The key is sent in the `api-key`
  /// header, and [apiVersion] as the `api-version` query parameter.
  factory ProviderConfig.azureOpenAi({
    required String endpoint,
    required String deployment,
    required String apiKey,
    required double pricePerInputToken,
    required double pricePerOutputToken,
    String apiVersion = '2024-10-21',
    String name = 'azure-openai',
    ProviderCapabilities capabilities = ProviderCapabilities.vision,
  }) {
    final root = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    return ProviderConfig(
      name: name,
      apiKey: apiKey,
      model: deployment,
      pricePerInputToken: pricePerInputToken,
      pricePerOutputToken: pricePerOutputToken,
      baseUrl:
          '$root/openai/deployments/${Uri.encodeComponent(deployment)}'
          '?api-version=${Uri.encodeQueryComponent(apiVersion)}',
      adapter: 'azure-openai',
      capabilities: capabilities,
    );
  }

  /// Display name used in attempt logs and failover order.
  ///
  /// This is the stable label for the upstream, for example `openai` or
  /// `anthropic`. It is not the model id. When [adapter] is null, it also
  /// selects the built-in adapter.
  final String name;

  /// Credential sent to the upstream provider.
  ///
  /// Callers own how this value is stored. The router does not print it.
  final String apiKey;

  /// Further credentials for the same provider, pooled with [apiKey].
  ///
  /// Empty by default. With more than one key, the router rotates them (see
  /// `KeyPoolPolicy`) and moves to the next key when one is rate limited or
  /// rejected, before it fails over to another provider. Use it when the
  /// provider cannot be swapped, such as for image generation.
  final List<String> apiKeys;

  /// [apiKey] followed by [apiKeys], without duplicates or blanks.
  List<String> get allKeys => <String>{
    apiKey,
    ...apiKeys.where((key) => key.isNotEmpty),
  }.toList(growable: false);

  /// Upstream model id, for example `gpt-4o-mini` or `gemini-2.0-flash`.
  final String model;

  /// USD charged for one input token.
  ///
  /// `0.000001` is one micro-dollar. Must be greater than or equal to zero.
  final double pricePerInputToken;

  /// USD charged for one output token.
  ///
  /// `0.000001` is one micro-dollar. Must be greater than or equal to zero.
  final double pricePerOutputToken;

  /// USD charged for one input token read from the provider's prompt cache.
  ///
  /// Null, the default, charges cached tokens at [pricePerInputToken].
  final double? pricePerCachedInputToken;

  /// Optional endpoint override for this provider.
  ///
  /// When null, the adapter uses that provider's default base URL. Point it
  /// at a backend proxy to keep API keys out of the app.
  final String? baseUrl;

  /// Built-in adapter that speaks to this provider, when [name] is not one.
  ///
  /// One of `openai`, `anthropic`, `gemini`, `openrouter`, or
  /// `azure-openai`, case-insensitive. Null, the default, uses [name]. Set it
  /// to give a provider any display name, for example
  /// `name: 'fast', adapter: 'openai'`. `RouterLlmProvider.customAdapters`
  /// is still looked up by [name] first.
  final String? adapter;

  /// Maximum time to wait for response headers, and for an error body.
  ///
  /// Defaults to 30 seconds. [idleTimeout] and [deadline] bound the stream
  /// after the headers arrive.
  final Duration timeout;

  /// Maximum time to wait between two lines of a streaming response.
  ///
  /// Defaults to 60 seconds. SSE keep-alive comments reset it. Null disables
  /// the check. A stalled stream fails over if no text was emitted yet.
  final Duration? idleTimeout;

  /// Maximum total time for one attempt, from request to last chunk.
  ///
  /// Null, the default, means no overall limit.
  final Duration? deadline;

  /// Maximum completion tokens requested for one attempt.
  ///
  /// Defaults to 1024. OpenAI's own API receives it as
  /// `max_completion_tokens`. Other OpenAI-compatible hosts and Anthropic
  /// receive `max_tokens`. Gemini receives `generationConfig.maxOutputTokens`.
  /// The cap is what the provider reserves, so a lower value keeps a small
  /// credit balance from rejecting the call.
  final int maxOutputTokens;

  /// Whether OpenAI-compatible requests ask for token usage in the stream.
  ///
  /// Defaults to true, which sends `stream_options.include_usage`. Set it to
  /// false for compatible servers that reject `stream_options`. Token counts
  /// are then estimated.
  final bool requestStreamUsage;

  /// Extra HTTP headers sent with every request to this provider.
  ///
  /// A header with the same name as a built-in one, such as `authorization`,
  /// replaces it. Use this for proxy auth or provider-specific headers.
  final Map<String, String> headers;

  /// System prompt and sampling settings for this provider.
  ///
  /// Each null field falls back to `RouterLlmProvider.settings`.
  final GenerationSettings settings;

  /// Attachment kinds this provider and model accept.
  ///
  /// Null, the default, uses the adapter's capabilities. Set it when the
  /// model differs from what its vendor usually supports, for example
  /// [ProviderCapabilities.textOnly] for a model without vision.
  final ProviderCapabilities? capabilities;

  /// Identifier used for health and latency tracking: `name/model`.
  String get id => '$name/$model';

  /// Whether this provider costs nothing per token, such as a local model.
  bool get isFree =>
      pricePerInputToken == 0 &&
      pricePerOutputToken == 0 &&
      (pricePerCachedInputToken ?? 0) == 0;

  static const Object _unset = Object();

  /// Returns a copy of this configuration with the given fields replaced.
  ///
  /// Passing `baseUrl: null`, `adapter: null`, `idleTimeout: null`,
  /// `deadline: null`, `capabilities: null`, or
  /// `pricePerCachedInputToken: null` clears that value. Omitted fields keep
  /// their current values. Price replacements must still be zero or
  /// positive.
  ProviderConfig copyWith({
    String? name,
    String? apiKey,
    String? model,
    double? pricePerInputToken,
    double? pricePerOutputToken,
    List<String>? apiKeys,
    Object? pricePerCachedInputToken = _unset,
    Object? baseUrl = _unset,
    Object? adapter = _unset,
    Duration? timeout,
    Object? idleTimeout = _unset,
    Object? deadline = _unset,
    int? maxOutputTokens,
    bool? requestStreamUsage,
    Map<String, String>? headers,
    GenerationSettings? settings,
    Object? capabilities = _unset,
  }) {
    return ProviderConfig(
      name: name ?? this.name,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      pricePerInputToken: pricePerInputToken ?? this.pricePerInputToken,
      pricePerOutputToken: pricePerOutputToken ?? this.pricePerOutputToken,
      apiKeys: apiKeys ?? this.apiKeys,
      pricePerCachedInputToken: identical(pricePerCachedInputToken, _unset)
          ? this.pricePerCachedInputToken
          : pricePerCachedInputToken as double?,
      baseUrl: identical(baseUrl, _unset) ? this.baseUrl : baseUrl as String?,
      adapter: identical(adapter, _unset) ? this.adapter : adapter as String?,
      timeout: timeout ?? this.timeout,
      idleTimeout: identical(idleTimeout, _unset)
          ? this.idleTimeout
          : idleTimeout as Duration?,
      deadline: identical(deadline, _unset)
          ? this.deadline
          : deadline as Duration?,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      requestStreamUsage: requestStreamUsage ?? this.requestStreamUsage,
      headers: headers ?? this.headers,
      settings: settings ?? this.settings,
      capabilities: identical(capabilities, _unset)
          ? this.capabilities
          : capabilities as ProviderCapabilities?,
    );
  }

  /// Returns the USD cost of [inputTokens] and [outputTokens] at this config's
  /// per-token prices.
  ///
  /// [cachedInputTokens] is the part of [inputTokens] read from the
  /// provider's prompt cache, charged at [pricePerCachedInputToken] when it
  /// is set. The result is `(inputTokens - cachedInputTokens) *
  /// pricePerInputToken + cachedInputTokens * cachedPrice + outputTokens *
  /// pricePerOutputToken`, so a micro-dollar unit price stays a micro-dollar
  /// product. Counts must be zero or positive, and [cachedInputTokens] at
  /// most [inputTokens].
  double calculateCost({
    required int inputTokens,
    required int outputTokens,
    int cachedInputTokens = 0,
  }) {
    assert(inputTokens >= 0);
    assert(outputTokens >= 0);
    assert(cachedInputTokens >= 0);
    final cached = cachedInputTokens > inputTokens
        ? inputTokens
        : cachedInputTokens;
    return (inputTokens - cached) * pricePerInputToken +
        cached * (pricePerCachedInputToken ?? pricePerInputToken) +
        outputTokens * pricePerOutputToken;
  }

  /// The attachment kinds in [kinds] that [capabilities] rejects.
  ///
  /// Returns an empty list when [capabilities] is null, because the adapter
  /// then decides.
  List<AttachmentKind> unsupportedKinds(Iterable<AttachmentKind> kinds) {
    return capabilities?.unsupported(kinds) ?? const <AttachmentKind>[];
  }
}
