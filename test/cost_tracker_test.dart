import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [CostTracker] accumulation and notifications.
void main() {
  const config = ProviderConfig(
    name: 'openai',
    apiKey: 'sk-test',
    model: 'gpt-4o-mini',
    pricePerInputToken: 0.000001,
    pricePerOutputToken: 0.000002,
  );

  late CostTracker tracker;

  setUp(() => tracker = CostTracker());

  tearDown(() => tracker.dispose());

  test('recordUsage notifies listeners and keeps micro-dollar precision', () {
    final observed = <double>[];
    tracker.totalCostNotifier.addListener(() {
      observed.add(tracker.totalCost);
    });

    tracker.recordUsage(
      config: config,
      inputTokens: 1500000,
      outputTokens: 500000,
    );

    expect(observed, hasLength(1));
    expect(observed.single, closeTo(2.5, 1e-12));
    expect(tracker.totalCost, closeTo(2.5, 1e-12));
    expect(tracker.totalInputTokens, 1500000);
    expect(tracker.totalOutputTokens, 500000);

    tracker.recordUsage(config: config, inputTokens: 1000000, outputTokens: 0);

    expect(observed, hasLength(2));
    expect(tracker.totalCost, closeTo(3.5, 1e-12));
    expect(tracker.totalInputTokens, 2500000);
    expect(tracker.totalOutputTokens, 500000);
  });

  test('recordUsage rejects negative token counts without mutating state', () {
    expect(
      () => tracker.recordUsage(
        config: config,
        inputTokens: -1,
        outputTokens: 0,
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => tracker.recordUsage(
        config: config,
        inputTokens: 0,
        outputTokens: -5,
      ),
      throwsA(isA<AssertionError>()),
    );

    expect(tracker.totalCost, 0);
    expect(tracker.totalInputTokens, 0);
    expect(tracker.totalOutputTokens, 0);
  });

  test('recordCost adds an explicit USD amount', () {
    tracker.recordCost(0.25);
    tracker.recordCost(0.125);

    expect(tracker.totalCost, closeTo(0.375, 1e-12));
    expect(tracker.totalInputTokens, 0);
    expect(tracker.totalOutputTokens, 0);
  });

  test('reset restores cost and token counts to zero', () {
    tracker.recordUsage(
      config: config,
      inputTokens: 1500000,
      outputTokens: 500000,
    );

    tracker.reset();

    expect(tracker.totalCost, 0);
    expect(tracker.totalInputTokens, 0);
    expect(tracker.totalOutputTokens, 0);
  });

  test('a zero-cost update does not notify, but token counters still move', () {
    final observed = <double>[];
    tracker.totalCostNotifier.addListener(() => observed.add(tracker.totalCost));

    const free = ProviderConfig(
      name: 'openai',
      apiKey: 'sk-test',
      model: 'gpt-4o-mini',
      pricePerInputToken: 0,
      pricePerOutputToken: 0,
    );

    tracker.recordUsage(config: free, inputTokens: 40, outputTokens: 10);
    tracker.recordUsage(config: config, inputTokens: 0, outputTokens: 0);
    tracker.recordCost(0);

    expect(observed, isEmpty);
    expect(tracker.totalCost, 0);
    expect(tracker.totalInputTokens, 40);
    expect(tracker.totalOutputTokens, 10);
  });

  test('reset notifies only when the total actually changes', () {
    final observed = <double>[];
    tracker.totalCostNotifier.addListener(() => observed.add(tracker.totalCost));

    tracker.reset();
    expect(observed, isEmpty);

    tracker.recordCost(1.25);
    tracker.reset();
    tracker.reset();

    expect(observed, <double>[1.25, 0]);
    expect(tracker.totalInputTokens, 0);
    expect(tracker.totalOutputTokens, 0);
  });

  test('every listener sees the same spend update', () {
    final first = <double>[];
    final second = <double>[];
    tracker.totalCostNotifier.addListener(() => first.add(tracker.totalCost));
    tracker.totalCostNotifier.addListener(() => second.add(tracker.totalCost));

    tracker.recordCost(0.5);
    tracker.recordUsage(config: config, inputTokens: 1000000, outputTokens: 0);

    expect(first, hasLength(2));
    expect(first.first, 0.5);
    expect(first.last, closeTo(1.5, 1e-12));
    expect(second, first);
  });

  test('recordCost does not change token counters', () {
    tracker.recordUsage(config: config, inputTokens: 4, outputTokens: 2);
    tracker.recordCost(1);

    expect(tracker.totalInputTokens, 4);
    expect(tracker.totalOutputTokens, 2);
    expect(
      tracker.totalCost,
      closeTo(1 + 4 * 0.000001 + 2 * 0.000002, 1e-12),
    );
  });

  test('dispose rejects later reads and writes', () {
    final disposed = CostTracker()..dispose();

    expect(() => disposed.totalCost, throwsFlutterError);
    expect(() => disposed.totalInputTokens, throwsFlutterError);
    expect(() => disposed.totalOutputTokens, throwsFlutterError);
    expect(() => disposed.recordCost(1), throwsFlutterError);
    expect(() => disposed.reset(), throwsFlutterError);
    expect(
      () => disposed.recordUsage(
        config: config,
        inputTokens: 1,
        outputTokens: 1,
      ),
      throwsFlutterError,
    );
  });
}
