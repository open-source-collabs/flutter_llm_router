@Tags(<String>['chaos'])
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A seeded chaos run that measures how often a request still succeeds when
/// providers fail, and checks that no failure escapes classification.
///
/// Each simulated provider fails [_failureRate] of its calls, picking a
/// failure class uniformly from [_Failure]. The numbers in
/// `doc/11-reliability-benchmark.md` come from this test:
///
/// ```sh
/// flutter test test/chaos --reporter expanded
/// ```
void main() {
  const requests = 2000;
  final scenarios = <_Scenario>[
    const _Scenario('1 provider', providers: 1),
    const _Scenario('3 providers, failover', providers: 3),
    const _Scenario(
      '3 providers, failover + 1 retry',
      providers: 3,
      retryPolicy: RetryPolicy(
        maxRetries: 1,
        initialDelay: Duration.zero,
        maxDelay: Duration.zero,
        jitter: 0,
      ),
    ),
  ];

  test('success rate by setup, with every failure classified', () async {
    final rows = <String>[];
    final results = <String, _Result>{};
    for (final scenario in scenarios) {
      final result = await _run(scenario, requests: requests, seed: 42);
      results[scenario.name] = result;
      rows.add(
        '| ${scenario.name} | ${_pct(result.succeeded, requests)} '
        '| ${_pct(result.partial, requests)} '
        '| ${_pct(result.failed, requests)} '
        '| ${result.unclassified} | ${result.hung} |',
      );
    }

    // Printed so the table can be copied into the docs.
    // ignore: avoid_print
    print(
      [
        '',
        'Chaos run: $requests requests per setup, each provider failing '
            '${(_failureRate * 100).round()}% of calls, seed 42.',
        '',
        '| Setup | Succeeded | Failed after partial text | Failed | '
            'Unclassified errors | Hung |',
        '|---|---|---|---|---|---|',
        ...rows,
        '',
      ].join('\n'),
    );

    for (final result in results.values) {
      expect(result.unclassified, 0, reason: 'an error escaped the router');
      expect(result.hung, 0, reason: 'a request never finished');
    }
    final single = results['1 provider']!.succeeded;
    final chain = results['3 providers, failover']!.succeeded;
    final retried = results['3 providers, failover + 1 retry']!.succeeded;
    expect(chain, greaterThan(single));
    expect(retried, greaterThanOrEqualTo(chain));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

const double _failureRate = 0.2;

/// How a simulated provider call fails.
enum _Failure {
  rateLimited,
  serverError,
  badKey,
  timeout,
  connectionDrop,
  inBandError,
  emptyReply,
  dropAfterText,
}

class _Scenario {
  const _Scenario(
    this.name, {
    required this.providers,
    this.retryPolicy = RetryPolicy.none,
  });

  final String name;
  final int providers;
  final RetryPolicy retryPolicy;
}

class _Result {
  int succeeded = 0;
  int partial = 0;
  int failed = 0;
  int unclassified = 0;
  int hung = 0;
}

Future<_Result> _run(
  _Scenario scenario, {
  required int requests,
  required int seed,
}) async {
  final random = Random(seed);
  final client = MockClient((request) async => http.Response('', 200));
  final names = <String>[for (var i = 0; i < scenario.providers; i++) 'p$i'];
  final router = RouterLlmProvider(
    providers: <ProviderConfig>[
      for (final name in names)
        ProviderConfig(
          name: name,
          apiKey: 'k',
          model: '$name-model',
          pricePerInputToken: 0,
          pricePerOutputToken: 0,
        ),
    ],
    retryPolicy: scenario.retryPolicy,
    connectivityChecker: const AssumeOnlineConnectivityChecker(),
    customAdapters: <String, BaseLlmAdapter>{
      for (final name in names) name: _ChaosAdapter(client, random),
    },
  );
  final result = _Result();
  try {
    for (var i = 0; i < requests; i++) {
      final text = StringBuffer();
      try {
        await router
            .generateStream('ping')
            .forEach(text.write)
            .timeout(const Duration(seconds: 2));
        result.succeeded++;
      } on TimeoutException {
        result.hung++;
      } on LlmRouterException {
        if (text.isNotEmpty) {
          result.partial++;
        } else {
          result.failed++;
        }
      } on Object {
        result.unclassified++;
      }
    }
  } finally {
    router.dispose();
    client.close();
  }
  return result;
}

class _ChaosAdapter extends BaseLlmAdapter {
  _ChaosAdapter(http.Client client, this._random) : super(client: client);

  final Random _random;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    if (_random.nextDouble() >= _failureRate) {
      return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
        AdapterText('po'),
        AdapterText('ng'),
        AdapterFinish(FinishReason.stop),
      ]);
    }
    final failure = _Failure.values[_random.nextInt(_Failure.values.length)];
    return switch (failure) {
      _Failure.rateLimited => Stream<AdapterChunk>.error(
        const RetryableLlmException('HTTP 429', statusCode: 429),
      ),
      _Failure.serverError => Stream<AdapterChunk>.error(
        const RetryableLlmException('HTTP 503', statusCode: 503),
      ),
      _Failure.badKey => Stream<AdapterChunk>.error(
        const ProviderUnavailableLlmException('HTTP 401', statusCode: 401),
      ),
      _Failure.timeout => Stream<AdapterChunk>.error(
        RetryableLlmException(
          'Timed out',
          cause: TimeoutException('simulated'),
        ),
      ),
      _Failure.connectionDrop => Stream<AdapterChunk>.error(
        RetryableLlmException(
          'Connection failed',
          cause: http.ClientException('simulated'),
        ),
      ),
      _Failure.inBandError => Stream<AdapterChunk>.error(
        const RetryableLlmException('Provider reported an error mid-stream'),
      ),
      _Failure.emptyReply => const Stream<AdapterChunk>.empty(),
      _Failure.dropAfterText => _dropAfterText(),
    };
  }

  Stream<AdapterChunk> _dropAfterText() async* {
    yield const AdapterText('po');
    throw RetryableLlmException(
      'Connection dropped while reading SSE',
      cause: http.ClientException('simulated'),
    );
  }
}

String _pct(int count, int total) =>
    '${(count * 100 / total).toStringAsFixed(1)}%';
