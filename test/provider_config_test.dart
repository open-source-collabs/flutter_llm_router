import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [ProviderConfig] pricing and copying.
void main() {
  const config = ProviderConfig(
    name: 'openai',
    apiKey: 'sk-test',
    model: 'gpt-4o-mini',
    pricePerInputToken: 0.000001,
    pricePerOutputToken: 0.000002,
  );

  test('calculateCost multiplies token counts by micro-dollar unit prices', () {
    // 1,500,000 input tokens * $0.000001 = $1.50
    // 500,000 output tokens * $0.000002 = $1.00
    final cost = config.calculateCost(
      inputTokens: 1500000,
      outputTokens: 500000,
    );

    expect(cost, closeTo(2.5, 1e-12));
    expect(
      cost,
      1500000 * config.pricePerInputToken + 500000 * config.pricePerOutputToken,
    );
  });

  test('calculateCost rejects negative token counts', () {
    expect(
      () => config.calculateCost(inputTokens: -1, outputTokens: 0),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => config.calculateCost(inputTokens: 0, outputTokens: -1),
      throwsA(isA<AssertionError>()),
    );
  });

  test('constructor rejects negative token prices', () {
    expect(
      () => ProviderConfig(
        name: 'openai',
        apiKey: 'sk-test',
        model: 'gpt-4o-mini',
        pricePerInputToken: -0.000001,
        pricePerOutputToken: 0,
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => ProviderConfig(
        name: 'openai',
        apiKey: 'sk-test',
        model: 'gpt-4o-mini',
        pricePerInputToken: 0,
        pricePerOutputToken: -0.000001,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('copyWith replaces selected fields and can clear baseUrl', () {
    final withEndpoint = config.copyWith(
      model: 'gpt-4o',
      timeout: const Duration(seconds: 10),
      baseUrl: 'https://api.example.com/v1',
    );

    expect(withEndpoint.name, 'openai');
    expect(withEndpoint.apiKey, 'sk-test');
    expect(withEndpoint.model, 'gpt-4o');
    expect(withEndpoint.pricePerInputToken, 0.000001);
    expect(withEndpoint.pricePerOutputToken, 0.000002);
    expect(withEndpoint.baseUrl, 'https://api.example.com/v1');
    expect(withEndpoint.timeout, const Duration(seconds: 10));

    expect(withEndpoint.copyWith(baseUrl: null).baseUrl, isNull);
  });

  test('timeout defaults to 30 seconds', () {
    expect(config.timeout, const Duration(seconds: 30));
    expect(config.baseUrl, isNull);
  });

  test('maxOutputTokens defaults to 1024 and rejects zero', () {
    expect(config.maxOutputTokens, 1024);
    expect(
      () => ProviderConfig(
        name: 'openai',
        apiKey: 'sk-test',
        model: 'gpt-4o-mini',
        pricePerInputToken: 0,
        pricePerOutputToken: 0,
        maxOutputTokens: 0,
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => config.copyWith(maxOutputTokens: -1),
      throwsA(isA<AssertionError>()),
    );
  });

  test('calculateCost is zero when there is nothing to bill', () {
    expect(config.calculateCost(inputTokens: 0, outputTokens: 0), 0);

    const free = ProviderConfig(
      name: 'openai',
      apiKey: 'sk-test',
      model: 'gpt-4o-mini',
      pricePerInputToken: 0,
      pricePerOutputToken: 0,
    );
    expect(free.calculateCost(inputTokens: 1000, outputTokens: 1000), 0);
  });

  test('copyWith keeps an omitted baseUrl and replaces the completion cap', () {
    final withEndpoint = config.copyWith(
      baseUrl: 'https://api.example.com/v1',
      maxOutputTokens: 256,
    );
    final renamed = withEndpoint.copyWith(name: 'backup', apiKey: 'sk-next');

    expect(renamed.name, 'backup');
    expect(renamed.apiKey, 'sk-next');
    expect(renamed.model, config.model);
    expect(renamed.baseUrl, 'https://api.example.com/v1');
    expect(renamed.maxOutputTokens, 256);
    expect(renamed.timeout, config.timeout);
    expect(renamed.pricePerInputToken, config.pricePerInputToken);
    expect(renamed.pricePerOutputToken, config.pricePerOutputToken);
  });

  test('copyWith rejects a negative replacement price', () {
    expect(
      () => config.copyWith(pricePerInputToken: -1),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => config.copyWith(pricePerOutputToken: -1),
      throwsA(isA<AssertionError>()),
    );
  });

  test('calculateCost keeps a per-million price that was scaled per token', () {
    const scaled = ProviderConfig(
      name: 'openai',
      apiKey: 'sk-test',
      model: 'gpt-4o-mini',
      pricePerInputToken: 0.00000015,
      pricePerOutputToken: 0.0000006,
    );

    expect(
      scaled.calculateCost(inputTokens: 1000000, outputTokens: 1000000),
      closeTo(0.75, 1e-12),
    );
  });
}
