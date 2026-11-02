import '../models/provider_config.dart';
import '../tracking/cost_tracker.dart';

/// Spending limits checked before each provider is called.
///
/// Limits compare against the router's [CostTracker] since its last
/// `reset`, so a "session" is whatever span the app resets the tracker on.
///
/// - A provider whose spend reached its entry in [providerLimitsUsd] is
///   skipped, and the router fails over to the next one. Order a cheaper
///   model after an expensive one to fall back to it when the expensive
///   one's budget runs out.
/// - Once total spend reaches [sessionLimitUsd], only free providers
///   ([ProviderConfig.isFree], such as a local model) are called.
///
/// When no provider within budget remains, the router throws
/// `BudgetExceededException` without calling anything. A request that
/// starts under a limit may finish over it, because the cost of a reply is
/// known only afterwards.
class BudgetPolicy {
  /// Creates a policy. Limits must be zero or positive.
  const BudgetPolicy({
    this.sessionLimitUsd,
    this.providerLimitsUsd = const <String, double>{},
  }) : assert(sessionLimitUsd == null || sessionLimitUsd >= 0);

  /// Total USD after which only free providers are called. Null for none.
  final double? sessionLimitUsd;

  /// USD per provider, keyed by [ProviderConfig.name], after which that
  /// provider is skipped.
  final Map<String, double> providerLimitsUsd;

  /// Why [config] cannot be called under [tracker]'s totals, or null when it
  /// can.
  String? blockReason(ProviderConfig config, CostTracker tracker) {
    final session = sessionLimitUsd;
    if (session != null && !config.isFree && tracker.totalCost >= session) {
      return 'Session budget of \$$session reached';
    }
    final limit = providerLimitsUsd[config.name];
    if (limit != null && tracker.costFor(config.name) >= limit) {
      return 'Budget of \$$limit for ${config.name} reached';
    }
    return null;
  }
}
