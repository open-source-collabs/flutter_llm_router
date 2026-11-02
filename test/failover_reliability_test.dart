import 'dart:async';
import 'dart:convert';

import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Failure classes that must fail over, stop cleanly, or be billed.
void main() {
  group('provider-scoped statuses', () {
    for (final status in <int>[401, 402, 403, 404]) {
      test('HTTP $status skips to the next provider', () async {
        await expectLater(
          _openAiWithResponse(http.Response('nope', status)).toList(),
          throwsA(
            isA<ProviderUnavailableLlmException>()
                .having((error) => error.statusCode, 'statusCode', status)
                .having(
                  (error) => error,
                  'retryable',
                  isA<RetryableLlmException>(),
                ),
          ),
        );
      });
    }

    test('a Gemini 400 for an invalid key is provider-scoped', () async {
      final client = MockClient(
        (request) async => http.Response(
          '{"error":{"code":400,"status":"INVALID_ARGUMENT",'
          '"details":[{"reason":"API_KEY_INVALID"}]}}',
          400,
        ),
      );
      addTearDown(client.close);

      await expectLater(
        GeminiAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')).toList(),
        throwsA(isA<ProviderUnavailableLlmException>()),
      );
    });

    test('any other Gemini 400 still stops the chain', () async {
      final client = MockClient(
        (request) async => http.Response('{"error":{"code":400}}', 400),
      );
      addTearDown(client.close);

      await expectLater(
        GeminiAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')).toList(),
        throwsA(isA<TerminalLlmException>()),
      );
    });

    test('an Anthropic 400 for low credit is provider-scoped', () async {
      final client = MockClient(
        (request) async => http.Response(
          '{"type":"error","error":{"type":"invalid_request_error",'
          '"message":"Your credit balance is too low to access the API."}}',
          400,
        ),
      );
      addTearDown(client.close);

      await expectLater(
        AnthropicAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')).toList(),
        throwsA(isA<ProviderUnavailableLlmException>()),
      );
    });

    test('the router fails over past a 401 and logs it', () async {
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const ProviderUnavailableLlmException('bad key', statusCode: 401),
          ),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('pong')),
        },
      );

      expect(await router.generateStream('ping').join(), 'pong');
      expect(router.lastAttemptLogs.first.statusCode, 401);
      expect(router.lastAttemptLogs.last.isSuccess, isTrue);
    });
  });

  group('timeouts', () {
    test('a stream that stalls after headers fails over', () async {
      final client = MockClient.streaming((request, body) async {
        final stalled = StreamController<List<int>>();
        stalled.add(utf8.encode('data: {"choices":[]}\n\n'));
        addTearDown(stalled.close);
        return http.StreamedResponse(stalled.stream, 200);
      });
      addTearDown(client.close);

      await expectLater(
        OpenAiAdapter(client: client)
            .streamCompletion(
              config: _config(idleTimeout: const Duration(milliseconds: 50)),
              messages: _turns('hi'),
            )
            .toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.message,
            'message',
            contains('idle'),
          ),
        ),
      );
    });

    test('a slow drip of keep-alives still hits the deadline', () async {
      final client = MockClient.streaming((request, body) async {
        final drip = Stream<List<int>>.periodic(
          const Duration(milliseconds: 10),
          (_) => utf8.encode(': ping\n\n'),
        );
        return http.StreamedResponse(drip, 200);
      });
      addTearDown(client.close);

      await expectLater(
        OpenAiAdapter(client: client)
            .streamCompletion(
              config: _config(deadline: const Duration(milliseconds: 80)),
              messages: _turns('hi'),
            )
            .toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.message,
            'message',
            contains('deadline'),
          ),
        ),
      );
    });

    test('an error body that never finishes is bounded', () async {
      final client = MockClient.streaming((request, body) async {
        return http.StreamedResponse(StreamController<List<int>>().stream, 503);
      });
      addTearDown(client.close);

      await expectLater(
        OpenAiAdapter(client: client)
            .streamCompletion(
              config: _config(timeout: const Duration(milliseconds: 50)),
              messages: _turns('hi'),
            )
            .toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });

    test('a timed-out request is aborted', () async {
      final aborted = Completer<void>();
      final client = MockClient.streaming((request, body) {
        if (request case http.Abortable(:final abortTrigger?)) {
          unawaited(abortTrigger.then((_) => aborted.complete()));
        }
        return Completer<http.StreamedResponse>().future;
      });
      addTearDown(client.close);

      await expectLater(
        OpenAiAdapter(client: client)
            .streamCompletion(
              config: _config(timeout: const Duration(milliseconds: 30)),
              messages: _turns('hi'),
            )
            .toList(),
        throwsA(isA<RetryableLlmException>()),
      );
      await aborted.future.timeout(const Duration(seconds: 1));
    });
  });

  group('errors outside the router exceptions', () {
    test('a non-ClientException transport error is retryable', () async {
      final client = MockClient((request) async => throw const _TlsFailure());
      addTearDown(client.close);

      await expectLater(
        OpenAiAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')).toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.cause,
            'cause',
            isA<_TlsFailure>(),
          ),
        ),
      );
    });

    test('a custom adapter exception fails over and is logged', () async {
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        adapters: {
          'alpha': (config, messages) =>
              Stream<AdapterChunk>.error(const FormatException('bad url')),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('pong')),
        },
      );

      expect(await router.generateStream('ping').join(), 'pong');
      expect(router.lastAttemptLogs.first.error, contains('bad url'));
    });

    test(
      'an adapter that throws before returning a stream fails over',
      () async {
        final router = _router(
          providers: [
            _config(name: 'alpha'),
            _config(name: 'beta'),
          ],
          adapters: {
            'alpha': (config, messages) => throw const _TlsFailure(),
            'beta': (config, messages) =>
                Stream<AdapterChunk>.value(const AdapterText('pong')),
          },
        );

        expect(await router.generateStream('ping').join(), 'pong');
        expect(router.lastAttemptLogs, hasLength(2));
      },
    );
  });

  group('in-band errors', () {
    test('an OpenAI error chunk inside a 200 stream is retryable', () async {
      await expectLater(
        _openAiWithSse(
          'data: {"error":{"message":"Upstream overloaded","code":502}}\n\n',
        ).toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.message,
            'message',
            contains('Upstream overloaded'),
          ),
        ),
      );
    });

    test('an Anthropic error event inside a 200 stream is retryable', () async {
      final client = _sseClient(
        'event: error\n'
        'data: {"type":"error","error":{"type":"overloaded_error",'
        '"message":"Overloaded"}}\n\n',
      );

      await expectLater(
        AnthropicAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')).toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.message,
            'message',
            contains('Overloaded'),
          ),
        ),
      );
    });

    test('a Gemini blocked prompt is retryable', () async {
      final client = _sseClient(
        'data: {"promptFeedback":{"blockReason":"SAFETY"}}\n\n',
      );

      await expectLater(
        GeminiAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')).toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.message,
            'message',
            contains('SAFETY'),
          ),
        ),
      );
    });

    test('a reply with no text fails over instead of succeeding', () async {
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.fromIterable(
            const <AdapterChunk>[AdapterText(''), AdapterUsage(inputTokens: 3)],
          ),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('pong')),
        },
      );

      expect(await router.generateStream('ping').join(), 'pong');
      expect(router.lastAttemptLogs.first.isSuccess, isFalse);
      expect(router.lastAttemptLogs.first.error, contains('no text'));
    });
  });

  group('cancellation', () {
    test('cancelling stops the chain and the pending attempt', () async {
      final adapterCancelled = Completer<void>();
      var betaCalls = 0;
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        adapters: {
          'alpha': (config, messages) {
            final pending = StreamController<AdapterChunk>(
              onCancel: () => adapterCancelled.complete(),
            );
            return pending.stream;
          },
          'beta': (config, messages) {
            betaCalls++;
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          },
        },
      );

      final subscription = router.generateStream('ping').listen(null);
      await _settle();
      await subscription.cancel();
      await adapterCancelled.future.timeout(const Duration(seconds: 1));
      await _settle();

      expect(betaCalls, 0);
      expect(router.lastAttemptLogs.single.error, contains('Cancelled'));
    });

    test('cancelling sendMessageStream stops the chain', () async {
      var betaCalls = 0;
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        adapters: {
          'alpha': (config, messages) =>
              StreamController<AdapterChunk>().stream,
          'beta': (config, messages) {
            betaCalls++;
            return Stream<AdapterChunk>.value(const AdapterText('pong'));
          },
        },
      );

      final subscription = router.sendMessageStream('ping').listen(null);
      await _settle();
      await subscription.cancel().timeout(const Duration(seconds: 1));
      await _settle();

      expect(betaCalls, 0);
    });

    test('cancelling closes the HTTP request', () async {
      final aborted = Completer<void>();
      final client = MockClient.streaming((request, body) async {
        if (request case http.Abortable(:final abortTrigger?)) {
          unawaited(abortTrigger.then((_) => aborted.complete()));
        }
        final open = StreamController<List<int>>();
        open.add(
          utf8.encode('data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n'),
        );
        addTearDown(open.close);
        return http.StreamedResponse(open.stream, 200);
      });
      addTearDown(client.close);

      final chunks = StreamIterator(
        OpenAiAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')),
      );
      expect(await chunks.moveNext(), isTrue);
      await chunks.cancel();

      await aborted.future.timeout(const Duration(seconds: 1));
    });

    test('a cancelled partial reply is billed by estimate', () async {
      final router = _router(
        providers: [_config(name: 'alpha', price: 1)],
        adapters: {
          'alpha': (config, messages) {
            final open = StreamController<AdapterChunk>();
            open.add(const AdapterText('Hello'));
            return open.stream;
          },
        },
      );

      final first = StreamIterator(router.generateStream('ping'));
      expect(await first.moveNext(), isTrue);
      await first.cancel();
      await _settle();

      expect(router.costTracker.totalInputTokens, 1);
      expect(router.costTracker.totalOutputTokens, 2);
    });

    test('a mid-stream failure is billed by estimate', () async {
      final router = _router(
        providers: [_config(name: 'alpha', price: 1)],
        adapters: {
          'alpha': (config, messages) async* {
            yield const AdapterText('Hello');
            throw const RetryableLlmException('reset', statusCode: 503);
          },
        },
      );

      await expectLater(
        router.generateStream('ping').drain<void>(),
        throwsA(isA<RetryableLlmException>()),
      );
      expect(router.costTracker.totalOutputTokens, 2);
    });
  });

  group('lifecycle', () {
    test('disposing during a stream ends it without errors', () async {
      final router = _router(
        providers: [_config(name: 'alpha')],
        adapters: {
          'alpha': (config, messages) {
            final open = StreamController<AdapterChunk>();
            open.add(const AdapterText('Hel'));
            return open.stream;
          },
        },
      );

      final done = Completer<void>();
      router
          .sendMessageStream('ping')
          .listen(null, onError: (Object _) {}, onDone: done.complete);
      await _settle();
      router.dispose();

      await done.future.timeout(const Duration(seconds: 1));
      await _settle();
    });

    test('dispose can be called twice', () {
      final router = _router(providers: [_config(name: 'alpha')]);
      router.dispose();
      router.dispose();
    });

    test('an empty provider list throws in release builds too', () {
      expect(
        () => RouterLlmProvider(providers: const <ProviderConfig>[]),
        throwsArgumentError,
      );
    });
  });

  group('history', () {
    test('a failed send is not resent with the next prompt', () async {
      var fail = true;
      List<ChatTurn>? sent;
      final router = _router(
        providers: [_config(name: 'alpha')],
        adapters: {
          'alpha': (config, messages) {
            if (fail) {
              fail = false;
              return Stream<AdapterChunk>.error(
                const RetryableLlmException('busy', statusCode: 503),
              );
            }
            sent = messages;
            return Stream<AdapterChunk>.value(const AdapterText('ok'));
          },
        },
      );

      await expectLater(
        router.sendMessageStream('first').drain<void>(),
        throwsA(isA<AllProvidersFailedException>()),
      );
      expect(await router.sendMessageStream('second').join(), 'ok');

      expect(sent!.map((turn) => turn.text), <String>['second']);
      expect(router.history, hasLength(4));
    });
  });

  group('attempt logs', () {
    test('a slower earlier call does not overwrite a newer call', () async {
      var call = 0;
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        adapters: {
          'alpha': (config, messages) async* {
            call++;
            if (call == 1) {
              await Future<void>.delayed(const Duration(milliseconds: 40));
              throw const RetryableLlmException('busy', statusCode: 503);
            }
            yield const AdapterText('fast');
          },
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('slow')),
        },
      );

      final slow = router.generateStream('one').join();
      await _settle();
      final fast = router.generateStream('two').join();
      expect(await fast, 'fast');
      expect(await slow, 'slow');

      expect(router.lastAttemptLogs, hasLength(1));
      expect(router.lastAttemptLogs.single.providerName, 'alpha');
    });

    test('attemptLogs notifies listeners as attempts finish', () async {
      final router = _router(
        providers: [_config(name: 'alpha')],
        adapters: {
          'alpha': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('pong')),
        },
      );
      final seen = <int>[];
      router.attemptLogs.addListener(
        () => seen.add(router.attemptLogs.value.length),
      );

      await router.generateStream('ping').drain<void>();

      expect(seen, contains(1));
    });
  });

  group('connectivity', () {
    test('a local provider does not trigger the internet probe', () async {
      final connectivity = _FakeConnectivity(online: false);
      final router = _router(
        providers: [
          _config(name: 'alpha', baseUrl: 'http://localhost:11434/v1'),
          _config(name: 'beta'),
        ],
        connectivity: connectivity,
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            RetryableLlmException(
              'refused',
              cause: http.ClientException('Connection refused'),
            ),
          ),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('pong')),
        },
      );

      expect(await router.generateStream('ping').join(), 'pong');
      expect(connectivity.calls, 0);
    });

    test('a probe timeout counts as online', () async {
      final client = MockClient((request) => Completer<http.Response>().future);
      addTearDown(client.close);

      final checker = HttpConnectivityChecker(
        client: client,
        timeout: const Duration(milliseconds: 20),
      );

      expect(await checker.hasInternet(), isTrue);
    });

    test('a blocked default probe falls back to a second host', () async {
      final probed = <Uri>[];
      final client = MockClient((request) async {
        probed.add(request.url);
        if (request.url == HttpConnectivityChecker.defaultProbeUrl) {
          throw http.ClientException('blocked');
        }
        return http.Response('', 204);
      });
      addTearDown(client.close);

      expect(
        await HttpConnectivityChecker(client: client).hasInternet(),
        isTrue,
      );
      expect(probed, [
        HttpConnectivityChecker.defaultProbeUrl,
        HttpConnectivityChecker.fallbackProbeUrl,
      ]);
    });

    test('a custom probe URL has no fallback', () async {
      final probed = <Uri>[];
      final client = MockClient((request) async {
        probed.add(request.url);
        throw http.ClientException('blocked');
      });
      addTearDown(client.close);
      final probeUrl = Uri.parse('https://example.com/ping');

      final checker = HttpConnectivityChecker(
        probeUrl: probeUrl,
        client: client,
      );

      expect(await checker.hasInternet(), isFalse);
      expect(probed, [probeUrl]);
    });

    test('AssumeOnlineConnectivityChecker never reports offline', () async {
      expect(
        await const AssumeOnlineConnectivityChecker().hasInternet(),
        isTrue,
      );
    });
  });

  group('vendor requests', () {
    test('OpenAI sends max_completion_tokens to the default host', () async {
      final body = await _capturedOpenAiBody(_config());

      expect(body['max_completion_tokens'], 1024);
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('a custom OpenAI-compatible host gets max_tokens', () async {
      final body = await _capturedOpenAiBody(
        _config(baseUrl: 'http://localhost:11434/v1'),
      );

      expect(body['max_tokens'], 1024);
      expect(body.containsKey('max_completion_tokens'), isFalse);
    });

    test('requestStreamUsage false omits stream_options', () async {
      final body = await _capturedOpenAiBody(
        _config(requestStreamUsage: false),
      );

      expect(body.containsKey('stream_options'), isFalse);
    });

    test('custom headers are sent and can replace auth', () async {
      late http.BaseRequest seen;
      final client = MockClient.streaming((request, body) async {
        seen = request;
        await body.drain<void>();
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'),
          ),
          200,
        );
      });
      addTearDown(client.close);

      await OpenAiAdapter(client: client)
          .streamCompletion(
            config: _config(
              headers: const {
                'authorization': 'Bearer proxy-token',
                'x-app-id': 'demo',
              },
            ),
            messages: _turns('hi'),
          )
          .drain<void>();

      expect(seen.headers['authorization'], 'Bearer proxy-token');
      expect(seen.headers['x-app-id'], 'demo');
    });

    test('Gemini thinking tokens are billed as output', () async {
      final client = _sseClient(
        'data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]}}],'
        '"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3,'
        '"thoughtsTokenCount":20}}\n\n',
      );

      final chunks = await GeminiAdapter(
        client: client,
      ).streamCompletion(config: _config(), messages: _turns('hi')).toList();

      expect(chunks.whereType<AdapterUsage>().single.outputTokens, 23);
    });
  });
}

class _TlsFailure implements Exception {
  const _TlsFailure();

  @override
  String toString() => 'HandshakeException: certificate rejected';
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

List<ChatTurn> _turns(String text) => <ChatTurn>[
  ChatTurn(role: ChatTurnRole.user, text: text),
];

ProviderConfig _config({
  String name = 'primary',
  double price = 0,
  String? baseUrl,
  Duration timeout = const Duration(seconds: 30),
  Duration? idleTimeout = const Duration(seconds: 60),
  Duration? deadline,
  bool requestStreamUsage = true,
  Map<String, String> headers = const <String, String>{},
}) {
  return ProviderConfig(
    name: name,
    apiKey: 'sk-test',
    model: '$name-model',
    pricePerInputToken: price,
    pricePerOutputToken: price,
    baseUrl: baseUrl,
    timeout: timeout,
    idleTimeout: idleTimeout,
    deadline: deadline,
    requestStreamUsage: requestStreamUsage,
    headers: headers,
  );
}

http.Client _sseClient(String sse) {
  final client = MockClient.streaming((request, body) async {
    await body.drain<void>();
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(sse)),
      200,
    );
  });
  addTearDown(client.close);
  return client;
}

Stream<AdapterChunk> _openAiWithSse(String sse) {
  return OpenAiAdapter(
    client: _sseClient(sse),
  ).streamCompletion(config: _config(), messages: _turns('hi'));
}

Stream<AdapterChunk> _openAiWithResponse(http.Response response) {
  final client = MockClient((request) async => response);
  addTearDown(client.close);
  return OpenAiAdapter(
    client: client,
  ).streamCompletion(config: _config(), messages: _turns('hi'));
}

Future<Map<String, dynamic>> _capturedOpenAiBody(ProviderConfig config) async {
  late Map<String, dynamic> captured;
  final client = MockClient.streaming((request, body) async {
    captured =
        jsonDecode(utf8.decode(await body.toBytes())) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'),
      ),
      200,
    );
  });
  addTearDown(client.close);

  await OpenAiAdapter(
    client: client,
  ).streamCompletion(config: config, messages: _turns('hi')).drain<void>();
  return captured;
}

class _FakeConnectivity implements ConnectivityChecker {
  _FakeConnectivity({required this.online});

  final bool online;
  int calls = 0;

  @override
  Future<bool> hasInternet() async {
    calls++;
    return online;
  }
}

typedef _Handler =
    Stream<AdapterChunk> Function(
      ProviderConfig config,
      List<ChatTurn> messages,
    );

RouterLlmProvider _router({
  required List<ProviderConfig> providers,
  Map<String, _Handler> adapters = const <String, _Handler>{},
  ConnectivityChecker? connectivity,
}) {
  final client = MockClient((request) async => http.Response('', 200));
  final router = RouterLlmProvider(
    providers: providers,
    customAdapters: <String, BaseLlmAdapter>{
      for (final entry in adapters.entries)
        entry.key: _ScriptedAdapter(client, entry.value),
    },
    connectivityChecker: connectivity ?? _FakeConnectivity(online: true),
  );
  addTearDown(() {
    router.dispose();
    client.close();
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
