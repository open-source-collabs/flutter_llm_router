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

A dropped socket or other `ClientException` is also retryable.

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
| Timeout, socket drop | `RetryableLlmException` | Next provider, if no token was yielded |
| HTTP 400, 401, 403, other 4xx | `TerminalLlmException` | Logged and rethrown. Later providers are not called |
| Retryable error after text started | `RetryableLlmException` | Rethrown. The partial answer is not restarted |
| Every provider failed first | `AllProvidersFailedException` | `attempts` holds each `AttemptLog` |

Unknown `name` values throw `TerminalLlmException` unless `customAdapters` supplies that name.

`sendMessageStream` sends each stored turn as its own message. `generateStream` sends only the current prompt. OpenAI-compatible and Anthropic requests put that cap in `max_tokens`. Gemini puts it in `generationConfig.maxOutputTokens`. Anthropic also sends `anthropic-version: 2023-06-01`.
