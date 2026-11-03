# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - Unreleased

1.2.0 is the first release since 1.1.0. It combines four milestones: failover that covers every failure class, real chat features, opt-in reliability policies, and tool calling with structured output. Every new feature is opt-in, but some failures now fail over where they used to stop the chain.

### Upgrade notes

- HTTP 401, 402, 403, and 404, empty replies, and any `Exception` from an adapter now fail over instead of stopping the chain or escaping. See **Failover correctness**.
- Attachments are now sent to providers as real images, PDFs, and text, instead of `toString()` notes in the prompt. See **Chat features**.
- `AdapterChunk` has two new subtypes, `AdapterFinish` and `AdapterToolCall`. Code that switches exhaustively over `AdapterChunk` must handle both.
- The minimum versions are now Dart `^3.8.0` and Flutter `>=3.32.0`.
- `getDocumentEmbedding` and `getQueryEmbedding` are deprecated and will be removed in 2.0.0.

### Failover correctness

Failover now covers the failures that used to stop the chain or hang it.

#### Changed

- HTTP 401, 402, 403, and 404 now fail over to the next provider instead of stopping the chain. They throw the new `ProviderUnavailableLlmException`, which extends `RetryableLlmException`. Gemini's HTTP 400 `API_KEY_INVALID` and Anthropic's HTTP 400 for low credit balance are treated the same way. Code that caught `TerminalLlmException` for a bad key now gets `AllProvidersFailedException` when every provider fails.
- A stream that ends without text is now a failure that fails over, instead of an empty success. Empty text chunks no longer block failover.
- Any `Exception` from an adapter, such as a TLS failure or a custom adapter's own error, now fails over and is logged, instead of escaping the router.
- Usage is now recorded for cancelled replies, replies that fail after text arrived, and failed attempts where the provider reported token counts. Gemini thinking tokens count as output tokens.
- `RouterLlmProvider` throws `ArgumentError` for an empty `providers` list in every build mode, instead of asserting only in debug builds.
- `HttpConnectivityChecker` treats a probe timeout as online, and the default probe falls back to `https://cp.cloudflare.com/generate_204` when Google cannot be reached. A local or private `baseUrl` no longer triggers the probe.
- OpenAI requests to `api.openai.com` send `max_completion_tokens` instead of `max_tokens`, which newer models require.
- Raised the minimum versions to Dart `^3.8.0` and Flutter `>=3.32.0`. `flutter_lints ^6.0.0` needs Dart 3.8, and the previous Flutter floor did not match the Dart floor.

#### Fixed

- A stream that stalled after the response headers could hang forever. `ProviderConfig.idleTimeout` (default 60 seconds) and `ProviderConfig.deadline` now bound it, and an error response body is bounded by `timeout`.
- Error events inside a 200 stream (OpenAI and OpenRouter `error` chunks, Anthropic `error` events such as `overloaded_error`, Gemini `error` objects and blocked prompts) were treated as success. They now fail over.
- Cancelling a reply did not stop the chain, and timed-out requests kept running. Cancelling or timing out now aborts the HTTP request, and no later provider is called.
- Disposing the router during a stream could throw. `dispose` now cancels active requests and can be called more than once.
- A failed send was resent with the next prompt. Failed and cancelled sends stay in `history` for display but are no longer sent upstream.
- A slower earlier call could overwrite `lastAttemptLogs` from a newer one.
- Anthropic requests from web builds were blocked by CORS. The adapter now sends `anthropic-dangerous-direct-browser-access` on web.

#### Added

- `ProviderUnavailableLlmException` and `AssumeOnlineConnectivityChecker`.
- `ProviderConfig.idleTimeout`, `deadline`, `requestStreamUsage`, and `headers`. `headers` supports backend proxies and can replace built-in headers such as `authorization`.
- `RouterLlmProvider.attemptLogs`, a `ValueListenable` of the latest attempt logs.
- `BaseLlmAdapter.isProviderScopedFailure` and `throwStreamError` for custom adapters. `postSse` takes optional `idleTimeout` and `deadline`.
- CI, tag-based publishing, Dependabot, and issue and pull request templates.
- `CONTRIBUTING.md`, `SECURITY.md`, and `CODE_OF_CONDUCT.md`.
- API key guidance in the README and quickstart.
- macOS runner for the example app.

#### Documentation

- README attempt-log snippet used `AttemptLog` fields that do not exist.
- Example and quickstart docs described an OpenRouter setup the example no longer uses.

#### Removed

- Unused example files: `view_model/chat_router_view_model.dart`, `widgets/api_keys_dialog.dart`, and `widgets/attempt_logs_sheet.dart`.

### Chat features

Attachments are now sent for real. This part also adds request settings and provider presets, and reports why a provider stopped.

#### Changed

- Attachments are sent to providers as images, PDFs, and text instead of being appended to the prompt as `toString()` notes, which sent the file name and size but not the content. `ChatTurn.text` now holds only the message text.
- `AdapterChunk` has a new subtype, `AdapterFinish`. Code that switches exhaustively over `AdapterChunk` must add a case for it.
- An HTTP 400 on a request with image, PDF, audio, or video attachments now fails over, because the model may not accept that media. Without such attachments, HTTP 400 still stops the chain.
- Gemini thought-summary parts are no longer shown as reply text. Their tokens are still billed as output.

#### Added

- `ChatTurn.attachments`, with `TurnAttachment`, `FileTurnAttachment`, `LinkTurnAttachment`, and `AttachmentKind`. Each adapter maps them to its vendor format: OpenAI `image_url` and `file` parts, Anthropic `image` and `document` blocks, Gemini `inlineData`. Text files are inlined as text for every vendor. Non-image links are sent as text references.
- `ChatTurn.toAnthropicMessage`.
- `ProviderCapabilities` and `ProviderConfig.capabilities`, plus `BaseLlmAdapter.capabilities`. The router skips a provider that cannot take the conversation's attachments and logs the reason, instead of sending a request that would fail or drop the file.
- `GenerationSettings` with `systemPrompt`, `temperature`, `topP`, and `stopSequences`. Set defaults on `RouterLlmProvider.settings` and override per provider with `ProviderConfig.settings`.
- `FinishReason` and `AdapterFinish`. `AttemptLog.finishReason` shows a reply cut off at `maxOutputTokens` (`FinishReason.length`) or stopped by a content filter. A filtered reply with no text fails over.
- Provider presets: `ProviderConfig.ollama`, `lmStudio`, `groq`, `mistral`, `deepSeek`, and `azureOpenAi`.
- `AzureOpenAiAdapter`, used with the `azure-openai` adapter key.
- `ProviderConfig.adapter`, which picks the built-in adapter so `name` can be any display label.
- `ProviderConfig.id` and `isFree`.
- `OpenAiAdapter.chatUrl`, `authHeaders`, and `maxTokensField`, for adapters that target other OpenAI-compatible hosts.
- Groq usage reported under `x_groq.usage` is read.

#### Deprecated

- `RouterLlmProvider.getDocumentEmbedding` and `getQueryEmbedding`. They always threw and will be removed in 2.0.0.

### Reliability policies

This part adds production reliability controls: same-provider retries, a circuit breaker, routing strategies, budgets, an event stream, a debug panel, and a response cache. Every feature is opt-in. With the defaults, routing behaves as it did without them.

#### Added

- `RetryPolicy` and `RouterLlmProvider.retryPolicy`. Retries the same provider with exponential backoff and jitter before failing over. Only transient failures are retried: HTTP 408, 429, 5xx, timeouts, and dropped connections. A `Retry-After` longer than `maxDelay` skips the retry and fails over. The default, `RetryPolicy.none`, does not retry.
- `RetryableLlmException.retryAfter`, read from the `retry-after-ms` header or a `Retry-After` header in seconds.
- Anthropic's in-stream `overloaded_error` now carries status 529, so it can be retried.
- `CircuitBreakerPolicy` and `RouterLlmProvider.circuitBreaker`. After `failureThreshold` consecutive failed requests, a provider is skipped for `cooldown`, then one trial request decides whether it comes back. If every circuit is open, the router tries the providers anyway. `RouterLlmProvider.providerHealth` exposes `ProviderHealth` (circuit state, success and failure counts, average time to first token) keyed by `ProviderConfig.id`. `resetCircuits` closes every circuit.
- `RoutingStrategy` and `RouterLlmProvider.routingStrategy`, with `PriorityRoutingStrategy` (default), `CheapestFirstRoutingStrategy`, `LowestLatencyRoutingStrategy`, and `WeightedRoutingStrategy`.
- `BudgetPolicy` and `RouterLlmProvider.budget`. A provider over its entry in `providerLimitsUsd` is skipped. Over `sessionLimitUsd`, only free providers are called. When nothing within budget remains, the router throws the new `BudgetExceededException` without calling a provider.
- `CostTracker.usageByProvider`, `costFor`, and `totalCachedInputTokens`, plus the `ProviderUsage` type.
- Cached-token pricing: `ProviderConfig.pricePerCachedInputToken`, `AdapterUsage.cachedInputTokens`, and a `cachedInputTokens` argument on `calculateCost` and `recordUsage`. OpenAI, DeepSeek, Anthropic, and Gemini cache counts are read from the stream.
- `RouterLlmProvider.events`, a broadcast stream of `RouterEvent`: `RequestStarted`, `AttemptStarted`, `AttemptFinished`, `RetryScheduled`, `CircuitStateChanged`, `UsageRecorded`, and `RequestFinished`.
- `RouterLlmProvider.redactEventErrors`, true by default, and `LlmRouterException.redactedMessage`. Events leave provider response bodies out of error messages, because they can echo the prompt. `lastAttemptLogs` and thrown exceptions keep the full message.
- `RouterInspector`, a widget that shows spend, provider health, and the attempts of the latest request live.
- `ResponseCache`, `InMemoryResponseCache`, `CachedResponse`, and `RouterLlmProvider.responseCache`. Only complete, successful replies are stored. Cache errors never fail a request.
- `AttemptLog.timeToFirstTokenMs`, `retry`, `skipReason`, `isSkipped`, and `fromCache`. Skipped providers and cache hits now appear in `lastAttemptLogs`.
- API key pools. `ProviderConfig.apiKeys` adds keys to `apiKey` (`ProviderConfig.allKeys` lists them all), and `KeyPoolPolicy` with `RouterLlmProvider.keyPool` sets `KeyRotation.roundRobin` (default) or `KeyRotation.priority`. A key that fails with HTTP 429 rests for its `Retry-After`, or `rateLimitCooldown` (60 seconds); a key that fails with 401, 402, or 403 rests for `invalidKeyCooldown` (10 minutes). The router retries the same provider with the next key before it fails over, which matters when no other provider can do the job, such as image generation. When every key of a provider is resting, the provider is skipped with a `skipReason`. `AttemptLog.keyIndex` shows which key an attempt used; the key itself is never logged. A provider with a single key behaves as before.

### Tools and structured output

This part adds tool calling and structured output. Both are opt-in. Read **Changed** if you wrote a custom adapter or switch over `AdapterChunk`.

#### Added

- Tool calling. Pass `RouterTool`s to `RouterLlmProvider.tools`. When a model calls one, the router runs its `ToolHandler`, sends the `ToolResult` back to the same provider, and streams the final reply. `maxToolRounds` (default 8) caps the rounds; going past it throws `TerminalLlmException`.
  - New types: `ToolDefinition`, `RouterTool`, `ToolHandler`, `ToolCall`, `ToolResult`.
  - Tools in one round run concurrently. Results go back in call order. A handler that throws an `Exception`, an unknown tool name, or a result that can't be encoded as JSON becomes an error result, so the model can recover.
  - `ChatTurn.toolCalls` and `ChatTurn.toolResults`, and `ChatTurn.toOpenAiMessages`, which yields one `tool` message per result.
  - `AdapterToolCall`, yielded once per complete call. OpenAI streamed `tool_calls` fragments and Anthropic `input_json_delta` blocks are assembled by the adapters. Gemini `functionCall` parts are read whole.
  - Gemini's `thoughtSignature` is kept in `ToolCall.providerData` and sent back with the call, as Gemini requires.
  - `ToolCallFinished` event, with tool name, call id, duration, and whether it failed.
  - `ProviderCapabilities.tools`. When tools are set, providers with `tools: false` are skipped and the reason is logged.
  - `BaseLlmAdapter.decodeToolArguments` for custom adapters. Malformed arguments are retryable.
- Structured output. `RouterLlmProvider.generateObject` asks for a reply that matches a `ResponseSchema` and returns it decoded.
  - Every provider gets the schema in its system prompt. OpenAI-compatible APIs also get `response_format` with `json_schema`. Gemini switches to JSON mode with `responseMimeType`.
  - The reply is parsed as JSON (a surrounding code fence is tolerated) and passed to your `decode` function. If either step fails, the attempt fails with the new `InvalidStructuredOutputException` and the router fails over.
- `GenerationSettings.tools` and `GenerationSettings.responseSchema`. The router fills them from `tools` and `generateObject`.
- The live contract tests now cover a tool round-trip and structured output for each vendor.
- A seeded chaos benchmark (`test/chaos`) that injects eight failure classes and checks that every failure is classified and none hangs. Results are in `doc/11-reliability-benchmark.md`.
- Example app: a keyless demo mode that streams simulated replies, and a workflow that publishes the example to GitHub Pages as a live web demo.

#### Changed

- `AdapterChunk` has a new subtype, `AdapterToolCall`. Code that switches exhaustively over `AdapterChunk` must add a case.
- Failover stops once a tool has run in a request. A later failure is rethrown, so a tool never runs twice because a provider failed. `RetryPolicy` still retries the same provider, which is safe because the tool results are already in the conversation. Failover before the first tool call works as before.
- `generateObject` buffers the reply and emits it only after it validates, so an invalid reply can still fail over.
- The response cache key now includes the tools and the schema. Cached `generateStream` replies don't answer `generateObject`, and the reverse.

## [1.1.0] - 2026-10-17

- Added connectivity-aware failover. When a provider fails with a connection error or timeout, `RouterLlmProvider` silently probes the internet once per request. If the device is offline, it throws the new `NoInternetConnectionException` instead of trying every provider. If the device is online, it fails over as before.
- Added `ConnectivityChecker` and `HttpConnectivityChecker`. The default probe is `https://www.google.com/generate_204` with a 3-second timeout, using `HEAD` on native platforms and a `no-cors` `fetch` on web. Configure it through `RouterLlmProvider(connectivityChecker: ...)`.
- Example app: added a "Simulate OpenAI network failure" switch and an offline SnackBar through `LlmChatView.onErrorCallback`.

## [1.0.4] - 2026-10-11

- Added screenshots to the pub.dev listing: failover, cost tracking, and quickstart.

## [1.0.3] - 2026-10-10

- Added explicit Windows and Linux (full cross-platform) support declarations in `pubspec.yaml`.
- Added native Windows (`example/windows/`) and Linux (`example/linux/`) desktop runner scaffolding to enable running the example app natively on both desktop platforms.
- Updated `http` dependency constraint to `^1.6.0`.
- Updated documentation with Windows and Linux desktop setup instructions and synchronized dependency version requirements.

## [1.0.2] - 2026-10-06

- Upgraded `flutter_ai_toolkit` constraint to `^1.0.0` and `flutter_lints` to `^6.0.0`.
- Removed discontinued `firebase_vertexai` dependency.
- Updated `RouterLlmProvider` embedding methods and documentation for `flutter_ai_toolkit 1.0.0`.

## [1.0.1] - 2026-10-04

- Added direct multi-provider configurations for OpenAI, Google Gemini, and Anthropic Claude.
- Refactored example app with MVVM state management (`ChatRouterViewModel`).
- Added compile-time `--dart-define` key configuration support.
- Exported adapters and model types in public library exports.
- Updated repository and issue tracker URLs to open-source-collabs.

## [1.0.0] - 2026-10-01

First release of the local package. It is not published to pub.dev.

### Added

- Package layout for `flutter_llm_router`: public `lib/` exports, `test/`, `doc/`, and `example/`, with MIT license and strict analyzer options.
- `ProviderConfig` for a named upstream model, API key, per-token USD prices, optional `baseUrl`, and a 30-second default `timeout`. Includes `copyWith` and `calculateCost`.
- `AttemptLog` for one provider try: name, model, timestamp, latency, success, error text, and HTTP status.
- `CostTracker` with `totalCostNotifier` (`ValueListenable<double>`), token counters, `recordUsage`, `recordCost`, `reset`, and `dispose`.
- `LlmRouterException`, `RetryableLlmException`, `TerminalLlmException`, and `AllProvidersFailedException`.
- SSE adapters for OpenAI chat completions, Anthropic `content_block_delta`, Gemini `streamGenerateContent?alt=sse`, and OpenRouter chat completions at `https://openrouter.ai/api/v1`. HTTP 429, 408, and 5xx, plus timeouts and socket drops, are retryable. HTTP 400, 401, and 403 are terminal. The adapters use `package:http` and do not import `dart:io`.
- `RouterLlmProvider`, an `LlmProvider` that walks providers in order. A retryable failure before the first token fails over. A terminal failure is logged and rethrown. If every provider fails, the router throws `AllProvidersFailedException`. Successful streams record estimated token cost. `lastAttemptLogs` exposes the latest attempt list. Built-in names are `openai`, `anthropic`, `gemini`, and `openrouter`. `customAdapters` overrides that lookup.
- Example chat app on `LlmChatView` that sends one OpenRouter key through `openai/gpt-4o-mini`, then `google/gemini-2.5-flash`, then `anthropic/claude-haiku-4.5`. A switch simulates HTTP 429. The app bar shows live spend, and a sheet lists attempt logs. The example Android manifest allows internet access.

### Notes

- Token counts are `(text.length + 3) ~/ 4`, not the provider's billed tokenizer.
- `getDocumentEmbedding` and `getQueryEmbedding` are unimplemented.
- `flutter_ai_toolkit` 0.5.0 is pinned, and `firebase_vertexai` is constrained to `>=1.0.1 <1.5.0` because later releases removed `TaskType`.
