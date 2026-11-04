> **DRAFT** for the maintainer to edit before publishing. Check the code samples against the released version, and add links and a byline.

# Failing over a streaming LLM response

Calling one LLM API is easy. Keeping a chat working when that API has a bad minute is not. Rate limits, overloaded models, revoked keys, retired model names, and dropped connections all happen in production. The usual fix is failover: if one provider fails, ask the next.

For a request that returns one JSON body, failover is a loop with a `try`. Streaming changes that. The user is watching tokens arrive. A failure halfway through isn't just a failed request; it's a reply that is already half on screen.

This article covers how `flutter_llm_router` handles that, and why its rules are what they are.

## The rule: fail over only before anything is shown

A streamed reply has a point of no return: the first token the user sees.

Before that point, a failure is invisible. The router can drop the attempt, log it, and ask the next provider. The user sees a slightly slower first token.

After that point, there is no clean way to switch. A second provider would start its own answer from scratch. You'd get two half-answers glued together, or you'd have to delete text the user already read. So the router rethrows the error and lets the UI show it.

```dart
final router = RouterLlmProvider(
  providers: const [
    ProviderConfig(
      name: 'openai',
      apiKey: openAiKey,
      model: 'gpt-4o-mini',
      pricePerInputToken: 0.00000015,
      pricePerOutputToken: 0.0000006,
    ),
    ProviderConfig(
      name: 'anthropic',
      apiKey: anthropicKey,
      model: 'claude-haiku-4-5',
      pricePerInputToken: 0.000001,
      pricePerOutputToken: 0.000005,
    ),
  ],
);
```

If OpenAI returns HTTP 429, the user never knows. If OpenAI drops the connection after "The capital of", the user sees an error, because hiding it would mean inventing the rest of the sentence.

Tool calling adds a second point of no return: the first tool that runs. A tool might send an email or write to a database. If the provider fails after that and the router fails over, the next provider would ask for the same tool again. So once any tool has run in a request, the router stops failing over. It can still retry the same provider, because the tool results are already in the conversation it resends.

Structured output works the other way. `generateObject` shows nothing until the whole reply has been parsed and decoded. The point of no return moves to the end, so an invalid reply can still fail over.

## Not every failure means "try the next one"

A loop that retries everything wastes time and money. A loop that retries nothing isn't failover. The router sorts each failure into one of three classes.

**Retryable: this provider, right now.** HTTP 429, 408, and 5xx, timeouts, dropped connections, and TLS failures. Another provider may well succeed. With a `RetryPolicy`, the same provider may succeed after a short wait.

**Provider-scoped: this provider, for now.** HTTP 401 (bad key), 402 (no credit), 403 (no access), and 404 (unknown or retired model). Retrying the same provider won't help, but the next one probably will. These throw `ProviderUnavailableLlmException`, which fails over without retrying. Vendors don't always use the obvious status: Gemini reports an invalid key as HTTP 400 with `API_KEY_INVALID`, and Anthropic reports low credit as a 400 too. The adapters recognise both.

**Terminal: this request.** A plain HTTP 400 usually means the request itself is wrong: too long, or malformed. Every provider would reject it, so the router stops and throws `TerminalLlmException`. There's one exception: if the conversation contains images or PDFs, a 400 may only mean this model can't take them, so the router fails over.

```dart
try {
  await for (final chunk in router.generateStream(prompt)) {
    buffer.write(chunk);
  }
} on AllProvidersFailedException catch (error) {
  for (final attempt in error.attempts) {
    debugPrint('${attempt.providerName}: ${attempt.statusCode} ${attempt.error}');
  }
} on TerminalLlmException catch (error) {
  debugPrint('Request rejected: ${error.message}');
}
```

## HTTP 200 does not mean success

The status code arrives before the body. In a stream, the provider can send 200, then fail.

All three major APIs do this. OpenAI can send an `error` object as a stream chunk. Anthropic sends an `error` event, for example `overloaded_error`. Gemini can return a `promptFeedback.blockReason` when it blocks the prompt. A client that checks only the status would treat all of these as successful, empty replies.

The adapters parse these in-band errors and throw retryable failures. Anthropic's `overloaded_error` is tagged with status 529, so a `RetryPolicy` treats it like the HTTP status it stands for.

A related case: the stream ends normally with no text at all. Sometimes a safety filter is the cause, sometimes nothing is. Either way, an empty reply is not an answer. The router treats it as a failure and fails over. If the provider said a content filter stopped it, the log says so, and the circuit breaker doesn't count it against the provider, since the prompt caused it.

## A stream that stops talking

The nastiest failure is silence. The connection stays open, the headers arrived, and then nothing. A plain HTTP timeout doesn't help, because it usually covers only the wait for the headers.

`ProviderConfig` has three separate limits:

```dart
const ProviderConfig(
  name: 'openai',
  apiKey: key,
  model: 'gpt-4o-mini',
  pricePerInputToken: 0.00000015,
  pricePerOutputToken: 0.0000006,
  timeout: Duration(seconds: 30),     // waiting for response headers
  idleTimeout: Duration(seconds: 60), // gap between two stream lines
  deadline: Duration(minutes: 3),     // the whole attempt
);
```

`idleTimeout` is the one that catches a stall. SSE keep-alive comments reset it, so a slow but alive model isn't cut off. If a stall happens before the first token, the router aborts the request and fails over. If it happens after, the rule from the first section applies: the error reaches the UI.

## Cancelling has to cancel

When the user taps stop, or leaves the screen, two things should happen: the HTTP request should be aborted, and no other provider should be called. It's easy to get only the first one. A loop that catches the cancellation as a failure fails over to the next provider. Now you pay for a reply nobody will read.

The router checks for cancellation before each provider and after each wait. It aborts the in-flight request with `http`'s `AbortableRequest`. Cancelling the Dart stream subscription is all the caller does:

```dart
final subscription = router.generateStream(prompt).listen(onChunk);
// Later, when the user taps stop:
await subscription.cancel();
```

`dispose` cancels every active request the same way.

## Bill what you were billed for

Providers charge for tokens generated, whether or not you used them. A reply cancelled after 300 tokens costs 300 tokens. So does a reply whose connection dropped halfway.

The router records usage for successful, cancelled, and partly streamed attempts. It prefers the token counts the provider reports in the stream. When a count is missing, as with a cancelled stream that never got its usage event, it estimates from the text length. A failed attempt with no text and no reported usage costs nothing and is not recorded.

```dart
ValueListenableBuilder<double>(
  valueListenable: router.costTracker.totalCostNotifier,
  builder: (context, cost, _) => Text('\$${cost.toStringAsFixed(4)}'),
);
```

## Seeing what happened

Failover that works is invisible, which is the point, and also a problem when you need to debug it. Every attempt is recorded in `router.lastAttemptLogs`: provider, model, latency, time to first token, status, retries, skips, and the error. For production, `router.events` streams the same information for logging and tracing, with provider error bodies redacted by default, since they can echo the prompt.

```dart
router.events.listen((event) {
  if (event case AttemptFinished(:final log) when !log.isSuccess) {
    analytics.log('llm_failover', {
      'provider': log.providerName,
      'status': log.statusCode,
      'error': log.error,
    });
  }
});
```

During development, `RouterInspector` shows the same data live in a widget.

## Summary

- Fail over freely before the first token, or the first tool call. After that, surface the error.
- Classify failures: retry transient ones, skip providers that can't serve, and stop on requests that no provider will accept.
- Don't trust HTTP 200. Parse in-band errors, and treat an empty reply as a failure.
- Bound the silence between stream lines, not just the wait for headers.
- Make cancel abort the request and end the chain.
- Record the cost of every token you were charged for.

`flutter_llm_router` is on [pub.dev](https://pub.dev/packages/flutter_llm_router). The rules above are covered by its test suite, including stalled streams, in-band errors, cancellation during failover, and dispose during a stream.
