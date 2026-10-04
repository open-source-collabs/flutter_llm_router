import 'dart:typed_data';

import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Routing, billing, history, and lifecycle scenarios for [RouterLlmProvider].
void main() {
  group('failover chain', () {
    test('walks three providers and bills only the winner', () async {
      final calls = <String>[];
      final router = _router(
        providers: [
          _config('alpha', inputPrice: 1, outputPrice: 1),
          _config('beta', inputPrice: 1, outputPrice: 1),
          _config('gamma', inputPrice: 0.000001, outputPrice: 0.000002),
        ],
        adapters: {
          'alpha': (config, messages) {
            calls.add('${config.name}:${config.model}');
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('rate limited', statusCode: 429),
            );
          },
          'beta': (config, messages) {
            calls.add('${config.name}:${config.model}');
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('timed out', statusCode: 408),
            );
          },
          'gamma': (config, messages) {
            calls.add('${config.name}:${config.model}');
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          },
        },
      );

      expect(await router.generateStream('ping').join(), 'pong');
      expect(calls, <String>[
        'alpha:alpha-model',
        'beta:beta-model',
        'gamma:gamma-model',
      ]);
      expect(
        router.lastAttemptLogs.map((log) => log.statusCode).toList(),
        <int?>[429, 408, null],
      );
      expect(router.lastAttemptLogs.last.isSuccess, isTrue);
      expect(router.lastAttemptLogs.last.error, isNull);
      expect(router.costTracker.totalInputTokens, 1);
      expect(router.costTracker.totalOutputTokens, 1);
      expect(router.costTracker.totalCost, closeTo(0.000003, 1e-12));
    });

    test('the same adapter name still fails over by model', () async {
      final models = <String>[];
      final router = _router(
        providers: [
          _config('openrouter', model: 'openai/gpt-4o-mini'),
          _config('openrouter', model: 'google/gemini-2.5-flash'),
        ],
        adapters: {
          'openrouter': (config, messages) {
            models.add(config.model);
            if (models.length == 1) {
              return Stream<AdapterChunk>.error(
                const RetryableLlmException('overloaded', statusCode: 503),
              );
            }
            return Stream<AdapterChunk>.value(const AdapterText('ok'));
          },
        },
      );

      expect(await router.generateStream('ping').join(), 'ok');
      expect(models, <String>[
        'openai/gpt-4o-mini',
        'google/gemini-2.5-flash',
      ]);
      expect(
        router.lastAttemptLogs.map((log) => log.model).toList(),
        models,
      );
      expect(router.lastAttemptLogs.map((log) => log.providerName).toSet(), {
        'openrouter',
      });
    });

    test('an unknown name is terminal and the rest of the chain is skipped',
        () async {
      final calls = <String>[];
      final router = _router(
        providers: [
          _config('alpha'),
          _config('not-a-provider'),
          _config('gamma'),
        ],
        adapters: {
          'alpha': (config, messages) {
            calls.add(config.name);
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('busy', statusCode: 503),
            );
          },
          'gamma': (config, messages) {
            calls.add(config.name);
            return Stream<AdapterChunk>.value(const AdapterText('late'));
          },
        },
      );

      await expectLater(
        router.generateStream('ping').toList(),
        throwsA(
          isA<TerminalLlmException>().having(
            (error) => error.message,
            'message',
            contains('not-a-provider'),
          ),
        ),
      );
      expect(calls, <String>['alpha']);
      expect(router.lastAttemptLogs, hasLength(2));
      expect(router.lastAttemptLogs.last.providerName, 'not-a-provider');
      expect(router.lastAttemptLogs.last.isSuccess, isFalse);
      expect(router.costTracker.totalCost, 0);
    });

    test('customAdapters match the configured name exactly', () async {
      final router = _router(
        providers: [_config('Alpha')],
        adapters: {
          'alpha': (config, messages) {
            return Stream<AdapterChunk>.value(const AdapterText('wrong case'));
          },
        },
      );

      await expectLater(
        router.generateStream('ping').toList(),
        throwsA(
          isA<TerminalLlmException>().having(
            (error) => error.message,
            'message',
            contains('"Alpha"'),
          ),
        ),
      );
      expect(router.costTracker.totalInputTokens, 0);
    });

    test('a matching custom adapter is used before any built-in', () async {
      final router = _router(
        providers: [_config('openai', model: 'gpt-4o-mini')],
        adapters: {
          'openai': (config, messages) {
            expect(config.model, 'gpt-4o-mini');
            return Stream<AdapterChunk>.value(const AdapterText('local'));
          },
        },
      );

      expect(await router.generateStream('ping').join(), 'local');
      expect(router.lastAttemptLogs.single.providerName, 'openai');
    });

    test('usage alone does not count as started text, so failover continues',
        () async {
      final router = _router(
        providers: [_config('alpha', inputPrice: 9), _config('beta')],
        adapters: {
          'alpha': (config, messages) async* {
            yield const AdapterUsage(inputTokens: 99, outputTokens: 99);
            throw const RetryableLlmException('dropped', statusCode: 503);
          },
          'beta': (config, messages) {
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          },
        },
      );

      expect(await router.generateStream('ping').join(), 'pong');
      expect(router.costTracker.totalInputTokens, 1);
      expect(router.costTracker.totalOutputTokens, 1);
      expect(router.lastAttemptLogs.first.isSuccess, isFalse);
    });

    test('an empty text chunk blocks failover', () async {
      final calls = <String>[];
      final router = _router(
        providers: [_config('alpha'), _config('beta')],
        adapters: {
          'alpha': (config, messages) async* {
            calls.add(config.name);
            yield const AdapterText('');
            throw const RetryableLlmException('dropped', statusCode: 503);
          },
          'beta': (config, messages) {
            calls.add(config.name);
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          },
        },
      );

      final chunks = <String>[];
      await expectLater(
        router.generateStream('ping').forEach(chunks.add),
        throwsA(isA<RetryableLlmException>()),
      );
      expect(chunks, <String>['']);
      expect(calls, <String>['alpha']);
      expect(router.costTracker.totalCost, 0);
    });

    test('a later call replaces attempt logs and does not bill failures',
        () async {
      var fail = true;
      final router = _router(
        providers: [
          _config('alpha'),
          _config('beta', inputPrice: 0.000001, outputPrice: 0.000002),
        ],
        adapters: {
          'alpha': (config, messages) {
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('busy', statusCode: 503),
            );
          },
          'beta': (config, messages) {
            if (fail) {
              return Stream<AdapterChunk>.error(
                const RetryableLlmException('down', statusCode: 502),
              );
            }
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          },
        },
      );

      await expectLater(
        router.generateStream('ping').toList(),
        throwsA(isA<AllProvidersFailedException>()),
      );
      expect(router.lastAttemptLogs, hasLength(2));
      expect(router.costTracker.totalCost, 0);
      expect(
        () => router.lastAttemptLogs.clear(),
        throwsUnsupportedError,
      );

      fail = false;
      expect(await router.generateStream('ping').join(), 'pong');
      expect(router.lastAttemptLogs, hasLength(2));
      expect(router.lastAttemptLogs.last.isSuccess, isTrue);
      expect(router.costTracker.totalInputTokens, 1);
      expect(router.costTracker.totalOutputTokens, 1);
    });
  });

  group('token accounting', () {
    test('estimates input and output on the 4-character boundary', () async {
      final router = _router(
        providers: [_config('beta')],
        adapters: {
          'beta': (config, messages) {
            expect(messages.single.text, 'abcde');
            return Stream<AdapterChunk>.value(const AdapterText('a'));
          },
        },
      );

      await router.generateStream('abcde').drain<void>();

      // "abcde" is 5 characters -> 2 tokens. "a" is 1 character -> 1 token.
      expect(router.costTracker.totalInputTokens, 2);
      expect(router.costTracker.totalOutputTokens, 1);
    });

    test('an empty reply is zero output tokens and still a success', () async {
      final router = _router(
        providers: [_config('beta')],
        adapters: {
          'beta': (config, messages) => const Stream<AdapterChunk>.empty(),
        },
      );

      expect(await router.generateStream('').join(), isEmpty);
      expect(router.lastAttemptLogs.single.isSuccess, isTrue);
      expect(router.lastAttemptLogs.single.latencyMs, greaterThanOrEqualTo(0));
      expect(router.costTracker.totalInputTokens, 0);
      expect(router.costTracker.totalOutputTokens, 0);
    });

    test('an explicit zero from the provider beats the character estimate',
        () async {
      final router = _router(
        providers: [
          _config('beta', inputPrice: 0.000001, outputPrice: 0.000002),
        ],
        adapters: {
          'beta': (config, messages) {
            return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
              AdapterText('hello world'),
              AdapterUsage(inputTokens: 0, outputTokens: 0),
            ]);
          },
        },
      );

      expect(await router.generateStream('hello world').join(), 'hello world');
      expect(router.costTracker.totalInputTokens, 0);
      expect(router.costTracker.totalOutputTokens, 0);
      expect(router.costTracker.totalCost, 0);
    });

    test('a reported side is kept and the missing side is estimated', () async {
      final router = _router(
        providers: [_config('beta')],
        adapters: {
          'beta': (config, messages) {
            return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
              AdapterUsage(inputTokens: 0),
              AdapterText('abcd'),
              AdapterUsage(outputTokens: 8),
              AdapterUsage(inputTokens: 6),
            ]);
          },
        },
      );

      expect(await router.generateStream('hi').join(), 'abcd');
      expect(router.costTracker.totalInputTokens, 6);
      expect(router.costTracker.totalOutputTokens, 8);
    });

    test('joined history is estimated as one string, separators included',
        () async {
      final seen = <String>[];
      final router = _router(
        providers: [_config('beta')],
        history: <ChatMessage>[
          ChatMessage.user('a', const []),
          ChatMessage.llm()..append('b'),
        ],
        adapters: {
          'beta': (config, messages) {
            seen.add(messages.map((turn) => turn.text).join('\n'));
            return Stream<AdapterChunk>.value(const AdapterText('z'));
          },
        },
      );

      await router.sendMessageStream('c').drain<void>();

      // "a\nb\nc" is 5 characters, so the estimate is 2, not 1+1+1.
      expect(seen.single, 'a\nb\nc');
      expect(router.costTracker.totalInputTokens, 2);
      expect(router.costTracker.totalOutputTokens, 1);
    });

    test('a free provider moves token counters without notifying spend',
        () async {
      final observed = <double>[];
      final router = _router(
        providers: [_config('beta')],
        adapters: {
          'beta': (config, messages) {
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          },
        },
      );
      router.costTracker.totalCostNotifier.addListener(() {
        observed.add(router.costTracker.totalCost);
      });

      await router.generateStream('ping').drain<void>();

      expect(observed, isEmpty);
      expect(router.costTracker.totalInputTokens, 1);
      expect(router.costTracker.totalOutputTokens, 1);
      expect(router.costTracker.totalCost, 0);
    });

    test('a terminal failure and a mid-stream drop are not billed', () async {
      final router = _router(
        providers: [_config('alpha', inputPrice: 1, outputPrice: 1)],
        adapters: {
          'alpha': (config, messages) {
            return Stream<AdapterChunk>.error(
              const TerminalLlmException('denied', statusCode: 401),
            );
          },
        },
      );

      await expectLater(
        router.generateStream('ping').toList(),
        throwsA(isA<TerminalLlmException>()),
      );
      expect(router.costTracker.totalCost, 0);

      final partial = _router(
        providers: [_config('alpha', inputPrice: 1, outputPrice: 1)],
        adapters: {
          'alpha': (config, messages) async* {
            yield const AdapterText('Hello');
            throw const RetryableLlmException('reset', statusCode: 503);
          },
        },
      );
      await expectLater(
        partial.generateStream('ping').drain<void>(),
        throwsA(isA<RetryableLlmException>()),
      );
      expect(partial.costTracker.totalInputTokens, 0);
      expect(partial.costTracker.totalOutputTokens, 0);
    });
  });

  group('history', () {
    test('generateStream does not touch history or listeners', () async {
      var notifications = 0;
      final attachment = FileAttachment(
        name: 'notes.txt',
        mimeType: 'text/plain',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );
      final seen = <String>[];
      final router = _router(
        providers: [_config('beta')],
        history: <ChatMessage>[ChatMessage.user('seed', const [])],
        adapters: {
          'beta': (config, messages) {
            seen.add(messages.single.text);
            return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
              AdapterText('Hel'),
              AdapterText('lo'),
            ]);
          },
        },
      );
      router.addListener(() => notifications++);

      final text = await router
          .generateStream('look', attachments: <Attachment>[attachment]).join();

      expect(text, 'Hello');
      expect(seen.single, contains('look'));
      expect(seen.single, contains('FileAttachment(name: notes.txt'));
      expect(router.history.single.text, 'seed');
      expect(notifications, 0);
      expect(
        () => (router.history as List<ChatMessage>).add(
          ChatMessage.user('nope', const []),
        ),
        throwsUnsupportedError,
      );
    });

    test('sendMessageStream stores the turn, yields into history, and notifies',
        () async {
      var notifications = 0;
      final router = _router(
        providers: [_config('beta')],
        adapters: {
          'beta': (config, messages) {
            return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
              AdapterText('one'),
              AdapterText(' two'),
            ]);
          },
        },
      );
      router.addListener(() => notifications++);

      expect(await router.sendMessageStream('hi').join(), 'one two');

      expect(notifications, 2);
      expect(router.history, hasLength(2));
      expect(router.history.first.origin.isUser, isTrue);
      expect(router.history.first.text, 'hi');
      expect(router.history.last.origin.isLlm, isTrue);
      expect(router.history.last.text, 'one two');
    });

    test('a failed send still keeps the user turn and the partial reply',
        () async {
      var notifications = 0;
      final router = _router(
        providers: [_config('alpha')],
        adapters: {
          'alpha': (config, messages) async* {
            yield const AdapterText('Hel');
            throw const TerminalLlmException('bad request', statusCode: 400);
          },
        },
      );
      router.addListener(() => notifications++);

      await expectLater(
        router.sendMessageStream('hi').toList(),
        throwsA(isA<TerminalLlmException>()),
      );

      expect(notifications, 2);
      expect(router.history, hasLength(2));
      expect(router.history.first.text, 'hi');
      expect(router.history.last.text, 'Hel');
      expect(router.costTracker.totalCost, 0);
    });

    test('blank turns are omitted and attachments are sent as notes', () async {
      final seen = <List<ChatTurn>>[];
      final link = LinkAttachment(
        name: 'docs',
        url: Uri.parse('https://example.test/docs'),
      );
      final router = _router(
        providers: [_config('beta')],
        history: <ChatMessage>[
          ChatMessage.llm()..append('   '),
          ChatMessage(
            origin: MessageOrigin.llm,
            text: null,
            attachments: <Attachment>[link],
          ),
        ],
        adapters: {
          'beta': (config, messages) {
            seen.add(messages);
            return Stream<AdapterChunk>.value(const AdapterText('done'));
          },
        },
      );

      await router.sendMessageStream(
        '   ',
        attachments: <Attachment>[
          FileAttachment(
            name: 'a.txt',
            mimeType: 'text/plain',
            bytes: Uint8List.fromList(<int>[9]),
          ),
        ],
      ).drain<void>();

      expect(
        seen.single.map((turn) => '${turn.role.name}:${turn.text}').toList(),
        <String>[
          'assistant:${link.toString()}',
          'user:FileAttachment(name: a.txt, mimeType: text/plain, bytes: 1 bytes)',
        ],
      );
    });

    test('an empty user prompt is rejected before history changes', () async {
      final calls = <String>[];
      final router = _router(
        providers: [_config('beta')],
        adapters: {
          'beta': (config, messages) {
            calls.add(config.name);
            return Stream<AdapterChunk>.value(const AdapterText('nope'));
          },
        },
      );

      await expectLater(
        router.sendMessageStream('').toList(),
        throwsA(isA<AssertionError>()),
      );
      expect(router.history, isEmpty);
      expect(calls, isEmpty);
    });

    test('seeded history is copied, and the setter replaces it', () {
      final seed = <ChatMessage>[ChatMessage.user('seed', const [])];
      final router = _router(providers: [_config('beta')], history: seed);
      var notifications = 0;
      router.addListener(() => notifications++);

      seed.add(ChatMessage.user('later', const []));
      expect(router.history, hasLength(1));
      expect(router.history.single.text, 'seed');

      router.history = <ChatMessage>[
        ChatMessage.user('replaced', const []),
        ChatMessage.llm()..append('ok'),
      ];

      expect(notifications, 1);
      expect(
        router.history.map((message) => message.text).toList(),
        <String?>['replaced', 'ok'],
      );
    });
  });

  group('lifecycle and guards', () {
    test('providers must be non-empty and stay unmodifiable', () {
      expect(
        () => RouterLlmProvider(providers: const <ProviderConfig>[]),
        throwsA(isA<AssertionError>()),
      );

      final router = _router(providers: [_config('beta')]);
      expect(
        () => router.providers.add(_config('gamma')),
        throwsUnsupportedError,
      );
    });

    test('embeddings are not implemented and name the input length', () {
      final router = _router(providers: [_config('beta')]);

      expect(
        () => router.getDocumentEmbedding('abcdef'),
        throwsA(
          isA<UnimplementedError>().having(
            (error) => error.message,
            'message',
            contains('6 characters'),
          ),
        ),
      );
      expect(
        () => router.getQueryEmbedding(''),
        throwsA(
          isA<UnimplementedError>().having(
            (error) => error.message,
            'message',
            contains('0 characters'),
          ),
        ),
      );
    });

    test('dispose releases an owned tracker and leaves an injected one', () {
      final owned = RouterLlmProvider(providers: [_config('beta')]);
      final ownedTracker = owned.costTracker;
      owned.dispose();
      expect(() => ownedTracker.totalCost, throwsFlutterError);

      final injected = CostTracker();
      final router = RouterLlmProvider(
        providers: [_config('beta')],
        costTracker: injected,
      );
      router.dispose();
      injected.recordCost(0.5);
      expect(injected.totalCost, closeTo(0.5, 1e-12));
      injected.dispose();
    });

    test('dispose does not close adapters the caller injected', () {
      final client = MockClient((request) async => http.Response('', 200));
      addTearDown(client.close);
      final adapter = _CloseSpy(client);
      final router = RouterLlmProvider(
        providers: [_config('beta')],
        customAdapters: <String, BaseLlmAdapter>{'beta': adapter},
      );

      router.dispose();

      expect(adapter.closeCalls, 0);
    });
  });
}

ProviderConfig _config(
  String name, {
  String? model,
  double inputPrice = 0,
  double outputPrice = 0,
}) {
  return ProviderConfig(
    name: name,
    apiKey: 'sk-test',
    model: model ?? '$name-model',
    pricePerInputToken: inputPrice,
    pricePerOutputToken: outputPrice,
  );
}

typedef _Handler = Stream<AdapterChunk> Function(
  ProviderConfig config,
  List<ChatTurn> messages,
);

RouterLlmProvider _router({
  required List<ProviderConfig> providers,
  Map<String, _Handler> adapters = const <String, _Handler>{},
  Iterable<ChatMessage>? history,
}) {
  final clients = <http.Client>[];
  final custom = <String, BaseLlmAdapter>{};
  for (final entry in adapters.entries) {
    final client = MockClient((request) async => http.Response('', 200));
    clients.add(client);
    custom[entry.key] = _ScriptedAdapter(client, entry.value);
  }
  final router = RouterLlmProvider(
    providers: providers,
    history: history,
    customAdapters: custom,
  );
  addTearDown(() {
    router.dispose();
    for (final client in clients) {
      client.close();
    }
  });
  return router;
}

class _ScriptedAdapter extends BaseLlmAdapter {
  _ScriptedAdapter(http.Client client, this._handler) : super(client: client);

  final _Handler _handler;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    return _handler(config, messages);
  }
}

class _CloseSpy extends BaseLlmAdapter {
  _CloseSpy(http.Client client) : super(client: client);

  int closeCalls = 0;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    return const Stream<AdapterChunk>.empty();
  }

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}
