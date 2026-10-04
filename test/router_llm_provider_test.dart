import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Failover, terminal errors, and cost recording for [RouterLlmProvider].
void main() {
  group('RouterLlmProvider', () {
    test('fails over when the first provider is retryable', () async {
      final calls = <String>[];
      final clients = _clients(2);
      addTearDown(() {
        for (final client in clients) {
          client.close();
        }
      });

      final router = RouterLlmProvider(
        providers: [_config('alpha'), _config('beta')],
        customAdapters: {
          'alpha': _ScriptedAdapter(
            clients[0],
            (config, messages) {
              calls.add(config.name);
              expect(messages.single.text, 'ping');
              return Stream<AdapterChunk>.error(
                const RetryableLlmException('rate limited', statusCode: 429),
              );
            },
          ),
          'beta': _ScriptedAdapter(clients[1], (config, messages) {
            calls.add(config.name);
            expect(messages.single.text, 'ping');
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          }),
        },
      );
      addTearDown(router.dispose);

      final text = await router.generateStream('ping').join();

      expect(text, 'pong');
      expect(calls, ['alpha', 'beta']);
      expect(router.lastAttemptLogs, hasLength(2));
      expect(router.lastAttemptLogs.first.providerName, 'alpha');
      expect(router.lastAttemptLogs.first.isSuccess, isFalse);
      expect(router.lastAttemptLogs.first.statusCode, 429);
      expect(router.lastAttemptLogs.first.error, 'rate limited');
      expect(router.lastAttemptLogs.last.providerName, 'beta');
      expect(router.lastAttemptLogs.last.isSuccess, isTrue);
      expect(router.history, isEmpty);
    });

    test('throws AllProvidersFailedException when every provider fails',
        () async {
      final clients = _clients(2);
      addTearDown(() {
        for (final client in clients) {
          client.close();
        }
      });

      final router = RouterLlmProvider(
        providers: [_config('alpha'), _config('beta')],
        customAdapters: {
          'alpha': _ScriptedAdapter(clients[0], (config, messages) {
            expect(config.name, 'alpha');
            expect(messages.single.text, 'ping');
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('timeout', statusCode: 504),
            );
          }),
          'beta': _ScriptedAdapter(clients[1], (config, messages) {
            expect(config.name, 'beta');
            expect(messages.single.text, 'ping');
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('unavailable', statusCode: 503),
            );
          }),
        },
      );
      addTearDown(router.dispose);

      await expectLater(
        router.generateStream('ping').toList(),
        throwsA(
          isA<AllProvidersFailedException>().having(
            (error) => error.attempts.map((log) => log.providerName).toList(),
            'attempts',
            ['alpha', 'beta'],
          ),
        ),
      );
      expect(
        router.lastAttemptLogs.map((log) => log.error).toList(),
        ['timeout', 'unavailable'],
      );
    });

    test('rethrows TerminalLlmException without calling the next provider',
        () async {
      final calls = <String>[];
      final clients = _clients(2);
      addTearDown(() {
        for (final client in clients) {
          client.close();
        }
      });

      final router = RouterLlmProvider(
        providers: [_config('alpha'), _config('beta')],
        customAdapters: {
          'alpha': _ScriptedAdapter(clients[0], (config, messages) {
            calls.add(config.name);
            expect(messages, isNotEmpty);
            return Stream<AdapterChunk>.error(
              const TerminalLlmException('invalid prompt', statusCode: 400),
            );
          }),
          'beta': _ScriptedAdapter(clients[1], (config, messages) {
            calls.add(config.name);
            return Stream<AdapterChunk>.value(
                const AdapterText('should not run'));
          }),
        },
      );
      addTearDown(router.dispose);

      await expectLater(
        router.generateStream('ping').toList(),
        throwsA(
          isA<TerminalLlmException>()
              .having((error) => error.statusCode, 'statusCode', 400)
              .having((error) => error.message, 'message', 'invalid prompt'),
        ),
      );
      expect(calls, ['alpha']);
      expect(router.lastAttemptLogs, hasLength(1));
      expect(router.lastAttemptLogs.single.isSuccess, isFalse);
      expect(router.lastAttemptLogs.single.providerName, 'alpha');
    });

    test('does not fail over on HTTP 402', () async {
      final calls = <String>[];
      final clients = _clients(2);
      addTearDown(() {
        for (final client in clients) {
          client.close();
        }
      });

      final router = RouterLlmProvider(
        providers: [_config('alpha'), _config('beta')],
        customAdapters: {
          'alpha': _ScriptedAdapter(clients[0], (config, messages) {
            calls.add(config.name);
            return Stream<AdapterChunk>.error(
              const TerminalLlmException(
                'insufficient credits',
                statusCode: 402,
              ),
            );
          }),
          'beta': _ScriptedAdapter(clients[1], (config, messages) {
            calls.add(config.name);
            return Stream<AdapterChunk>.value(
                const AdapterText('should not run'));
          }),
        },
      );
      addTearDown(router.dispose);

      await expectLater(
        router.generateStream('ping').toList(),
        throwsA(
          isA<TerminalLlmException>().having(
            (error) => error.statusCode,
            'statusCode',
            402,
          ),
        ),
      );
      expect(calls, ['alpha']);
      expect(router.lastAttemptLogs.single.statusCode, 402);
    });

    test('keeps partial text and does not call the next provider', () async {
      final calls = <String>[];
      final clients = _clients(2);
      addTearDown(() {
        for (final client in clients) {
          client.close();
        }
      });

      final router = RouterLlmProvider(
        providers: [_config('alpha'), _config('beta')],
        customAdapters: {
          'alpha': _ScriptedAdapter(clients[0], (config, messages) {
            calls.add(config.name);
            return _partialThenDrop();
          }),
          'beta': _ScriptedAdapter(clients[1], (config, messages) {
            calls.add(config.name);
            return Stream<AdapterChunk>.value(
                const AdapterText('should not run'));
          }),
        },
      );
      addTearDown(router.dispose);

      final chunks = <String>[];
      await expectLater(
        router.generateStream('ping').forEach(chunks.add),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
      expect(chunks, ['Hello']);
      expect(calls, ['alpha']);
    });

    test('records input and output tokens after a successful stream', () async {
      final client = MockClient((_) async => http.Response('', 200));
      addTearDown(client.close);
      final tracker = CostTracker();
      addTearDown(tracker.dispose);

      final router = RouterLlmProvider(
        providers: [
          _config('beta', inputPrice: 0.000001, outputPrice: 0.000002),
        ],
        costTracker: tracker,
        customAdapters: {
          'beta': _ScriptedAdapter(client, (config, messages) {
            expect(config.name, 'beta');
            expect(messages.single.text, 'ping');
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          }),
        },
      );
      addTearDown(router.dispose);

      await router.generateStream('ping').drain<void>();

      // "ping" and "pong" are 4 characters, so each is one estimated token.
      expect(tracker.totalInputTokens, 1);
      expect(tracker.totalOutputTokens, 1);
      expect(tracker.totalCost, closeTo(0.000003, 1e-12));
      expect(router.lastAttemptLogs.single.isSuccess, isTrue);
    });

    test('records provider usage instead of the character estimate', () async {
      final client = MockClient((_) async => http.Response('', 200));
      addTearDown(client.close);
      final tracker = CostTracker();
      addTearDown(tracker.dispose);

      final router = RouterLlmProvider(
        providers: [
          _config('beta', inputPrice: 0.000001, outputPrice: 0.000002),
        ],
        costTracker: tracker,
        customAdapters: {
          'beta': _ScriptedAdapter(client, (config, messages) {
            return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
              AdapterText('pong'),
              AdapterUsage(inputTokens: 11, outputTokens: 7),
            ]);
          }),
        },
      );
      addTearDown(router.dispose);

      final text = await router.generateStream('ping').join();

      expect(text, 'pong');
      expect(tracker.totalInputTokens, 11);
      expect(tracker.totalOutputTokens, 7);
      expect(tracker.totalCost, closeTo(0.000025, 1e-12));
    });

    test('sendMessageStream sends earlier turns as separate messages',
        () async {
      final client = MockClient((_) async => http.Response('', 200));
      addTearDown(client.close);
      final seen = <List<ChatTurn>>[];

      final router = RouterLlmProvider(
        providers: [_config('beta')],
        history: <ChatMessage>[
          ChatMessage.user('hello', const []),
          ChatMessage.llm()..append('hi'),
        ],
        customAdapters: {
          'beta': _ScriptedAdapter(client, (config, messages) {
            seen.add(messages);
            return Stream<AdapterChunk>.value(const AdapterText('next'));
          }),
        },
      );
      addTearDown(router.dispose);

      await router.sendMessageStream('again').drain<void>();

      expect(seen, hasLength(1));
      expect(
        seen.single.map((turn) => '${turn.role.name}:${turn.text}').toList(),
        <String>['user:hello', 'assistant:hi', 'user:again'],
      );
    });
  });
}

ProviderConfig _config(
  String name, {
  double inputPrice = 0,
  double outputPrice = 0,
}) {
  return ProviderConfig(
    name: name,
    apiKey: 'sk-test',
    model: 'test-model',
    pricePerInputToken: inputPrice,
    pricePerOutputToken: outputPrice,
  );
}

Stream<AdapterChunk> _partialThenDrop() async* {
  yield const AdapterText('Hello');
  throw const RetryableLlmException('connection dropped', statusCode: 503);
}

List<http.Client> _clients(int count) {
  return List<http.Client>.generate(
    count,
    (_) => MockClient((_) async => http.Response('', 200)),
  );
}

class _ScriptedAdapter extends BaseLlmAdapter {
  _ScriptedAdapter(http.Client client, this._handler) : super(client: client);

  final Stream<AdapterChunk> Function(
    ProviderConfig config,
    List<ChatTurn> messages,
  ) _handler;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    return _handler(config, messages);
  }
}
