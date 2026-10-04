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

The router calls `recordUsage` only after a provider stream finishes without error. Failover attempts that threw before the first token are logged and are not billed. A retryable error after text has already been yielded is not billed either. The partial text was already shown.

```dart
costTracker.recordUsage(
  config: winningProvider,
  inputTokens: inputTokens,
  outputTokens: outputTokens,
);
```

`recordUsage` adds the token counts, then adds `config.calculateCost(...)` to the running total.

`recordCost` adds a raw USD amount and does not change the token counters. `reset` sets cost and both counters back to zero and notifies listeners when the cost actually changes.

## Token accounting

The router uses a count when the winning provider reports it:

| Provider | Input field | Output field |
| --- | --- | --- |
| OpenAI and OpenRouter | `usage.prompt_tokens` | `usage.completion_tokens` |
| Anthropic | `message_start.message.usage.input_tokens` | `message_delta.usage.output_tokens` |
| Gemini | `usageMetadata.promptTokenCount` | `usageMetadata.candidatesTokenCount` |

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
