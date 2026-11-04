# Production checklist

Work through this before shipping an app that uses `flutter_llm_router`.

## Keys and security

- [ ] No production API keys ship in the app. Keys in a client build can be extracted, including keys passed through `--dart-define`. Use a [backend proxy](08-backend-proxy.md) with `baseUrl` and `headers`, or let users supply their own keys.
- [ ] The proxy authenticates the user and enforces rate and spend limits on the server. Client-side `BudgetPolicy` is a guard rail, not a security control.
- [ ] Telemetry gets redacted errors. Keep `redactEventErrors` at its default of true unless your telemetry may hold prompt content.
- [ ] `RouterInspector` is behind a debug flag or limited to internal builds.

## Failover chain

- [ ] At least two providers from different vendors, so one vendor's outage doesn't take the chat down.
- [ ] Every model id is current. A retired model returns 404, which fails over but adds latency to each request. Add a [circuit breaker](05-reliability-policies.md#circuit-breaker) so a dead provider is skipped.
- [ ] Prices on each `ProviderConfig` match the vendor's pricing page, converted to USD per token. Set `pricePerCachedInputToken` where the vendor discounts cache hits.
- [ ] `capabilities` is set for any model that lacks vision or PDF support, if your app lets users attach files.
- [ ] Settings each model rejects, such as `temperature` on reasoning models, are set per provider, not on the router.

## Latency

- [ ] `timeout`, `idleTimeout`, and `deadline` fit your UX. Worst-case wait is roughly the sum of every provider's timeouts and retries.
- [ ] `RetryPolicy.maxRetries` is small (0–2) for interactive chat.
- [ ] `circuitBreaker` is set so known-bad providers don't cost a timeout on every request.

## Cost

- [ ] The spend label or analytics reads `costTracker`. `usageByProvider` shows where money goes.
- [ ] A `BudgetPolicy` matches how you bill or limit users, and `costTracker.reset()` runs at the right boundary, such as per session or per day.
- [ ] `maxOutputTokens` is set deliberately. Watch for `FinishReason.length` in attempt logs to see truncation.

## Errors and UX

- [ ] `LlmChatView.onErrorCallback` handles `NoInternetConnectionException.defaultMessage` with an offline message.
- [ ] `BudgetExceededException` and `AllProvidersFailedException` show a useful message, not a stack trace.
- [ ] The app disposes the router (and any tracker it owns) when the chat screen goes away.

## Observability

- [ ] `router.events` feeds your logging or tracing, at least `RequestFinished` failures and `CircuitStateChanged`.
- [ ] Alerts exist for a rising failover rate or an open circuit on your primary provider.

## Testing

- [ ] Run the app with an invalid key on the first provider and confirm the next one answers.
- [ ] Run it offline and confirm the offline message.
- [ ] Send an image with a text-only provider first and confirm it is skipped.
- [ ] Your own tests use `customAdapters` with scripted streams, as the package's tests do, instead of calling real vendors.
