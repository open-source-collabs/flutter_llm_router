import 'package:flutter/foundation.dart';

import '../models/provider_config.dart';

/// State of one provider's circuit breaker.
enum CircuitState {
  /// Requests flow normally.
  closed,

  /// Too many consecutive failures. The router skips this provider until
  /// the cooldown ends.
  open,

  /// The cooldown ended. One trial request may run; its result closes or
  /// reopens the circuit.
  halfOpen,
}

/// When the router stops calling a failing provider, and for how long.
///
/// After [failureThreshold] consecutive failed requests the circuit opens
/// and the router skips the provider, logging why, for [cooldown]. Then one
/// trial request runs: success closes the circuit, failure opens it again.
/// If every provider's circuit is open, the router tries them anyway rather
/// than failing without a call.
///
/// A failure counts once per request, after any retries. Terminal failures,
/// cancellations, and connection failures on a confirmed-offline device do
/// not count.
class CircuitBreakerPolicy {
  /// Creates a policy. [failureThreshold] must be at least 1.
  const CircuitBreakerPolicy({
    this.failureThreshold = 3,
    this.cooldown = const Duration(seconds: 30),
  }) : assert(failureThreshold >= 1);

  /// Consecutive failures that open the circuit.
  final int failureThreshold;

  /// How long an open circuit skips the provider.
  final Duration cooldown;
}

/// A snapshot of one provider's health, keyed by [ProviderConfig.id].
@immutable
class ProviderHealth {
  /// Creates a health snapshot.
  const ProviderHealth({
    required this.providerId,
    this.state = CircuitState.closed,
    this.consecutiveFailures = 0,
    this.openUntil,
    this.successes = 0,
    this.failures = 0,
    this.averageTimeToFirstTokenMs,
  });

  /// [ProviderConfig.id] of the provider.
  final String providerId;

  /// Current circuit breaker state. Always [CircuitState.closed] without a
  /// [CircuitBreakerPolicy].
  final CircuitState state;

  /// Failed requests since the last success.
  final int consecutiveFailures;

  /// When an open circuit allows a trial request. Null unless [state] is
  /// [CircuitState.open].
  final DateTime? openUntil;

  /// Successful attempts since the router was created.
  final int successes;

  /// Failed attempts, including retries, since the router was created.
  final int failures;

  /// Exponentially weighted average time to first token, in milliseconds,
  /// over successful attempts. Null until one succeeds.
  final double? averageTimeToFirstTokenMs;

  ProviderHealth _copyWith({
    CircuitState? state,
    int? consecutiveFailures,
    DateTime? openUntil,
    bool clearOpenUntil = false,
    int? successes,
    int? failures,
    double? averageTimeToFirstTokenMs,
  }) {
    return ProviderHealth(
      providerId: providerId,
      state: state ?? this.state,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      openUntil: clearOpenUntil ? null : openUntil ?? this.openUntil,
      successes: successes ?? this.successes,
      failures: failures ?? this.failures,
      averageTimeToFirstTokenMs:
          averageTimeToFirstTokenMs ?? this.averageTimeToFirstTokenMs,
    );
  }

  @override
  String toString() {
    return 'ProviderHealth($providerId, state: ${state.name}, '
        'consecutiveFailures: $consecutiveFailures, openUntil: $openUntil, '
        'successes: $successes, failures: $failures, '
        'averageTimeToFirstTokenMs: $averageTimeToFirstTokenMs)';
  }
}

/// Tracks [ProviderHealth] for a router. Not exported.
class ProviderHealthRegistry {
  /// Creates a registry. [policy] null disables the circuit breaker.
  ProviderHealthRegistry({required this.policy, required this.onStateChange});

  /// Circuit breaker settings, or null for none.
  final CircuitBreakerPolicy? policy;

  /// Called when a circuit changes state.
  final void Function(String providerId, CircuitState from, CircuitState to)
  onStateChange;

  final ValueNotifier<Map<String, ProviderHealth>> _health =
      ValueNotifier<Map<String, ProviderHealth>>(
        const <String, ProviderHealth>{},
      );
  final Set<String> _trialsInFlight = <String>{};

  static const double _latencyWeight = 0.3;

  /// Listenable snapshot of every provider seen so far.
  ValueListenable<Map<String, ProviderHealth>> get listenable => _health;

  /// Current snapshot.
  Map<String, ProviderHealth> get snapshot => _health.value;

  ProviderHealth _get(String id) =>
      _health.value[id] ?? ProviderHealth(providerId: id);

  void _put(ProviderHealth health) {
    final previous = _get(health.providerId).state;
    _health.value = Map<String, ProviderHealth>.unmodifiable(
      <String, ProviderHealth>{..._health.value, health.providerId: health},
    );
    if (previous != health.state) {
      onStateChange(health.providerId, previous, health.state);
    }
  }

  /// Whether [config] would be skipped now, without changing any state.
  bool isBlocked(ProviderConfig config, DateTime now) {
    if (policy == null) return false;
    final health = _get(config.id);
    return switch (health.state) {
      CircuitState.closed => false,
      CircuitState.open => now.isBefore(health.openUntil!),
      CircuitState.halfOpen => _trialsInFlight.contains(config.id),
    };
  }

  /// Claims permission to call [config], moving an expired open circuit to
  /// half-open and reserving its single trial. Returns false to skip.
  bool tryAcquire(ProviderConfig config, DateTime now) {
    if (policy == null) return true;
    if (isBlocked(config, now)) return false;
    final health = _get(config.id);
    if (health.state == CircuitState.closed) return true;
    _trialsInFlight.add(config.id);
    if (health.state == CircuitState.open) {
      _put(
        health._copyWith(state: CircuitState.halfOpen, clearOpenUntil: true),
      );
    }
    return true;
  }

  /// Releases a trial without a verdict, for example when cancelled.
  void release(ProviderConfig config) => _trialsInFlight.remove(config.id);

  /// Records a successful attempt and closes the circuit.
  void recordSuccess(ProviderConfig config, {int? timeToFirstTokenMs}) {
    _trialsInFlight.remove(config.id);
    final health = _get(config.id);
    final previous = health.averageTimeToFirstTokenMs;
    final sample = timeToFirstTokenMs?.toDouble();
    _put(
      health._copyWith(
        state: CircuitState.closed,
        consecutiveFailures: 0,
        clearOpenUntil: true,
        successes: health.successes + 1,
        averageTimeToFirstTokenMs: sample == null
            ? previous
            : previous == null
            ? sample
            : previous + _latencyWeight * (sample - previous),
      ),
    );
  }

  /// Counts one failed attempt, including a retry, without touching the
  /// circuit.
  void recordAttemptFailure(ProviderConfig config) {
    final health = _get(config.id);
    _put(health._copyWith(failures: health.failures + 1));
  }

  /// Counts a failed request against the circuit, which may open it.
  void recordRequestFailure(ProviderConfig config, DateTime now) {
    _trialsInFlight.remove(config.id);
    final policy = this.policy;
    final health = _get(config.id);
    final failures = health.consecutiveFailures + 1;
    final opens =
        policy != null &&
        (health.state == CircuitState.halfOpen ||
            failures >= policy.failureThreshold);
    _put(
      health._copyWith(
        consecutiveFailures: failures,
        state: opens ? CircuitState.open : health.state,
        openUntil: opens ? now.add(policy.cooldown) : null,
      ),
    );
  }

  /// Closes every circuit and clears failure streaks. Counters and latency
  /// averages are kept.
  void resetCircuits() {
    _trialsInFlight.clear();
    for (final health in _health.value.values.toList()) {
      _put(
        health._copyWith(
          state: CircuitState.closed,
          consecutiveFailures: 0,
          clearOpenUntil: true,
        ),
      );
    }
  }

  /// Releases the listenable.
  void dispose() => _health.dispose();
}
