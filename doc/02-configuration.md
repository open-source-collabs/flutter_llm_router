# Configuration

`ProviderConfig` describes one upstream in the failover chain.

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | `String` | yes | Display name stored on `AttemptLog`. Also the adapter key when `adapter` is null. Built-ins: `openai`, `anthropic`, `gemini`, `openrouter`, `azure-openai` (case-insensitive). |
| `apiKey` | `String` | yes | Credential for that provider. OpenAI uses `Authorization: Bearer`. Anthropic uses `x-api-key`. Gemini uses `x-goog-api-key`. The key is not placed on the Gemini URL. |
| `model` | `String` | yes | Upstream model id, for example `gpt-4o-mini` or `gemini-2.0-flash`. |
| `pricePerInputToken` | `double` | yes | USD for one input token. Must be `>= 0`. `0.000001` is one micro-dollar. |
| `pricePerOutputToken` | `double` | yes | USD for one output token. Must be `>= 0`. |
| `pricePerCachedInputToken` | `double?` | no | USD for one input token read from the prompt cache. Null charges cached tokens at `pricePerInputToken`. |
| `baseUrl` | `String?` | no | Replaces the vendor host. Null uses the vendor default. |
| `adapter` | `String?` | no | Built-in adapter key, so `name` can be any label. Null uses `name`. `customAdapters` is still matched by `name` first. |
| `timeout` | `Duration` | no | How long to wait for response headers, and for the body of an error response. Default is 30 seconds. |
| `idleTimeout` | `Duration?` | no | Longest gap between two lines of the stream. Default is 60 seconds. Null disables it. |
| `deadline` | `Duration?` | no | Longest total time for one attempt. Default is null, meaning no limit. |
| `maxOutputTokens` | `int` | no | Completion cap for one attempt. Default is 1024. Must be greater than zero. |
| `requestStreamUsage` | `bool` | no | Whether OpenAI-compatible requests send `stream_options.include_usage`. Default is true. Turn it off for servers that reject it; tokens are then estimated. |
| `headers` | `Map<String, String>` | no | Extra headers for every request. A header with a built-in name, such as `authorization`, replaces the built-in one. |
| `settings` | `GenerationSettings` | no | System prompt, temperature, top-p, and stop sequences for this provider. Null fields fall back to `RouterLlmProvider.settings`. See [Attachments and settings](04-attachments-and-settings.md#generation-settings). |
| `capabilities` | `ProviderCapabilities?` | no | Attachment kinds this model accepts. Null uses the adapter's defaults. See [Capabilities](04-attachments-and-settings.md#capabilities). |

A negative price throws `AssertionError` in debug and profile builds.

`id` returns `name/model`, the key used for provider health. `isFree` is true when every price is zero.

Presets such as `ProviderConfig.ollama`, `ProviderConfig.groq`, and `ProviderConfig.azureOpenAi` fill in the endpoint, adapter, and capabilities. See [Presets](04-attachments-and-settings.md#presets).

```dart
const config = ProviderConfig(
  name: 'openai',
  apiKey: 'sk-live',
  model: 'gpt-4o-mini',
  pricePerInputToken: 0.00000015,
  pricePerOutputToken: 0.0000006,
  timeout: Duration(seconds: 20),
);
```

`copyWith` replaces the fields you pass. Passing null for `baseUrl`, `adapter`, `idleTimeout`, `deadline`, `capabilities`, or `pricePerCachedInputToken` clears that value.

`calculateCost(inputTokens: ..., outputTokens: ...)` returns `inputTokens * pricePerInputToken + outputTokens * pricePerOutputToken`. The optional `cachedInputTokens` argument charges that part of `inputTokens` at `pricePerCachedInputToken`. Counts must be `>= 0`.

## Timeouts

Three limits bound one attempt:

- `timeout` bounds the wait for HTTP headers, and the wait for the body of an error response.
- `idleTimeout` bounds the gap between two lines of the stream. SSE keep-alive comments reset it, so a provider that is still thinking does not trip it. Raise it for models that pause for a long time before answering.
- `deadline` bounds the whole attempt, from request to last chunk.

When a limit fires, the request is aborted and the adapter throws `RetryableLlmException`. The router tries the next provider if no text has been yielded.

Dropped sockets, DNS failures, and TLS failures are also retryable. See [Connectivity check](#connectivity-check) for what the router does before failing over on these.

## Cancellation

Cancelling the stream returned by `generateStream` or `sendMessageStream` stops the chain. The pending request is aborted, no later provider is called, and the attempt is logged as cancelled. `router.dispose()` cancels every active request.

## Proxies and custom headers

To keep provider keys out of the app, point `baseUrl` at your backend and authenticate the app with `headers`:

```dart
ProviderConfig(
  name: 'openai',
  apiKey: '',
  model: 'gpt-4o-mini',
  pricePerInputToken: 0.00000015,
  pricePerOutputToken: 0.0000006,
  baseUrl: 'https://api.example.com/llm/openai/v1',
  headers: {'authorization': 'Bearer $userSessionToken'},
)
```

The proxy adds the real provider key before forwarding the request.

## baseUrl

`baseUrl` is the API root, not the full route. The adapter appends the vendor path:

| `name` | Default root | Path |
| --- | --- | --- |
| `openai` | `https://api.openai.com/v1` | `chat/completions` |
| `openrouter` | `https://openrouter.ai/api/v1` | `chat/completions` |
| `anthropic` | `https://api.anthropic.com/v1` | `messages` |
| `gemini` | `https://generativelanguage.googleapis.com/v1beta` | `models/{model}:streamGenerateContent?alt=sse` |
| `azure-openai` | None; `baseUrl` is the deployment URL | `chat/completions?api-version=...` |

A trailing slash on `baseUrl` is ignored, so this still hits the OpenAI-compatible route:

```dart
ProviderConfig(
  name: 'groq',
  adapter: 'openai',
  apiKey: key,
  model: 'llama-3.3-70b-versatile',
  pricePerInputToken: 0,
  pricePerOutputToken: 0,
  baseUrl: 'https://api.groq.com/openai/v1/',
)
```

`ProviderConfig.groq(...)` builds the same config. The request still uses that adapter's JSON shape. An OpenAI-compatible proxy works with the `openai` adapter. Pointing it at a Gemini URL does not.

`name: 'openrouter'` is that same chat-completions call with the OpenRouter root already set. Several entries may share the name. The slug in `model` selects the upstream, for example `openai/gpt-4o-mini`, then `google/gemini-2.5-flash`, then `anthropic/claude-haiku-4.5`. Each entry keeps its own key and prices. Direct `openai`, `gemini`, and `anthropic` entries stay the path for vendor credentials.

## What fails over

| Condition | Exception | Router |
| --- | --- | --- |
| HTTP 429, 408, 500–599 | `RetryableLlmException` | Next provider, if no token was yielded |
| HTTP 401, 402, 403, 404, Gemini invalid key, Anthropic low credit | `ProviderUnavailableLlmException` | Next provider, if no token was yielded |
| Error event inside a 200 stream, blocked prompt, or a reply with no text | `RetryableLlmException` | Next provider, if no token was yielded |
| Timeout, stalled stream, socket drop, TLS failure, device online | `RetryableLlmException` | Next provider, if no token was yielded |
| Timeout, socket drop, device offline | `NoInternetConnectionException` | Chain stops. `attempts` holds the logs so far |
| Any other exception from an adapter | `RetryableLlmException` wrapping it as `cause` | Next provider, if no token was yielded |
| HTTP 400 on a request with image, PDF, audio, or video attachments | `ProviderUnavailableLlmException` | Next provider, if no token was yielded |
| HTTP 400 and other 4xx | `TerminalLlmException` | Logged and rethrown. Later providers are not called |
| Provider can't take an attachment, is over budget, or has an open circuit | None | Skipped and logged with `skipReason`. See [Reliability policies](05-reliability-policies.md) |
| Retryable error after text started | `RetryableLlmException` | Rethrown. The partial answer is not restarted |
| Every provider failed first | `AllProvidersFailedException` | `attempts` holds each `AttemptLog` |

`ProviderUnavailableLlmException` extends `RetryableLlmException`, so existing `on RetryableLlmException` handlers still catch it.

An unknown adapter key (`adapter`, or `name` when `adapter` is null) throws `TerminalLlmException` unless `customAdapters` supplies that `name`.

To retry the same provider before failing over, set `RouterLlmProvider.retryPolicy`. See [Reliability policies](05-reliability-policies.md#retry).

## Connectivity check

A connection error or timeout can mean the provider is down or the device is offline. Before failing over on one, the router calls `connectivityChecker.hasInternet()`. It does this at most once per request and shows nothing to the user.

- `false`: the router throws `NoInternetConnectionException` and skips the remaining providers.
- `true`: the router fails over as usual.

HTTP status failures such as 429 and 503 never trigger the check. Neither do providers whose `baseUrl` is a local or private address, such as `localhost` for Ollama, because their failure says nothing about internet access.

The default `HttpConnectivityChecker` probes `https://www.google.com/generate_204` with a 3-second timeout. If that host cannot be reached, it tries `https://cp.cloudflare.com/generate_204`. Any HTTP response counts as online. A probe that gets no answer in time is inconclusive and counts as online, so a slow network keeps failing over. The device is reported offline only when every probe fails with a connection error. Native platforms send a `HEAD` request. Web uses a `no-cors` `fetch`, so CORS does not hide a reachable host.

Use a different probe where these hosts are blocked or must not be contacted. A custom probe has no fallback:

```dart
RouterLlmProvider(
  providers: providers,
  connectivityChecker: HttpConnectivityChecker(
    probeUrl: Uri.parse('https://example.com/health'),
    timeout: const Duration(seconds: 2),
  ),
);
```

To turn the check off, pass `const AssumeOnlineConnectivityChecker()`.

`NoInternetConnectionException.toString()` returns its plain message. `LlmChatView` hands `onErrorCallback` an `LlmFailureException` carrying that text, so compare `error.message` with `NoInternetConnectionException.defaultMessage` to show an offline UI.

`sendMessageStream` sends each stored turn as its own message. `generateStream` sends only the current prompt. A send that fails or is cancelled before any text arrives stays in `history` for display, but is not sent with later prompts. Requests to `api.openai.com` put the cap in `max_completion_tokens`, which newer OpenAI models require. Other OpenAI-compatible hosts and Anthropic put it in `max_tokens`. Web builds of the Anthropic adapter also send `anthropic-dangerous-direct-browser-access: true`, which Anthropic requires for browser requests. Gemini puts it in `generationConfig.maxOutputTokens`. Anthropic also sends `anthropic-version: 2023-06-01`.
