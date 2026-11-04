import 'package:flutter/foundation.dart';

import '../models/provider_config.dart';

/// Token counts and estimated USD spend for one provider.
@immutable
class ProviderUsage {
  /// Creates a usage total. Every count must be zero or positive.
  const ProviderUsage({
    this.inputTokens = 0,
    this.cachedInputTokens = 0,
    this.outputTokens = 0,
    this.cost = 0,
  });

  /// Input tokens, including cached ones.
  final int inputTokens;

  /// The part of [inputTokens] read from the provider's prompt cache.
  final int cachedInputTokens;

  /// Output tokens, including thinking tokens.
  final int outputTokens;

  /// Estimated USD spend.
  final double cost;

  ProviderUsage _plus({
    required int inputTokens,
    required int cachedInputTokens,
    required int outputTokens,
    required double cost,
  }) {
    return ProviderUsage(
      inputTokens: this.inputTokens + inputTokens,
      cachedInputTokens: this.cachedInputTokens + cachedInputTokens,
      outputTokens: this.outputTokens + outputTokens,
      cost: this.cost + cost,
    );
  }

  @override
  String toString() {
    return 'ProviderUsage(inputTokens: $inputTokens, '
        'cachedInputTokens: $cachedInputTokens, '
        'outputTokens: $outputTokens, cost: $cost)';
  }
}

/// Running token totals and estimated USD spend for a router.
///
/// [totalCostNotifier] updates whenever [recordUsage] or [recordCost] changes
/// the accumulated spend. [usageByProvider] breaks the totals down by
/// [ProviderConfig.name]. Call [dispose] when the tracker is no longer used.
class CostTracker {
  /// Creates a tracker with zero spend and zero token counts.
  CostTracker();

  final ValueNotifier<double> _totalCostNotifier = ValueNotifier<double>(0);
  final Map<String, ProviderUsage> _usageByProvider = <String, ProviderUsage>{};
  int _totalInputTokens = 0;
  int _totalCachedInputTokens = 0;
  int _totalOutputTokens = 0;

  /// Listenable USD total. Listeners run when the total changes.
  ValueListenable<double> get totalCostNotifier => _totalCostNotifier;

  /// USD accumulated since the last [reset].
  double get totalCost {
    _assertAlive();
    return _totalCostNotifier.value;
  }

  /// Input tokens accumulated since the last [reset], including cached ones.
  int get totalInputTokens {
    _assertAlive();
    return _totalInputTokens;
  }

  /// Cached input tokens accumulated since the last [reset].
  int get totalCachedInputTokens {
    _assertAlive();
    return _totalCachedInputTokens;
  }

  /// Output tokens accumulated since the last [reset].
  int get totalOutputTokens {
    _assertAlive();
    return _totalOutputTokens;
  }

  /// Totals since the last [reset], keyed by [ProviderConfig.name].
  ///
  /// Costs added with [recordCost] alone are not in this breakdown.
  Map<String, ProviderUsage> get usageByProvider {
    _assertAlive();
    return Map<String, ProviderUsage>.unmodifiable(_usageByProvider);
  }

  /// USD spent on the provider named [providerName] since the last [reset].
  double costFor(String providerName) {
    _assertAlive();
    return _usageByProvider[providerName]?.cost ?? 0;
  }

  /// Adds token counts and the USD cost implied by [config].
  ///
  /// Counts must be zero or positive. [cachedInputTokens] is the part of
  /// [inputTokens] read from the prompt cache. The added cost is
  /// [ProviderConfig.calculateCost] for those counts, so per-token
  /// micro-dollar prices accumulate without an extra per-million scale.
  void recordUsage({
    required ProviderConfig config,
    required int inputTokens,
    required int outputTokens,
    int cachedInputTokens = 0,
  }) {
    _assertAlive();
    assert(inputTokens >= 0);
    assert(outputTokens >= 0);
    assert(cachedInputTokens >= 0);
    final cost = config.calculateCost(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedInputTokens: cachedInputTokens,
    );
    _totalInputTokens += inputTokens;
    _totalCachedInputTokens += cachedInputTokens;
    _totalOutputTokens += outputTokens;
    _usageByProvider[config.name] =
        (_usageByProvider[config.name] ?? const ProviderUsage())._plus(
          inputTokens: inputTokens,
          cachedInputTokens: cachedInputTokens,
          outputTokens: outputTokens,
          cost: cost,
        );
    recordCost(cost);
  }

  /// Adds [costInUsd] to the running total and notifies listeners when it
  /// changes.
  void recordCost(double costInUsd) {
    _assertAlive();
    _totalCostNotifier.value = _totalCostNotifier.value + costInUsd;
  }

  /// Clears token counts, the provider breakdown, and estimated spend back
  /// to zero.
  void reset() {
    _assertAlive();
    _totalInputTokens = 0;
    _totalCachedInputTokens = 0;
    _totalOutputTokens = 0;
    _usageByProvider.clear();
    _totalCostNotifier.value = 0;
  }

  /// Releases [totalCostNotifier].
  ///
  /// The tracker must not be used after this call. In debug and profile
  /// builds, later reads and writes throw [FlutterError].
  void dispose() {
    _totalCostNotifier.dispose();
  }

  void _assertAlive() {
    assert(ChangeNotifier.debugAssertNotDisposed(_totalCostNotifier));
  }
}
