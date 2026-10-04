# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
