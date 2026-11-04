import '../exceptions/router_exceptions.dart';
import '../models/provider_config.dart';

/// How a provider with several API keys picks the next one.
enum KeyRotation {
  /// Each request starts on the next key, spreading load evenly.
  roundRobin,

  /// Every request starts on the first key and moves on only when a key is
  /// cooling down.
  priority,
}

/// How the router rotates [ProviderConfig.apiKeys] and benches bad keys.
///
/// A key is benched when a call with it fails with HTTP 429 (rate limit) or
/// 401, 402, or 403 (bad key, no credit, no access). The router then retries
/// the same provider with the next key, so one exhausted key does not cost
/// the provider, which matters when no other provider can do the job.
/// A provider with a single key is unaffected.
class KeyPoolPolicy {
  /// Creates a policy.
  const KeyPoolPolicy({
    this.rotation = KeyRotation.roundRobin,
    this.rateLimitCooldown = const Duration(seconds: 60),
    this.invalidKeyCooldown = const Duration(minutes: 10),
  });

  /// Which key a request starts on. Defaults to [KeyRotation.roundRobin].
  final KeyRotation rotation;

  /// How long a rate-limited key rests when the response carried no
  /// `Retry-After`. Defaults to 60 seconds.
  final Duration rateLimitCooldown;

  /// How long a key rests after a 401, 402, or 403. Defaults to 10 minutes,
  /// so a topped-up balance is noticed without restarting the app.
  final Duration invalidKeyCooldown;
}

/// Tracks which keys of each provider are resting. Not exported.
class KeyPoolRegistry {
  /// Creates a registry that applies [policy].
  KeyPoolRegistry(this.policy);

  /// Rotation and cooldown settings.
  final KeyPoolPolicy policy;

  final Map<String, Map<int, DateTime>> _restingUntil =
      <String, Map<int, DateTime>>{};
  final Map<String, int> _cursor = <String, int>{};

  /// Indexes into [ProviderConfig.allKeys] to try, in order, skipping keys
  /// that are resting at [now]. Empty when every key is resting.
  List<int> order(ProviderConfig config, DateTime now) {
    final count = config.allKeys.length;
    if (count <= 1) return const <int>[0];
    final start = switch (policy.rotation) {
      KeyRotation.priority => 0,
      KeyRotation.roundRobin => (_cursor[config.id] ?? 0) % count,
    };
    _cursor[config.id] = start + 1;
    final resting = _restingUntil[config.id];
    return <int>[
      for (var i = 0; i < count; i++)
        if ((start + i) % count case final index
            when resting?[index] == null || !now.isBefore(resting![index]!))
          index,
    ];
  }

  /// Earliest time a resting key of [config] is usable again, or null.
  DateTime? nextAvailable(ProviderConfig config) {
    final resting = _restingUntil[config.id];
    if (resting == null || resting.isEmpty) return null;
    return resting.values.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  /// Benches key [index] of [config] if [failure] is the key's fault.
  /// Returns whether the key was benched.
  bool recordFailure(
    ProviderConfig config,
    int index,
    LlmRouterException failure,
    DateTime now,
  ) {
    if (config.allKeys.length <= 1) return false;
    final Duration cooldown;
    if (failure.statusCode == 429) {
      final retryAfter = failure is RetryableLlmException
          ? failure.retryAfter
          : null;
      cooldown = retryAfter ?? policy.rateLimitCooldown;
    } else if (failure is ProviderUnavailableLlmException &&
        (failure.statusCode == 401 ||
            failure.statusCode == 402 ||
            failure.statusCode == 403)) {
      cooldown = policy.invalidKeyCooldown;
    } else {
      return false;
    }
    (_restingUntil[config.id] ??= <int, DateTime>{})[index] = now.add(cooldown);
    return true;
  }
}
