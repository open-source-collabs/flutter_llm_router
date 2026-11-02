# Cost tracking

`CostTracker` keeps the USD estimate and the token counts for one router. The chat UI listens to `totalCostNotifier` instead of polling.

## Create and own the tracker

Pass a tracker when the widget should read it. You then dispose both objects.

```dart
final costTracker = CostTracker();
final router = RouterLlmProvider(
  providers: providers,
  costTracker: costTracker,
);

@override
void dispose() {
  router.dispose();
  costTracker.dispose();
  super.dispose();
}
```

If you omit `costTracker`, the router creates one and disposes it in `router.dispose()`. Read it from `router.costTracker` before that call.

## Bind the spend label

`totalCostNotifier` is a `ValueListenable<double>`. Listeners run when the total changes.

```dart
ValueListenableBuilder<double>(
  valueListenable: router.costTracker.totalCostNotifier,
  builder: (context, totalCost, _) {
    return Text('\$${totalCost.toStringAsFixed(8)}');
  },
)
```

Eight fraction digits keep per-token prices such as `0.00000015` visible. `totalCost` is the same number as `totalCostNotifier.value`.

A zero-cost update does not notify, because `ValueNotifier` skips an unchanged value. Token counters still move.

## When usage is recorded

The router calls `recordUsage` for every attempt that a provider is likely to charge for:

- a stream that finishes with text,
- a stream that fails or is cancelled after text was yielded, priced on the partial text,
- any attempt where the provider reported token counts, even if it then failed.

A failed attempt with no text and no reported usage is logged and not billed. Gemini thinking tokens count as output tokens.

```dart
costTracker.recordUsage(
  config: winningProvider,
  inputTokens: inputTokens,
  outputTokens: outputTokens,
);
```

`recordUsage` adds the token counts, then adds `config.calculateCost(...)` to the running total. Its optional `cachedInputTokens` argument is the part of `inputTokens` read from the prompt cache.

`recordCost` adds a raw USD amount and does not change the token counters or the provider breakdown. `reset` sets cost, every counter, and the breakdown back to zero and notifies listeners when the cost actually changes.

Each recorded attempt is also reported as a `UsageRecorded` event on `router.events`. See [Observability](06-observability.md).

## Per-provider breakdown

`usageByProvider` maps each `ProviderConfig.name` to a `ProviderUsage` with `inputTokens`, `cachedInputTokens`, `outputTokens`, and `cost`. `costFor(name)` returns one provider's spend.

```dart
for (final entry in router.costTracker.usageByProvider.entries) {
  print('${entry.key}: \$${entry.value.cost.toStringAsFixed(6)}');
}
```

`BudgetPolicy` uses these totals for its per-provider and session limits. See [Budgets](05-reliability-policies.md#budgets).

## Cached tokens

Vendors charge less for prompt tokens served from their cache. Set `pricePerCachedInputToken` to that rate:

```dart
ProviderConfig(
  name: 'openai',
  apiKey: key,
  model: 'gpt-4o-mini',
  pricePerInputToken: 0.00000015,
  pricePerCachedInputToken: 0.000000075,
  pricePerOutputToken: 0.0000006,
)
```

Cost is then `(inputTokens - cachedInputTokens) * pricePerInputToken + cachedInputTokens * pricePerCachedInputToken + outputTokens * pricePerOutputToken`. Without it, cached tokens cost the normal input price. `totalCachedInputTokens` holds the running count.

## Token accounting

The router uses a count when the winning provider reports it:

| Provider | Input field | Output field | Cached input field |
| --- | --- | --- | --- |
| OpenAI, OpenRouter, Azure, and compatible hosts | `usage.prompt_tokens` | `usage.completion_tokens` | `usage.prompt_tokens_details.cached_tokens`, or DeepSeek's `prompt_cache_hit_tokens` |
| Groq | `x_groq.usage.prompt_tokens` when `usage` is absent | `x_groq.usage.completion_tokens` | None |
| Anthropic | `input_tokens` + `cache_read_input_tokens` + `cache_creation_input_tokens` from `message_start` | `message_delta.usage.output_tokens` | `cache_read_input_tokens` |
| Gemini | `usageMetadata.promptTokenCount` | `candidatesTokenCount` + `thoughtsTokenCount` | `cachedContentTokenCount` |

Anthropic cache writes are counted as ordinary input tokens. Anthropic charges a premium for them, so the estimate is slightly low when you write to its cache.

OpenAI-compatible requests set `stream_options.include_usage` so the final SSE event can carry `usage`. A side that never arrives falls back to:

```text
tokens = (text.length + 3) ~/ 4
```

- Input text is the joined chat turns sent to the winning adapter.
- Output text is the concatenation of text chunks from the winning stream.
- An empty string is 0 tokens.
- A 4-character string is 1 token. A 5-character string is 2 tokens.

`pricePerInputToken` and `pricePerOutputToken` are USD per one of those estimated tokens. A price stored per million tokens must be divided by 1,000,000 before it goes on `ProviderConfig`. Example: `$0.15 / 1,000,000 = 0.00000015`.

`calculateCost` multiplies those unit prices by the counts. It does not divide by one million again.

The label is an estimate for the session. Compare it with the provider dashboard before you treat it as the invoice.
