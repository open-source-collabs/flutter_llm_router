import 'dart:async';
import 'dart:math';

import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Retry, circuit breaker, routing strategies, budgets, events, and the
/// response cache.
void main() {
  const fastRetry = RetryPolicy(
    maxRetries: 2,
    initialDelay: Duration(milliseconds: 1),
    maxDelay: Duration(milliseconds: 20),
    jitter: 0,
  );

  group('RetryPolicy', () {
    test('waits grow exponentially and stop at maxDelay', () {
      const policy = RetryPolicy(
        maxRetries: 5,
        initialDelay: Duration(milliseconds: 100),
        maxDelay: Duration(milliseconds: 350),
        jitter: 0,
      );
      const failure = RetryableLlmException('HTTP 503', statusCode: 503);
      expect(
        <Duration?>[
          for (var retry = 0; retry < 6; retry++)
            policy.delayFor(retry, failure),
        ],
        <Duration?>[
          const Duration(milliseconds: 100),
          const Duration(milliseconds: 200),
          const Duration(milliseconds: 350),
          const Duration(milliseconds: 350),
          const Duration(milliseconds: 350),
          null,
        ],
      );
    });

    test('jitter stays within its fraction', () {
      const policy = RetryPolicy(
        initialDelay: Duration(milliseconds: 1000),
        jitter: 0.2,
      );
      const failure = RetryableLlmException('HTTP 503', statusCode: 503);
      final random = Random(1);
      for (var i = 0; i < 50; i++) {
        final delay = policy.delayFor(0, failure, random: random)!;
        expect(delay.inMilliseconds, inInclusiveRange(800, 1200));
      }
    });

    test('Retry-After replaces the wait, unless it is too long', () {
      const policy = RetryPolicy(maxDelay: Duration(seconds: 5));
      expect(
        policy.delayFor(
          0,
          const RetryableLlmException(
            'HTTP 429',
            statusCode: 429,
            retryAfter: Duration(seconds: 3),
          ),
        ),
        const Duration(seconds: 3),
      );
      expect(
        policy.delayFor(
          0,
          const RetryableLlmException(
            'HTTP 429',
            statusCode: 429,
            retryAfter: Duration(seconds: 30),
          ),
        ),
        isNull,
      );
    });

    test('only transient failures are retried', () {
      const policy = RetryPolicy();
      expect(
        policy.shouldRetry(const RetryableLlmException('x', statusCode: 429)),
        isTrue,
      );
      expect(
        policy.shouldRetry(
          RetryableLlmException('x', cause: TimeoutException('t')),
        ),
        isTrue,
      );
      expect(
        policy.shouldRetry(
          const ProviderUnavailableLlmException('x', statusCode: 401),
        ),
        isFalse,
      );
      expect(
        policy.shouldRetry(const TerminalLlmException('x', statusCode: 400)),
        isFalse,
      );
      expect(
        policy.shouldRetry(const RetryableLlmException('returned no text')),
        isFalse,
      );
      expect(
        policy.shouldRetry(
          const RetryableLlmException('x', cause: FormatException('bad')),
        ),
        isFalse,
      );
    });

    test('the router retries the same provider before failing over', () async {
      var calls = 0;
      final router = _router(
        providers: [_config('alpha'), _config('beta')],
        retryPolicy: fastRetry,
        adapters: {
          'alpha': (config, messages) {
            calls++;
            if (calls < 3) {
              return Stream<AdapterChunk>.error(
                const RetryableLlmException('HTTP 503', statusCode: 503),
              );
            }
            return Stream<AdapterChunk>.value(const AdapterText('third time'));
          },
        },
      );

      expect(await router.generateStream('hi').join(), 'third time');
      expect(calls, 3);
      expect(router.lastAttemptLogs.map((log) => log.retry), <int>[0, 1, 2]);
      expect(router.lastAttemptLogs.last.isSuccess, isTrue);
    });

    test('after the last retry the router fails over', () async {
      final router = _router(
        providers: [_config('alpha'), _config('beta')],
        retryPolicy: fastRetry,
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const RetryableLlmException('HTTP 429', statusCode: 429),
          ),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('beta')),
        },
      );

      expect(await router.generateStream('hi').join(), 'beta');
      expect(
        router.lastAttemptLogs.map((log) => '${log.providerName}${log.retry}'),
        <String>['alpha0', 'alpha1', 'alpha2', 'beta0'],
      );
    });

    test('cancelling during a retry wait stops the request', () async {
      var calls = 0;
      final router = _router(
        providers: [_config('alpha'), _config('beta')],
        retryPolicy: const RetryPolicy(
          maxRetries: 1,
          initialDelay: Duration(seconds: 30),
          jitter: 0,
          maxDelay: Duration(seconds: 30),
        ),
        adapters: {
          'alpha': (config, messages) {
            calls++;
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('HTTP 503', statusCode: 503),
            );
          },
          'beta': (config, messages) {
            calls++;
            return Stream<AdapterChunk>.value(const AdapterText('beta'));
          },
        },
      );

      final subscription = router.generateStream('hi').listen((_) {});
      await _settle();
      await subscription.cancel();
      await _settle();
      expect(calls, 1);
    });
  });

  group('circuit breaker', () {
    test(
      'opens after the threshold, skips, then closes after a trial',
      () async {
        var alphaFails = true;
        final events = <CircuitStateChanged>[];
        final router = _router(
          providers: [_config('alpha'), _config('beta')],
          circuitBreaker: const CircuitBreakerPolicy(
            failureThreshold: 2,
            cooldown: Duration(milliseconds: 60),
          ),
          adapters: {
            'alpha': (config, messages) => alphaFails
                ? Stream<AdapterChunk>.error(
                    const RetryableLlmException('HTTP 503', statusCode: 503),
                  )
                : Stream<AdapterChunk>.value(const AdapterText('alpha')),
            'beta': (config, messages) =>
                Stream<AdapterChunk>.value(const AdapterText('beta')),
          },
        );
        router.events.only<CircuitStateChanged>().listen(events.add);

        await router.generateStream('1').drain<void>();
        expect(
          router.providerHealth.value['alpha/alpha-model']?.state,
          CircuitState.closed,
        );
        await router.generateStream('2').drain<void>();
        expect(
          router.providerHealth.value['alpha/alpha-model']?.state,
          CircuitState.open,
        );

        await router.generateStream('3').drain<void>();
        final skipped = router.lastAttemptLogs.first;
        expect(skipped.isSkipped, isTrue);
        expect(skipped.skipReason, startsWith('Circuit open'));
        expect(router.lastAttemptLogs.last.providerName, 'beta');

        alphaFails = false;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(await router.generateStream('4').join(), 'alpha');
        expect(
          router.providerHealth.value['alpha/alpha-model']?.state,
          CircuitState.closed,
        );
        await _settle();
        expect(events.map((event) => event.to), <CircuitState>[
          CircuitState.open,
          CircuitState.halfOpen,
          CircuitState.closed,
        ]);
      },
    );

    test('a failed trial reopens the circuit', () async {
      final router = _router(
        providers: [_config('alpha'), _config('beta')],
        circuitBreaker: const CircuitBreakerPolicy(
          failureThreshold: 1,
          cooldown: Duration(milliseconds: 30),
        ),
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const RetryableLlmException('HTTP 503', statusCode: 503),
          ),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('beta')),
        },
      );

      await router.generateStream('1').drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await router.generateStream('2').drain<void>();
      expect(router.lastAttemptLogs.first.isSkipped, isFalse);
      expect(
        router.providerHealth.value['alpha/alpha-model']?.state,
        CircuitState.open,
      );
    });

    test('when every circuit is open the router tries anyway', () async {
      var calls = 0;
      final router = _router(
        providers: [_config('alpha')],
        circuitBreaker: const CircuitBreakerPolicy(
          failureThreshold: 1,
          cooldown: Duration(minutes: 5),
        ),
        adapters: {
          'alpha': (config, messages) {
            calls++;
            return calls == 1
                ? Stream<AdapterChunk>.error(
                    const RetryableLlmException('HTTP 503', statusCode: 503),
                  )
                : Stream<AdapterChunk>.value(const AdapterText('back'));
          },
        },
      );

      await expectLater(
        router.generateStream('1').join(),
        throwsA(isA<AllProvidersFailedException>()),
      );
      expect(await router.generateStream('2').join(), 'back');
    });

    test('terminal failures do not count and resetCircuits closes', () async {
      final router = _router(
        providers: [_config('alpha'), _config('beta')],
        circuitBreaker: const CircuitBreakerPolicy(
          failureThreshold: 1,
          cooldown: Duration(minutes: 5),
        ),
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const ProviderUnavailableLlmException('bad key', statusCode: 401),
          ),
          'beta': (config, messages) => Stream<AdapterChunk>.error(
            const TerminalLlmException('HTTP 400', statusCode: 400),
          ),
        },
      );

      await expectLater(
        router.generateStream('1').join(),
        throwsA(isA<TerminalLlmException>()),
      );
      final health = router.providerHealth.value;
      expect(health['alpha/alpha-model']?.state, CircuitState.open);
      expect(health['beta/beta-model']?.state, CircuitState.closed);

      router.resetCircuits();
      expect(
        router.providerHealth.value['alpha/alpha-model']?.state,
        CircuitState.closed,
      );
    });

    test('health records successes and time to first token', () async {
      final router = _router(
        providers: [_config('alpha')],
        adapters: {
          'alpha': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('ok')),
        },
      );

      await router.generateStream('1').drain<void>();
      final health = router.providerHealth.value['alpha/alpha-model']!;
      expect(health.successes, 1);
      expect(health.averageTimeToFirstTokenMs, isNotNull);
      expect(health.state, CircuitState.closed);
    });
  });

  group('routing strategies', () {
    final cheap = _config('cheap', input: 0.000001, output: 0.000002);
    final pricey = _config('pricey', input: 0.00001, output: 0.00003);
    final free = _config('free');

    test('priority keeps the configured order', () {
      expect(const PriorityRoutingStrategy().order([pricey, cheap], const {}), [
        pricey,
        cheap,
      ]);
    });

    test('cheapest first sorts by price and keeps ties stable', () {
      final alsoFree = _config('also-free');
      expect(
        const CheapestFirstRoutingStrategy().order([
          pricey,
          free,
          cheap,
          alsoFree,
        ], const {}),
        [free, alsoFree, cheap, pricey],
      );
    });

    test('lowest latency measures unknown providers first', () {
      final health = <String, ProviderHealth>{
        cheap.id: ProviderHealth(
          providerId: cheap.id,
          averageTimeToFirstTokenMs: 900,
        ),
        pricey.id: ProviderHealth(
          providerId: pricey.id,
          averageTimeToFirstTokenMs: 200,
        ),
      };
      expect(
        const LowestLatencyRoutingStrategy().order([
          cheap,
          pricey,
          free,
        ], health),
        [free, pricey, cheap],
      );
    });

    test('weighted draws follow the weights and keep every provider', () {
      final strategy = WeightedRoutingStrategy(<String, double>{
        'cheap': 3,
        'pricey': 1,
        'free': 0,
      }, random: Random(7));
      final firsts = <String, int>{};
      for (var i = 0; i < 400; i++) {
        final order = strategy.order([cheap, pricey, free], const {});
        expect(order.toSet(), {cheap, pricey, free});
        expect(order.last, free);
        firsts.update(order.first.name, (n) => n + 1, ifAbsent: () => 1);
      }
      expect(firsts['cheap']!, greaterThan(250));
      expect(firsts['pricey']!, greaterThan(50));
      expect(firsts['free'], isNull);
    });

    test('the router follows the strategy', () async {
      final router = _router(
        providers: [pricey, cheap],
        routingStrategy: const CheapestFirstRoutingStrategy(),
        adapters: {
          'pricey': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('pricey')),
          'cheap': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('cheap')),
        },
      );
      expect(await router.generateStream('hi').join(), 'cheap');
    });
  });

  group('budgets', () {
    test('a provider over its limit is skipped for the next one', () async {
      final tracker = CostTracker();
      addTearDown(tracker.dispose);
      final big = _config('big', input: 1, output: 1);
      tracker.recordUsage(config: big, inputTokens: 5, outputTokens: 0);
      final router = _router(
        providers: [big, _config('small', input: 0.1, output: 0.1)],
        tracker: tracker,
        budget: const BudgetPolicy(providerLimitsUsd: {'big': 5}),
        adapters: {
          'big': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('big')),
          'small': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('small')),
        },
      );

      expect(await router.generateStream('hi').join(), 'small');
      expect(router.lastAttemptLogs.first.skipReason, contains('big'));
    });

    test('over the session limit only free providers run', () async {
      final tracker = CostTracker();
      addTearDown(tracker.dispose);
      final paid = _config('paid', input: 1, output: 1);
      tracker.recordUsage(config: paid, inputTokens: 10, outputTokens: 0);
      final router = _router(
        providers: [paid, _config('local')],
        tracker: tracker,
        budget: const BudgetPolicy(sessionLimitUsd: 10),
        adapters: {
          'paid': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('paid')),
          'local': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('local')),
        },
      );

      expect(await router.generateStream('hi').join(), 'local');
    });

    test('with nothing in budget the router throws without a call', () async {
      var calls = 0;
      final tracker = CostTracker();
      addTearDown(tracker.dispose);
      final paid = _config('paid', input: 1, output: 1);
      tracker.recordUsage(config: paid, inputTokens: 3, outputTokens: 0);
      final router = _router(
        providers: [paid],
        tracker: tracker,
        budget: const BudgetPolicy(sessionLimitUsd: 2),
        adapters: {
          'paid': (config, messages) {
            calls++;
            return Stream<AdapterChunk>.value(const AdapterText('paid'));
          },
        },
      );

      await expectLater(
        router.generateStream('hi').join(),
        throwsA(
          isA<BudgetExceededException>()
              .having((error) => error.spentUsd, 'spentUsd', 3)
              .having((error) => error.attempts.single.isSkipped, 'skip', true),
        ),
      );
      expect(calls, 0);
    });

    test('CostTracker breaks spend down by provider and resets', () {
      final tracker = CostTracker();
      addTearDown(tracker.dispose);
      tracker
        ..recordUsage(
          config: _config('a', input: 1, output: 2),
          inputTokens: 1,
          outputTokens: 1,
        )
        ..recordUsage(
          config: _config('a', input: 1, output: 2),
          inputTokens: 2,
          outputTokens: 0,
        )
        ..recordUsage(
          config: _config('b', input: 1, output: 0),
          inputTokens: 4,
          outputTokens: 9,
        );

      expect(tracker.costFor('a'), 5);
      expect(tracker.usageByProvider['b']?.outputTokens, 9);
      expect(tracker.costFor('missing'), 0);
      tracker.reset();
      expect(tracker.usageByProvider, isEmpty);
    });
  });

  group('events', () {
    test('a failover request reports each step with redacted errors', () async {
      final router = _router(
        providers: [_config('alpha'), _config('beta')],
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const RetryableLlmException(
              'HTTP 503: prompt echo',
              statusCode: 503,
              redactedMessage: 'HTTP 503',
            ),
          ),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('ok')),
        },
      );
      final events = <RouterEvent>[];
      router.events.listen(events.add);

      await router.generateStream('hi').drain<void>();
      await _settle();

      expect(events.map((event) => event.runtimeType), <Type>[
        RequestStarted,
        AttemptStarted,
        AttemptFinished,
        AttemptStarted,
        UsageRecorded,
        AttemptFinished,
        RequestFinished,
      ]);
      expect(events.map((event) => event.requestId).toSet(), {1});
      final failed = events.whereType<AttemptFinished>().first.log;
      expect(failed.error, 'HTTP 503');
      expect(router.lastAttemptLogs.first.error, 'HTTP 503: prompt echo');
      expect((events.first as RequestStarted).providerOrder, <String>[
        'alpha/alpha-model',
        'beta/beta-model',
      ]);
      final finished = events.last as RequestFinished;
      expect(finished.outcome, RequestOutcome.succeeded);
      final usage = events.whereType<UsageRecorded>().single;
      expect(usage.estimated, isTrue);
    });

    test(
      'a failed request reports its error type and redacted message',
      () async {
        final router = _router(
          providers: [_config('alpha')],
          adapters: {
            'alpha': (config, messages) => Stream<AdapterChunk>.error(
              const TerminalLlmException(
                'HTTP 400: prompt echo',
                statusCode: 400,
                redactedMessage: 'HTTP 400',
              ),
            ),
          },
        );
        final finished = router.events.only<RequestFinished>().first;

        await expectLater(
          router.generateStream('hi').join(),
          throwsA(isA<TerminalLlmException>()),
        );
        final event = await finished;
        expect(event.outcome, RequestOutcome.failed);
        expect(event.errorType, 'TerminalLlmException');
        expect(event.errorMessage, 'HTTP 400');
      },
    );

    test('redaction can be turned off', () async {
      final router = _router(
        providers: [_config('alpha'), _config('beta')],
        redactEventErrors: false,
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const RetryableLlmException(
              'HTTP 503: detail',
              statusCode: 503,
              redactedMessage: 'HTTP 503',
            ),
          ),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('ok')),
        },
      );
      final finished = router.events.only<AttemptFinished>().first;
      await router.generateStream('hi').drain<void>();
      expect((await finished).log.error, 'HTTP 503: detail');
    });

    test('a retry is announced with its delay', () async {
      var calls = 0;
      final router = _router(
        providers: [_config('alpha')],
        retryPolicy: fastRetry,
        adapters: {
          'alpha': (config, messages) => ++calls == 1
              ? Stream<AdapterChunk>.error(
                  const RetryableLlmException('HTTP 503', statusCode: 503),
                )
              : Stream<AdapterChunk>.value(const AdapterText('ok')),
        },
      );
      final retry = router.events.only<RetryScheduled>().first;
      await router.generateStream('hi').drain<void>();
      final event = await retry;
      expect(event.retry, 1);
      expect(event.delay, const Duration(milliseconds: 1));
    });

    test('the stream closes on dispose', () async {
      final router = RouterLlmProvider(
        providers: [_config('alpha')],
        connectivityChecker: const AssumeOnlineConnectivityChecker(),
      );
      final done = router.events.drain<void>();
      router.dispose();
      await done;
    });
  });

  group('response cache', () {
    test('a repeated request is answered without a provider call', () async {
      var calls = 0;
      final cache = InMemoryResponseCache();
      final router = _router(
        providers: [_config('alpha')],
        responseCache: cache,
        adapters: {
          'alpha': (config, messages) {
            calls++;
            return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
              AdapterText('Hel'),
              AdapterText('lo'),
            ]);
          },
        },
      );

      expect(await router.generateStream('hi').join(), 'Hello');
      expect(await router.generateStream('hi').join(), 'Hello');
      expect(calls, 1);
      final log = router.lastAttemptLogs.single;
      expect(log.fromCache, isTrue);
      expect(log.providerName, 'alpha');

      expect(await router.generateStream('other').join(), 'Hello');
      expect(calls, 2);
      router.settings = const GenerationSettings(temperature: 0.5);
      await router.generateStream('hi').drain<void>();
      expect(calls, 3);
    });

    test('failures and partial replies are not cached', () async {
      var calls = 0;
      final cache = InMemoryResponseCache();
      final router = _router(
        providers: [_config('alpha')],
        responseCache: cache,
        adapters: {
          'alpha': (config, messages) {
            calls++;
            return Stream<AdapterChunk>.error(
              const RetryableLlmException('HTTP 503', statusCode: 503),
            );
          },
        },
      );

      for (var i = 0; i < 2; i++) {
        await expectLater(
          router.generateStream('hi').join(),
          throwsA(isA<AllProvidersFailedException>()),
        );
      }
      expect(calls, 2);
      expect(cache.length, 0);
    });

    test('a throwing cache never fails the request', () async {
      final router = _router(
        providers: [_config('alpha')],
        responseCache: _BrokenCache(),
        adapters: {
          'alpha': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('ok')),
        },
      );
      expect(await router.generateStream('hi').join(), 'ok');
    });

    test('InMemoryResponseCache evicts the least recent and expires', () {
      var now = DateTime(2026);
      final cache = InMemoryResponseCache(
        maxEntries: 2,
        ttl: const Duration(minutes: 1),
        clock: () => now,
      );
      const reply = CachedResponse(text: 't', providerName: 'p', model: 'm');
      cache
        ..write('a', reply)
        ..write('b', reply);
      expect(cache.read('a'), isNotNull);
      cache.write('c', reply);
      expect(cache.read('b'), isNull);
      expect(cache.read('a'), isNotNull);
      now = now.add(const Duration(minutes: 2));
      expect(cache.read('c'), isNull);
    });
  });
}

typedef _Handler =
    Stream<AdapterChunk> Function(
      ProviderConfig config,
      List<ChatTurn> messages,
    );

ProviderConfig _config(String name, {double input = 0, double output = 0}) {
  return ProviderConfig(
    name: name,
    apiKey: 'test-key',
    model: '$name-model',
    pricePerInputToken: input,
    pricePerOutputToken: output,
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

RouterLlmProvider _router({
  required List<ProviderConfig> providers,
  Map<String, _Handler> adapters = const <String, _Handler>{},
  RetryPolicy retryPolicy = RetryPolicy.none,
  CircuitBreakerPolicy? circuitBreaker,
  RoutingStrategy routingStrategy = const PriorityRoutingStrategy(),
  BudgetPolicy? budget,
  ResponseCache? responseCache,
  CostTracker? tracker,
  bool redactEventErrors = true,
}) {
  final client = MockClient((request) async => http.Response('', 200));
  final router = RouterLlmProvider(
    providers: providers,
    costTracker: tracker,
    retryPolicy: retryPolicy,
    circuitBreaker: circuitBreaker,
    routingStrategy: routingStrategy,
    budget: budget,
    responseCache: responseCache,
    redactEventErrors: redactEventErrors,
    customAdapters: <String, BaseLlmAdapter>{
      for (final entry in adapters.entries)
        entry.key: _ScriptedAdapter(client, entry.value),
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
  }) {
    return _handler(config, messages);
  }
}

class _BrokenCache extends ResponseCache {
  @override
  Future<CachedResponse?> read(String key) => Future.error(StateError('read'));

  @override
  void write(String key, CachedResponse response) => throw StateError('write');
}

extension on Stream<RouterEvent> {
  Stream<T> only<T extends RouterEvent>() =>
      where((event) => event is T).cast<T>();
}
