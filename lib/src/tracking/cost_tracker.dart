import 'package:flutter/foundation.dart';

import '../models/provider_config.dart';

/// Running token totals and estimated USD spend for a router.
///
/// [totalCostNotifier] updates whenever [recordUsage] or [recordCost] changes
/// the accumulated spend. Call [dispose] when the tracker is no longer used.
class CostTracker {
  final ValueNotifier<double> _totalCostNotifier = ValueNotifier<double>(0);
  int _totalInputTokens = 0;
  int _totalOutputTokens = 0;

  /// Listenable USD total. Listeners run when the total changes.
  ValueListenable<double> get totalCostNotifier => _totalCostNotifier;

  /// USD accumulated since the last [reset].
  double get totalCost {
    _assertAlive();
    return _totalCostNotifier.value;
  }

  /// Input tokens accumulated since the last [reset].
  int get totalInputTokens {
    _assertAlive();
    return _totalInputTokens;
  }

  /// Output tokens accumulated since the last [reset].
  int get totalOutputTokens {
    _assertAlive();
    return _totalOutputTokens;
  }

  /// Adds token counts and the USD cost implied by [config].
  ///
  /// [inputTokens] and [outputTokens] must be zero or positive. The added
  /// cost is [ProviderConfig.calculateCost] for those counts, so per-token
  /// micro-dollar prices accumulate without an extra per-million scale.
  void recordUsage({
    required ProviderConfig config,
    required int inputTokens,
    required int outputTokens,
  }) {
    _assertAlive();
    assert(inputTokens >= 0);
    assert(outputTokens >= 0);
    _totalInputTokens += inputTokens;
    _totalOutputTokens += outputTokens;
    recordCost(
      config.calculateCost(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
      ),
    );
  }

  /// Adds [costInUsd] to the running total and notifies listeners when it
  /// changes.
  void recordCost(double costInUsd) {
    _assertAlive();
    _totalCostNotifier.value = _totalCostNotifier.value + costInUsd;
  }

  /// Clears token counts and estimated spend back to zero.
  void reset() {
    _assertAlive();
    _totalInputTokens = 0;
    _totalOutputTokens = 0;
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
