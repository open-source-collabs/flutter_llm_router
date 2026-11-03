import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// API key pools: rotation, benching a rate-limited key, and falling through
/// to the next provider only when every key is spent.
void main() {
  group('ProviderConfig.allKeys', () {
    test('puts apiKey first and drops duplicates and blanks', () {
      expect(_config(apiKeys: ['b', 'a', '', 'b']).allKeys, <String>['a', 'b']);
    });

    test('copyWith keeps and replaces the pool', () {
      final config = _config(apiKeys: ['b']);
      expect(config.copyWith(model: 'x').apiKeys, <String>['b']);
      expect(config.copyWith(apiKeys: ['c']).allKeys, <String>['a', 'c']);
    });
  });

  group('key pool routing', () {
    test('round robin starts each request on the next key', () async {
      final used = <String>[];
      final router = _router(
        providers: [
          _config(apiKeys: ['b', 'c']),
        ],
        handler: (config, _) {
          used.add(config.apiKey);
          return Stream<AdapterChunk>.value(const AdapterText('ok'));
        },
      );
      for (var i = 0; i < 4; i++) {
        await router.generateStream('hi').join();
      }
      expect(used, <String>['a', 'b', 'c', 'a']);
      expect(router.lastAttemptLogs.single.keyIndex, 0);
    });

    test('priority rotation always starts on the first key', () async {
      final used = <String>[];
      final router = _router(
        providers: [
          _config(apiKeys: ['b']),
        ],
        keyPool: const KeyPoolPolicy(rotation: KeyRotation.priority),
        handler: (config, _) {
          used.add(config.apiKey);
          return Stream<AdapterChunk>.value(const AdapterText('ok'));
        },
      );
      for (var i = 0; i < 3; i++) {
        await router.generateStream('hi').join();
      }
      expect(used, <String>['a', 'a', 'a']);
    });

    test('a 429 moves to the next key on the same provider', () async {
      final used = <String>[];
      final router = _router(
        providers: [
          _config(apiKeys: ['b']),
          _config(name: 'other'),
        ],
        keyPool: const KeyPoolPolicy(rotation: KeyRotation.priority),
        handler: (config, _) {
          used.add('${config.name}:${config.apiKey}');
          if (config.apiKey == 'a') {
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('HTTP 429', statusCode: 429),
            );
          }
          return Stream<AdapterChunk>.value(const AdapterText('ok'));
        },
      );

      expect(await router.generateStream('hi').join(), 'ok');
      expect(used, <String>['main:a', 'main:b']);
      expect(router.lastAttemptLogs.map((log) => log.keyIndex), [0, 1]);

      // Key a is resting, so the next request goes straight to b.
      used.clear();
      await router.generateStream('hi').join();
      expect(used, <String>['main:b']);
    });

    test('a rejected key (401) is benched too', () async {
      final used = <String>[];
      final router = _router(
        providers: [
          _config(apiKeys: ['b']),
        ],
        keyPool: const KeyPoolPolicy(rotation: KeyRotation.priority),
        handler: (config, _) {
          used.add(config.apiKey);
          if (config.apiKey == 'a') {
            return Stream<AdapterChunk>.error(
              const ProviderUnavailableLlmException(
                'HTTP 401',
                statusCode: 401,
              ),
            );
          }
          return Stream<AdapterChunk>.value(const AdapterText('ok'));
        },
      );
      expect(await router.generateStream('hi').join(), 'ok');
      expect(used, <String>['a', 'b']);
    });

    test('a 503 is not the key\'s fault and does not rotate', () async {
      final used = <String>[];
      final router = _router(
        providers: [
          _config(apiKeys: ['b']),
          _config(name: 'other'),
        ],
        handler: (config, _) {
          used.add('${config.name}:${config.apiKey}');
          if (config.name == 'main') {
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('HTTP 503', statusCode: 503),
            );
          }
          return Stream<AdapterChunk>.value(const AdapterText('ok'));
        },
      );
      expect(await router.generateStream('hi').join(), 'ok');
      expect(used, <String>['main:a', 'other:a']);
    });

    test('fails over to the next provider once every key is spent', () async {
      final used = <String>[];
      final router = _router(
        providers: [
          _config(apiKeys: ['b']),
          _config(name: 'other'),
        ],
        handler: (config, _) {
          used.add('${config.name}:${config.apiKey}');
          if (config.name == 'main') {
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('HTTP 429', statusCode: 429),
            );
          }
          return Stream<AdapterChunk>.value(const AdapterText('ok'));
        },
      );
      expect(await router.generateStream('hi').join(), 'ok');
      expect(used, <String>['main:a', 'main:b', 'other:a']);

      // Both keys are resting now, so the provider is skipped with a reason.
      used.clear();
      await router.generateStream('hi').join();
      expect(used, <String>['other:a']);
      expect(
        router.lastAttemptLogs.first.skipReason,
        contains('API keys are cooling down'),
      );
    });

    test('Retry-After sets how long a key rests', () async {
      final used = <String>[];
      final router = _router(
        providers: [
          _config(apiKeys: ['b']),
        ],
        keyPool: const KeyPoolPolicy(
          rotation: KeyRotation.priority,
          rateLimitCooldown: Duration(hours: 1),
        ),
        handler: (config, _) {
          used.add(config.apiKey);
          if (config.apiKey == 'a' && used.length == 1) {
            return Stream<AdapterChunk>.error(
              const RetryableLlmException(
                'HTTP 429',
                statusCode: 429,
                retryAfter: Duration(milliseconds: 1),
              ),
            );
          }
          return Stream<AdapterChunk>.value(const AdapterText('ok'));
        },
      );
      await router.generateStream('hi').join();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await router.generateStream('hi').join();
      expect(used, <String>['a', 'b', 'a']);
    });

    test('a single key behaves as before and logs no key index', () async {
      var calls = 0;
      final router = _router(
        providers: [_config()],
        handler: (config, _) {
          calls++;
          return Stream<AdapterChunk>.error(
            const RetryableLlmException('HTTP 429', statusCode: 429),
          );
        },
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          router.generateStream('hi').join(),
          throwsA(isA<AllProvidersFailedException>()),
        );
      }
      expect(calls, 2);
      expect(router.lastAttemptLogs.single.keyIndex, isNull);
    });
  });
}

typedef _Handler =
    Stream<AdapterChunk> Function(
      ProviderConfig config,
      List<ChatTurn> messages,
    );

ProviderConfig _config({
  String name = 'main',
  List<String> apiKeys = const [],
}) {
  return ProviderConfig(
    name: name,
    apiKey: 'a',
    apiKeys: apiKeys,
    model: '$name-model',
    pricePerInputToken: 0,
    pricePerOutputToken: 0,
  );
}

RouterLlmProvider _router({
  required List<ProviderConfig> providers,
  required _Handler handler,
  KeyPoolPolicy keyPool = const KeyPoolPolicy(),
}) {
  final client = MockClient((request) async => http.Response('', 200));
  final router = RouterLlmProvider(
    providers: providers,
    keyPool: keyPool,
    customAdapters: <String, BaseLlmAdapter>{
      for (final provider in providers)
        provider.name: _ScriptedAdapter(client, handler),
    },
    connectivityChecker: const AssumeOnlineConnectivityChecker(),
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
  }) => _handler(config, messages);
}
