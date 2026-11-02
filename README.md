# flutter_llm_router

[![CI](https://github.com/open-source-collabs/flutter_llm_router/actions/workflows/ci.yml/badge.svg)](https://github.com/open-source-collabs/flutter_llm_router/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/flutter_llm_router.svg)](https://pub.dev/packages/flutter_llm_router)
[![pub points](https://img.shields.io/pub/points/flutter_llm_router)](https://pub.dev/packages/flutter_llm_router/score)
[![pub likes](https://img.shields.io/pub/likes/flutter_llm_router)](https://pub.dev/packages/flutter_llm_router)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Dart](https://img.shields.io/badge/Dart-%5E3.8.0-0175C2?logo=dart&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.32.0-02569B?logo=flutter&logoColor=white)
[![Platforms](https://img.shields.io/badge/platforms-windows%20%7C%20android%20%7C%20ios%20%7C%20web%20%7C%20macos%20%7C%20linux-blue.svg)](pubspec.yaml)

A resilient multi-provider LLM router for Flutter AI Toolkit. `RouterLlmProvider` implements `LlmProvider`, so it seamlessly drops into `LlmChatView` and adds automatic failover, real-time token cost tracking, and attempt logging across Windows, macOS, Linux, Android, iOS, and Web.

## Features

- **Transparent Failover**: Tries configured LLM providers in priority order. Automatically recovers from rate limits (HTTP 429), 5xx errors, bad keys and exhausted credit, retired models, stalled streams, error events inside a stream, and empty replies.
- **Cancellation**: Cancelling a reply aborts the HTTP request and stops the chain.
- **Connectivity-Aware Failover**: On a connection error, silently probes the internet. If the device is offline, it stops with a clear `NoInternetConnectionException` instead of cycling through every provider.
- **Drop-in UI Integration**: Compatible with Flutter AI Toolkit's `LlmChatView`.
- **Multi-Provider Support**: Built-in adapters for OpenAI, Google Gemini, Anthropic Claude, OpenRouter, and Azure OpenAI, presets for Ollama, LM Studio, Groq, Mistral, and DeepSeek, plus custom adapters.
- **Attachments**: Images, PDFs, and text files are sent in each vendor's format. Providers that can't take an attachment are skipped, with the reason logged.
- **Request Settings**: System prompt, temperature, top-p, and stop sequences, set once or per provider.
- **Tool Calling**: Give the model Dart functions to call. The router runs them, sends the results back, and streams the final reply.
- **Structured Output**: `generateObject` returns a reply decoded against a JSON Schema, and fails over when a provider returns invalid JSON.
- **Reliability Policies** (opt-in): Same-provider retries with backoff and `Retry-After`, a circuit breaker, and routing strategies (priority, cheapest, lowest latency, weighted).
- **Budgets** (opt-in): Per-provider and per-session spending limits.
- **Live Token & Cost Tracking**: Configurable USD token pricing, cached-token pricing, and a per-provider breakdown with real-time `ValueNotifier` updates.
- **Observability**: Attempt logs (`lastAttemptLogs`), an `events` stream for logging and tracing with error redaction, and a `RouterInspector` debug widget.
- **Response Cache** (opt-in): Answers repeated requests without a provider call.

## Installation

Add `flutter_llm_router` and `flutter_ai_toolkit` to your project:

```sh
flutter pub add flutter_llm_router flutter_ai_toolkit
```

Or add them to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_ai_toolkit: ^1.0.0
  flutter_llm_router: ^1.2.0
```

## Problem

A single upstream outage, HTTP 429 rate limit, or network timeout breaks the chat experience. In addition, token spend remains hidden until the vendor invoice arrives, and there is no record of which provider responded or failed.

## Solution

Point `LlmChatView` at one `RouterLlmProvider`. The router tries each `ProviderConfig` in order:

- HTTP 429, 408, 5xx, timeouts, stalled streams, dropped sockets, error events inside a stream, and empty replies raise `RetryableLlmException` and move to the next provider (as long as no text has been yielded yet).
- HTTP 401, 402, 403, and 404 mean only this provider can't serve the request (bad key, no credit, no access, unknown model). They raise `ProviderUnavailableLlmException` and move to the next provider.
- On a connection error or timeout, the router silently checks whether the device is online (once per request). If it is offline, the router throws `NoInternetConnectionException`. If it is online, only that provider is unreachable, so the router moves to the next one.
- Other non-success statuses, such as HTTP 400, raise `TerminalLlmException` and stop the chain immediately, because every provider would reject the same request.
- If every provider fails, the router throws `AllProvidersFailedException` containing the complete attempt history.
- Completed streams update `CostTracker` and `lastAttemptLogs`.

### Reliability, measured

A seeded chaos run (`test/chaos`) sends 2,000 requests per setup while each simulated provider fails 20% of its calls. Each failure is one of eight classes: 429, 503, 401, timeout, dropped connection, in-band error, empty reply, or a drop after text.

| Setup | Succeeded | Failed after partial text |
| :--- | :--- | :--- |
| 1 provider | 79.8% | 2.1% |
| 3 providers, failover | 96.4% | 2.8% |
| 3 providers, failover + 1 retry | 97.2% | 2.8% |

In every setup, every failure surfaced as a classified `LlmRouterException`, and no request hung. A drop after text has already been shown can't fail over by design. These are simulated, independent failures, not vendor uptime; see the [Reliability Benchmark](doc/11-reliability-benchmark.md) for the method and limits.

### Supported Providers

| Name | Adapter | Default Base URL | Model Example |
| :--- | :--- | :--- | :--- |
| `openai` | `OpenAiAdapter` | `https://api.openai.com/v1` | `gpt-4o-mini` |
| `gemini` | `GeminiAdapter` | `https://generativelanguage.googleapis.com/v1beta` | `gemini-2.0-flash` |
| `anthropic` | `AnthropicAdapter` | `https://api.anthropic.com/v1` | `claude-3-5-haiku-latest` |
| `openrouter` | `OpenRouterAdapter` | `https://openrouter.ai/api/v1` | `openai/gpt-4o-mini`, `anthropic/claude-3.5-haiku` |
| `azure-openai` | `AzureOpenAiAdapter` | Set by `ProviderConfig.azureOpenAi` | Your deployment name |

You can repeat `openrouter` across multiple entries with different `model` slugs to fail over between upstream models using a single OpenRouter API key.

`name` picks the adapter unless you set `ProviderConfig.adapter`, so `name: 'fast', adapter: 'openai'` works too.

## Quickstart

```dart
import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final CostTracker _costTracker;
  late final RouterLlmProvider _router;

  @override
  void initState() {
    super.initState();
    _costTracker = CostTracker();
    _router = RouterLlmProvider(
      costTracker: _costTracker,
      providers: [
        ProviderConfig(
          name: 'openai',
          apiKey: 'YOUR_OPENAI_KEY',
          model: 'gpt-4o-mini',
          pricePerInputToken: 0.00000015,
          pricePerOutputToken: 0.0000006,
        ),
        ProviderConfig(
          name: 'gemini',
          apiKey: 'YOUR_GEMINI_KEY',
          model: 'gemini-2.0-flash',
          pricePerInputToken: 0.0000001,
          pricePerOutputToken: 0.0000004,
        ),
        ProviderConfig(
          name: 'openrouter',
          apiKey: 'YOUR_OPENROUTER_KEY',
          model: 'anthropic/claude-3.5-haiku',
          pricePerInputToken: 0.0000008,
          pricePerOutputToken: 0.000004,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _router.dispose();
    _costTracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resilient Chat'),
        actions: [
          // Live token spend label
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: ValueListenableBuilder<double>(
                valueListenable: _costTracker.totalCostNotifier,
                builder: (context, totalCost, _) {
                  return Text(
                    '\$${totalCost.toStringAsFixed(6)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  );
                },
              ),
            ),
          ),
        ],
      ),
      body: LlmChatView(
        provider: _router,
        welcomeMessage: 'Ask a question. If OpenAI hits a 429, it automatically fails over to Gemini.',
      ),
    );
  }
}
```

The runnable demonstration is in [example/](example/), supporting Windows, macOS, Linux, Web, Android, and iOS. It adds simulated outage toggles, API key management, the live spend label, and an attempt history inspection sheet.

## Live Cost Tracking

Prices on `ProviderConfig` are configured in USD per token (e.g. `0.000001` is one micro-dollar). After a successful stream:
1. The router uses the provider's reported token counts if provided by the stream.
2. If token counts are omitted, it estimates tokens as `(text.length + 3) ~/ 4`.
3. It updates `costTracker` with both token counts and calculated cost.

```dart
ValueListenableBuilder<double>(
  valueListenable: router.costTracker.totalCostNotifier,
  builder: (context, totalCost, _) {
    return Text('\$${totalCost.toStringAsFixed(6)}');
  },
)
```

Read `router.costTracker.totalInputTokens` and `router.costTracker.totalOutputTokens` to inspect token counts, and `router.costTracker.usageByProvider` for a per-provider breakdown. Set `pricePerCachedInputToken` to price prompt-cache hits at the vendor's discounted rate.

## Attempt History & Logging

Inspect `router.lastAttemptLogs` to see how each provider attempt performed during the last turn. Listen to `router.attemptLogs` to update a UI as attempts finish:

```dart
for (final log in router.lastAttemptLogs) {
  print('${log.providerName} (${log.model}): success=${log.isSuccess}, status=${log.statusCode}, error=${log.error}');
}
```

Each log also carries `timeToFirstTokenMs`, `finishReason`, `retry`, `skipReason` (for providers the router skipped), and `fromCache`.

## Attachments and Capabilities

Images, PDFs, and text files attached in `LlmChatView` reach the provider. OpenAI receives `image_url` and `file` parts, Anthropic `image` and `document` blocks, and Gemini `inlineData`. Text files are inlined as text everywhere.

If a provider can't take an attachment, the router skips it and logs why in `AttemptLog.skipReason`. Declare a model's limits with `capabilities`:

```dart
ProviderConfig(
  name: 'openai',
  apiKey: key,
  model: 'gpt-3.5-turbo',
  pricePerInputToken: 0.0000005,
  pricePerOutputToken: 0.0000015,
  capabilities: ProviderCapabilities.textOnly,
)
```

See [Attachments and settings](doc/04-attachments-and-settings.md).

## Request Settings

```dart
final router = RouterLlmProvider(
  providers: providers,
  settings: const GenerationSettings(
    systemPrompt: 'You are a concise assistant.',
    temperature: 0.3,
  ),
);
```

`ProviderConfig.settings` overrides any field for one provider. `AttemptLog.finishReason` tells you when a reply was cut off (`FinishReason.length`) or filtered (`FinishReason.contentFilter`).

## Tool Calling

```dart
final router = RouterLlmProvider(
  providers: providers,
  tools: [
    RouterTool(
      name: 'get_weather',
      description: 'Current weather for a city.',
      parameters: const {
        'type': 'object',
        'properties': {
          'city': {'type': 'string'},
        },
        'required': ['city'],
      },
      handler: (arguments) async => {'city': arguments['city'], 'tempC': 4},
    ),
  ],
);
```

When the model calls a tool, the router runs the handler, sends the result back to the same provider, and streams the final reply. This works with OpenAI, Anthropic, Gemini, and OpenAI-compatible hosts. Failover happens only before the first tool runs, so a tool never runs twice because a provider failed. See [Tools and Structured Output](doc/10-tools-and-structured-output.md).

## Structured Output

```dart
final city = await router.generateObject(
  'What is the capital of Norway?',
  schema: const ResponseSchema(
    name: 'city',
    schema: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  ),
  decode: (json) => (json! as Map)['name'] as String,
);
```

Each reply is parsed and decoded before it is accepted. If a provider returns invalid JSON, or `decode` throws, the router fails over to the next one.

## Provider Presets

Presets set the endpoint, adapter, and capabilities for common hosts:

```dart
final providers = [
  ProviderConfig.groq(
    apiKey: groqKey,
    model: 'llama-3.3-70b-versatile',
    pricePerInputToken: 0.00000059,
    pricePerOutputToken: 0.00000079,
  ),
  // Free local fallback. Local URLs never trigger the offline check.
  ProviderConfig.ollama(model: 'llama3.2'),
];
```

Also available: `ProviderConfig.lmStudio`, `ProviderConfig.mistral`, `ProviderConfig.deepSeek`, and `ProviderConfig.azureOpenAi`. Check prices against each vendor's pricing page.

## Reliability Policies

All policies are off by default.

```dart
final router = RouterLlmProvider(
  providers: providers,
  // Retry 429/5xx/timeouts on the same provider before failing over.
  retryPolicy: const RetryPolicy(maxRetries: 2),
  // Skip a provider for 30s after 3 failed requests in a row.
  circuitBreaker: const CircuitBreakerPolicy(),
  // Try the cheapest provider first.
  routingStrategy: const CheapestFirstRoutingStrategy(),
);
```

Other strategies: `PriorityRoutingStrategy` (default), `LowestLatencyRoutingStrategy`, and `WeightedRoutingStrategy`. `router.providerHealth` shows each provider's circuit state and average time to first token. See [Reliability policies](doc/05-reliability-policies.md).

## Budgets

```dart
final router = RouterLlmProvider(
  providers: providers,
  budget: const BudgetPolicy(
    sessionLimitUsd: 1.00,
    providerLimitsUsd: {'openai': 0.50},
  ),
);
```

A provider over its limit is skipped, so the next (cheaper) one answers. Over the session limit, only free providers such as a local model run. With nothing left in budget, the router throws `BudgetExceededException` before any call. `costTracker.usageByProvider` breaks spend down by provider.

## Events and Observability

```dart
router.events.listen((event) {
  switch (event) {
    case AttemptFinished(:final log) when !log.isSuccess:
      debugPrint('Attempt failed: ${log.providerName} ${log.error}');
    case RequestFinished(:final outcome, :final latency):
      debugPrint('Request $outcome in ${latency.inMilliseconds} ms');
    default:
      break;
  }
});
```

Event errors are redacted by default (`redactEventErrors`), because provider error bodies can echo the prompt. See [Observability](doc/06-observability.md).

## RouterInspector

A debug panel that shows spend, provider health, and the latest attempts live:

```dart
showModalBottomSheet<void>(
  context: context,
  builder: (_) => SingleChildScrollView(child: RouterInspector(router: router)),
);
```

## Response Cache

```dart
final router = RouterLlmProvider(
  providers: providers,
  responseCache: InMemoryResponseCache(ttl: const Duration(minutes: 10)),
);
```

Identical requests (same conversation, attachments, and router settings) are answered from the cache. Only complete, successful replies are stored. Implement `ResponseCache` for persistent storage.

## Protecting API Keys

Any key shipped in a client app can be extracted, including keys passed through `--dart-define` and keys in an obfuscated build. A leaked key lets anyone spend on your account.

Direct keys are fine for local development and for apps where users supply their own keys. For a production app with your own keys, run a backend proxy that holds the keys, checks who is calling, and enforces limits. Point `ProviderConfig.baseUrl` at that proxy. See [Backend proxy](doc/08-backend-proxy.md).

## Documentation

- [Quickstart Guide](doc/01-quickstart.md)
- [Configuration](doc/02-configuration.md)
- [Cost Tracking](doc/03-cost-tracking.md)
- [Attachments and Settings](doc/04-attachments-and-settings.md)
- [Reliability Policies](doc/05-reliability-policies.md)
- [Observability](doc/06-observability.md)
- [Production Checklist](doc/07-production-checklist.md)
- [Backend Proxy](doc/08-backend-proxy.md)
- [Comparison](doc/09-comparison.md)
- [Tools and Structured Output](doc/10-tools-and-structured-output.md)
- [Reliability Benchmark](doc/11-reliability-benchmark.md)
- [Example App](example/README.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security Policy](SECURITY.md)

*Note: `getDocumentEmbedding` and `getQueryEmbedding` are deprecated, throw `UnimplementedError`, and will be removed in 2.0.0. Chat streaming is the supported path.*

## License

MIT. See [LICENSE](LICENSE).

