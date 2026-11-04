import 'dart:math';

import '../models/provider_config.dart';
import 'provider_health.dart';

/// Decides the order in which the router tries providers for one request.
///
/// The router calls [order] once per request and then fails over through
/// the result. Return every provider, or a subset to leave some out. Ties
/// should keep the configured order, so behaviour stays predictable.
abstract class RoutingStrategy {
  /// Const constructor for subclasses.
  const RoutingStrategy();

  /// Returns [providers] in the order to try them.
  ///
  /// [providers] is the router's configured list. [health] is keyed by
  /// [ProviderConfig.id] and holds only providers called before.
  List<ProviderConfig> order(
    List<ProviderConfig> providers,
    Map<String, ProviderHealth> health,
  );
}

/// Tries providers in the configured order. The default.
class PriorityRoutingStrategy extends RoutingStrategy {
  /// Creates the priority strategy.
  const PriorityRoutingStrategy();

  @override
  List<ProviderConfig> order(
    List<ProviderConfig> providers,
    Map<String, ProviderHealth> health,
  ) => providers;
}

/// Tries the cheapest provider first, by the sum of its input and output
/// token prices. Ties keep the configured order.
class CheapestFirstRoutingStrategy extends RoutingStrategy {
  /// Creates the cheapest-first strategy.
  const CheapestFirstRoutingStrategy();

  @override
  List<ProviderConfig> order(
    List<ProviderConfig> providers,
    Map<String, ProviderHealth> health,
  ) {
    return _stableSortBy(
      providers,
      (config) => config.pricePerInputToken + config.pricePerOutputToken,
    );
  }
}

/// Tries the provider with the lowest average time to first token first.
///
/// Providers with no successful attempt yet sort first, so each is measured
/// once. Ties keep the configured order.
class LowestLatencyRoutingStrategy extends RoutingStrategy {
  /// Creates the lowest-latency strategy.
  const LowestLatencyRoutingStrategy();

  @override
  List<ProviderConfig> order(
    List<ProviderConfig> providers,
    Map<String, ProviderHealth> health,
  ) {
    return _stableSortBy(
      providers,
      (config) => health[config.id]?.averageTimeToFirstTokenMs ?? -1,
    );
  }
}

/// Spreads traffic across providers in proportion to [weights].
///
/// Each request draws a provider order at random, weighted without
/// replacement, so the remaining providers still back up the first.
/// [weights] is keyed by [ProviderConfig.name] or [ProviderConfig.id], with
/// the id taking precedence. A provider without a weight gets
/// [defaultWeight]. A weight of zero puts the provider last.
class WeightedRoutingStrategy extends RoutingStrategy {
  /// Creates a weighted strategy. Weights must be zero or positive.
  ///
  /// [random] makes the draw reproducible in tests.
  WeightedRoutingStrategy(
    this.weights, {
    this.defaultWeight = 1,
    Random? random,
  }) : assert(weights.values.every((weight) => weight >= 0)),
       assert(defaultWeight >= 0),
       _random = random ?? Random();

  /// Relative share of traffic per provider.
  final Map<String, double> weights;

  /// Weight of a provider missing from [weights].
  final double defaultWeight;

  final Random _random;

  @override
  List<ProviderConfig> order(
    List<ProviderConfig> providers,
    Map<String, ProviderHealth> health,
  ) {
    final remaining = <ProviderConfig>[...providers];
    final ordered = <ProviderConfig>[];
    while (remaining.isNotEmpty) {
      final weightsLeft = <double>[for (final c in remaining) _weightOf(c)];
      final total = weightsLeft.fold<double>(0, (sum, weight) => sum + weight);
      if (total <= 0) {
        ordered.addAll(remaining);
        break;
      }
      var pick = _random.nextDouble() * total;
      var index = 0;
      while (index < remaining.length - 1 && pick >= weightsLeft[index]) {
        pick -= weightsLeft[index];
        index++;
      }
      ordered.add(remaining.removeAt(index));
    }
    return ordered;
  }

  double _weightOf(ProviderConfig config) =>
      weights[config.id] ?? weights[config.name] ?? defaultWeight;
}

List<ProviderConfig> _stableSortBy(
  List<ProviderConfig> providers,
  double Function(ProviderConfig config) key,
) {
  final indexed = <(int, ProviderConfig)>[
    for (var i = 0; i < providers.length; i++) (i, providers[i]),
  ];
  indexed.sort((a, b) {
    final byKey = key(a.$2).compareTo(key(b.$2));
    return byKey != 0 ? byKey : a.$1.compareTo(b.$1);
  });
  return <ProviderConfig>[for (final entry in indexed) entry.$2];
}
