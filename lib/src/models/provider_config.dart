/// Configuration for one upstream model in the router's failover chain.
///
/// Prices are USD charged for a single token. A value of `0.000001` is one
/// micro-dollar per token. [calculateCost] multiplies those unit prices by
/// the token counts for an attempt.
class ProviderConfig {
  /// Creates configuration for a single upstream provider.
  ///
  /// [pricePerInputToken] and [pricePerOutputToken] must be zero or positive.
  /// [timeout] defaults to 30 seconds. [maxOutputTokens] defaults to 1024
  /// and is the completion cap sent on each attempt. [baseUrl] overrides the
  /// provider's default endpoint when it is non-null.
  const ProviderConfig({
    required this.name,
    required this.apiKey,
    required this.model,
    required this.pricePerInputToken,
    required this.pricePerOutputToken,
    this.baseUrl,
    this.timeout = const Duration(seconds: 30),
    this.maxOutputTokens = 1024,
  })  : assert(pricePerInputToken >= 0),
        assert(pricePerOutputToken >= 0),
        assert(maxOutputTokens > 0);

  /// Display name used in attempt logs and failover order.
  ///
  /// This is the stable label for the upstream, for example `openai` or
  /// `anthropic`. It is not the model id.
  final String name;

  /// Credential sent to the upstream provider.
  ///
  /// Callers own how this value is stored. The router does not print it.
  final String apiKey;

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

  /// Optional endpoint override for this provider.
  ///
  /// When null, the adapter uses that provider's default base URL.
  final String? baseUrl;

  /// Maximum time to wait for one upstream attempt.
  ///
  /// Defaults to 30 seconds.
  final Duration timeout;

  /// Maximum completion tokens requested for one attempt.
  ///
  /// Defaults to 1024. OpenAI-compatible calls send this as `max_tokens`.
  /// Anthropic sends it as `max_tokens`. Gemini sends it as
  /// `generationConfig.maxOutputTokens`. The cap is what the provider reserves,
  /// so a lower value keeps a small credit balance from rejecting the call.
  final int maxOutputTokens;

  static const Object _unset = Object();

  /// Returns a copy of this configuration with the given fields replaced.
  ///
  /// Passing `baseUrl: null` clears a previously set endpoint. Omitted
  /// fields keep their current values. Price replacements must still be
  /// zero or positive.
  ProviderConfig copyWith({
    String? name,
    String? apiKey,
    String? model,
    double? pricePerInputToken,
    double? pricePerOutputToken,
    Object? baseUrl = _unset,
    Duration? timeout,
    int? maxOutputTokens,
  }) {
    return ProviderConfig(
      name: name ?? this.name,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      pricePerInputToken: pricePerInputToken ?? this.pricePerInputToken,
      pricePerOutputToken: pricePerOutputToken ?? this.pricePerOutputToken,
      baseUrl: identical(baseUrl, _unset) ? this.baseUrl : baseUrl as String?,
      timeout: timeout ?? this.timeout,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    );
  }

  /// Returns the USD cost of [inputTokens] and [outputTokens] at this config's
  /// per-token prices.
  ///
  /// The result is `inputTokens * pricePerInputToken + outputTokens *
  /// pricePerOutputToken`, so a micro-dollar unit price stays a micro-dollar
  /// product. Both token counts must be zero or positive.
  double calculateCost({
    required int inputTokens,
    required int outputTokens,
  }) {
    assert(inputTokens >= 0);
    assert(outputTokens >= 0);
    return inputTokens * pricePerInputToken +
        outputTokens * pricePerOutputToken;
  }
}
