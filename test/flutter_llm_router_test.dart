import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for router history and attempt log formatting.
void main() {
  test('AttemptLog toString includes outcome details', () {
    final timestamp = DateTime.utc(2026, 10, 1, 12);
    final log = AttemptLog(
      providerName: 'openai',
      model: 'gpt-4o-mini',
      timestamp: timestamp,
      latencyMs: 842,
      isSuccess: false,
      error: 'timeout',
      statusCode: 504,
    );

    expect(log.providerName, 'openai');
    expect(log.model, 'gpt-4o-mini');
    expect(log.timestamp, timestamp);
    expect(log.latencyMs, 842);
    expect(log.isSuccess, isFalse);
    expect(log.error, 'timeout');
    expect(log.statusCode, 504);
    expect(
      log.toString(),
      'AttemptLog(providerName: openai, model: gpt-4o-mini, '
      'timestamp: ${timestamp.toIso8601String()}, latencyMs: 842, '
      'isSuccess: false, error: timeout, statusCode: 504)',
    );
  });

  test('RouterLlmProvider keeps history and notifies listeners', () {
    final router = RouterLlmProvider(
      providers: const [
        ProviderConfig(
          name: 'primary',
          apiKey: 'sk-test',
          model: 'gemini-2.0-flash',
          pricePerInputToken: 0,
          pricePerOutputToken: 0,
        ),
      ],
    );
    addTearDown(router.dispose);

    var notifications = 0;
    router.addListener(() => notifications++);

    router.history = [ChatMessage.user('hello', const [])];

    expect(router.providers, hasLength(1));
    expect(router.providers.single.name, 'primary');
    expect(router.history, hasLength(1));
    expect(router.history.single.text, 'hello');
    expect(router.lastAttemptLogs, isEmpty);
    expect(notifications, 1);
  });
}
