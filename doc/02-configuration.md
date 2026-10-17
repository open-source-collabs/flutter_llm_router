# Configuration

`ProviderConfig` describes one upstream in the failover chain.

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | `String` | yes | Adapter key and the name stored on `AttemptLog`. Built-ins: `openai`, `anthropic`, `gemini`, `openrouter` (case-insensitive). |
| `apiKey` | `String` | yes | Credential for that provider. OpenAI uses `Authorization: Bearer`. Anthropic uses `x-api-key`. Gemini uses `x-goog-api-key`. The key is not placed on the Gemini URL. |
| `model` | `String` | yes | Upstream model id, for example `gpt-4o-mini` or `gemini-2.0-flash`. |
| `pricePerInputToken` | `double` | yes | USD for one input token. Must be `>= 0`. `0.000001` is one micro-dollar. |
| `pricePerOutputToken` | `double` | yes | USD for one output token. Must be `>= 0`. |
| `baseUrl` | `String?` | no | Replaces the vendor host. Null uses the vendor default. |
| `timeout` | `Duration` | no | How long to wait for response headers. Default is 30 seconds. |
| `maxOutputTokens` | `int` | no | Completion cap for one attempt. Default is 1024. Must be greater than zero. |

A negative price throws `AssertionError` in debug and profile builds.

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

`copyWith` replaces the fields you pass. `copyWith(baseUrl: null)` clears an override.

`calculateCost(inputTokens: ..., outputTokens: ...)` returns `inputTokens * pricePerInputToken + outputTokens * pricePerOutputToken`. Both counts must be `>= 0`.

## Timeout

`timeout` bounds `Client.send`, the wait for HTTP headers. It does not cut the stream off between tokens. When it fires, the adapter throws `RetryableLlmException` and the router tries the next provider if no text has been yielded.

A dropped socket or other `ClientException` is also retryable. See [Connectivity check](#connectivity-check) for what the router does before failing over on these.

## baseUrl

`baseUrl` is the API root, not the full route. The adapter appends the vendor path:

| `name` | Default root | Path |
| --- | --- | --- |
| `openai` | `https://api.openai.com/v1` | `chat/completions` |
| `openrouter` | `https://openrouter.ai/api/v1` | `chat/completions` |
| `anthropic` | `https://api.anthropic.com/v1` | `messages` |
| `gemini` | `https://generativelanguage.googleapis.com/v1beta` | `models/{model}:streamGenerateContent?alt=sse` |

A trailing slash on `baseUrl` is ignored, so this still hits the OpenAI-compatible route:

```dart
ProviderConfig(
  name: 'openai',
  apiKey: key,
  model: 'llama-3.3-70b-versatile',
  pricePerInputToken: 0,
  pricePerOutputToken: 0,
  baseUrl: 'https://api.groq.com/openai/v1',
)
```

The request still uses that vendor's JSON shape. An OpenAI-compatible proxy works with `name: 'openai'`. Pointing that name at a Gemini URL does not.

`name: 'openrouter'` is that same chat-completions call with the OpenRouter root already set. Several entries may share the name. The slug in `model` selects the upstream, for example `openai/gpt-4o-mini`, then `google/gemini-2.5-flash`, then `anthropic/claude-haiku-4.5`. Each entry keeps its own key and prices. Direct `openai`, `gemini`, and `anthropic` entries stay the path for vendor credentials.

## What fails over

| Condition | Exception | Router |
| --- | --- | --- |
| HTTP 429, 408, 500–599 | `RetryableLlmException` | Next provider, if no token was yielded |
| Timeout, socket drop, device online | `RetryableLlmException` | Next provider, if no token was yielded |
| Timeout, socket drop, device offline | `NoInternetConnectionException` | Chain stops. `attempts` holds the logs so far |
| HTTP 400, 401, 403, other 4xx | `TerminalLlmException` | Logged and rethrown. Later providers are not called |
| Retryable error after text started | `RetryableLlmException` | Rethrown. The partial answer is not restarted |
| Every provider failed first | `AllProvidersFailedException` | `attempts` holds each `AttemptLog` |

Unknown `name` values throw `TerminalLlmException` unless `customAdapters` supplies that name.

## Connectivity check

A connection error or timeout can mean the provider is down or the device is offline. Before failing over on one, the router calls `connectivityChecker.hasInternet()`. It does this at most once per request and shows nothing to the user.

- `false`: the router throws `NoInternetConnectionException` and skips the remaining providers.
- `true`: the router fails over as usual.

HTTP status failures such as 429 and 503 never trigger the check.

The default `HttpConnectivityChecker` probes `https://www.google.com/generate_204` with a 3-second timeout. Any HTTP response counts as online. Native platforms send a `HEAD` request. Web uses a `no-cors` `fetch`, so CORS does not hide a reachable host.

Use a different probe where Google is blocked:

```dart
RouterLlmProvider(
  providers: providers,
  connectivityChecker: HttpConnectivityChecker(
    probeUrl: Uri.parse('https://example.com/health'),
    timeout: const Duration(seconds: 2),
  ),
);
```

To turn the check off, pass a `ConnectivityChecker` whose `hasInternet` always returns `true`.

`NoInternetConnectionException.toString()` returns its plain message. `LlmChatView` hands `onErrorCallback` an `LlmFailureException` carrying that text, so compare `error.message` with `NoInternetConnectionException.defaultMessage` to show an offline UI.

`sendMessageStream` sends each stored turn as its own message. `generateStream` sends only the current prompt. OpenAI-compatible and Anthropic requests put that cap in `max_tokens`. Gemini puts it in `generationConfig.maxOutputTokens`. Anthropic also sends `anthropic-version: 2023-06-01`.
