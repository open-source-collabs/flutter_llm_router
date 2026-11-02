# Reliability policies

Plain failover needs no configuration. These policies tune it. Each one is off by default, and the defaults behave exactly like plain failover.

For each request the router:

1. Asks `responseCache`, when set, for a stored reply.
2. Orders `providers` with `routingStrategy`.
3. For each provider, skips it if it can't take the attachments, if `budget` blocks it, or if its circuit is open. Each skip is logged with a `skipReason`.
4. Calls the provider, retrying transient failures under `retryPolicy`, then fails over.

## Retry

```dart
RouterLlmProvider(
  providers: providers,
  retryPolicy: const RetryPolicy(
    maxRetries: 2,
    initialDelay: Duration(milliseconds: 500),
    maxDelay: Duration(seconds: 8),
    multiplier: 2,
    jitter: 0.2,
  ),
);
```

`RetryPolicy` retries the same provider before failing over. The default `retryPolicy` is `RetryPolicy.none`, which doesn't retry. `const RetryPolicy()` retries twice.

What is retried:

- HTTP 408, 429, and 500–599, including Anthropic's in-stream `overloaded_error` (reported as 529).
- Timeouts, stalled streams, dropped connections, and TLS failures.

What is not retried: `ProviderUnavailableLlmException` (bad key, no credit, unknown model), `TerminalLlmException`, empty replies, malformed stream data, and any failure after text was shown.

The wait before retry `n` (from zero) is `initialDelay * multiplier^n`, capped at `maxDelay`, then varied by up to `jitter` in either direction. When the provider sent `Retry-After` (in seconds) or `retry-after-ms`, that value replaces the wait while `respectRetryAfter` is true. If it is longer than `maxDelay`, the router fails over at once instead of making the user wait.

Each retry appears in `lastAttemptLogs` with `retry` set to 1, 2, and so on. Cancelling the stream during a wait stops the request. On a connection failure, the offline check runs before any retry, so an offline device stops at once.

Retries multiply the worst-case wait. With three providers, two retries each, and a 30-second `timeout`, a request can take minutes. Use `ProviderConfig.deadline` and a small `maxRetries` for interactive chat.

## Circuit breaker

```dart
RouterLlmProvider(
  providers: providers,
  circuitBreaker: const CircuitBreakerPolicy(
    failureThreshold: 3,
    cooldown: Duration(seconds: 30),
  ),
);
```

Without a breaker, a dead provider costs every request its full timeout. With one:

- After `failureThreshold` consecutive failed requests, the circuit opens and the provider is skipped for `cooldown`.
- After the cooldown, the circuit is half-open. One trial request is allowed. Success closes the circuit, and failure opens it again for another cooldown.
- If every provider's circuit is open, the router calls them anyway, rather than failing without trying.

A failure counts once per request, after retries. Terminal failures, cancellations, content-filtered replies, and connection failures on a device confirmed offline don't count. A success resets the streak.

Circuits are tracked per `ProviderConfig.id` (`name/model`), so two OpenRouter models sharing a key have separate circuits.

```dart
ValueListenableBuilder<Map<String, ProviderHealth>>(
  valueListenable: router.providerHealth,
  builder: (context, health, _) => Column(
    children: [
      for (final h in health.values)
        Text('${h.providerId}: ${h.state.name}, '
            '${h.successes} ok, ${h.failures} failed'),
    ],
  ),
)
```

`router.resetCircuits()` closes every circuit, for example after the user fixes an API key. Circuit changes are also reported as `CircuitStateChanged` events.

## Routing strategies

`routingStrategy` orders the providers for each request. The router then fails over through that order.

| Strategy | Order |
| --- | --- |
| `PriorityRoutingStrategy` (default) | The configured list order |
| `CheapestFirstRoutingStrategy` | By `pricePerInputToken + pricePerOutputToken`, cheapest first |
| `LowestLatencyRoutingStrategy` | By average time to first token. Providers not yet measured go first, so each is measured once |
| `WeightedRoutingStrategy(weights)` | A random order weighted by share of traffic |

Ties keep the configured order.

```dart
// About 80% of first attempts go to Gemini, 20% to OpenAI. The other
// provider is still the fallback.
routingStrategy: WeightedRoutingStrategy({'gemini': 4, 'openai': 1}),
```

Weights are keyed by `ProviderConfig.id` or `ProviderConfig.name`, with the id winning. A missing provider gets `defaultWeight` (1). A weight of zero puts the provider last.

Latency comes from `ProviderHealth.averageTimeToFirstTokenMs`, an exponentially weighted average over successful attempts.

Write your own by extending `RoutingStrategy` and returning the providers in the order to try. Returning a subset leaves the rest out of that request.

## Budgets

```dart
RouterLlmProvider(
  providers: [
    ProviderConfig(name: 'premium', /* ... */),
    ProviderConfig(name: 'budget', /* ... */),
    ProviderConfig.ollama(model: 'llama3.2'),
  ],
  budget: const BudgetPolicy(
    sessionLimitUsd: 2.00,
    providerLimitsUsd: {'premium': 0.50},
  ),
);
```

`BudgetPolicy` is checked before each provider call, against `costTracker` totals since its last `reset`:

- A provider whose spend reached its entry in `providerLimitsUsd` (keyed by `ProviderConfig.name`) is skipped. Order a cheaper model after an expensive one to fall back to it.
- Once total spend reaches `sessionLimitUsd`, only free providers (`ProviderConfig.isFree`, all prices zero) are called.
- If no provider within budget remains, the router throws `BudgetExceededException` without calling anything. `spentUsd` holds the total, and `attempts` lists the skipped providers.

A request that starts under a limit may finish over it, because a reply's cost is known only afterwards. Define the session by calling `costTracker.reset()` when you want the limits to start over, for example daily or per signed-in user.

## Response cache

```dart
final cache = InMemoryResponseCache(
  maxEntries: 100,
  ttl: const Duration(minutes: 10),
);
RouterLlmProvider(providers: providers, responseCache: cache);
```

Before routing, the router looks up a key built from the conversation turns, their attachments, and `router.settings`. A hit is shown as one chunk, costs nothing, and is logged with `fromCache: true` and the original `providerName`. After a complete, successful reply, the router stores it. Failures and partial replies are never stored.

The key doesn't include the provider, so a reply from any provider can answer. It also doesn't include `ProviderConfig.settings`. Don't use the cache when per-provider settings must change the answer.

`InMemoryResponseCache` evicts the least recently used entry beyond `maxEntries`. For storage across launches, implement `ResponseCache`'s `read` and `write`. Keys can be long, so a persistent cache may hash them. Errors thrown by a cache are ignored.

Caching suits repeated prompts such as suggested questions and `generateStream` calls. Free-form chat rarely repeats a whole conversation.
