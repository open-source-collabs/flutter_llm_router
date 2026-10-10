# flutter_llm_router

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Dart](https://img.shields.io/badge/Dart-%5E3.7.0-0175C2?logo=dart&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.27.0-02569B?logo=flutter&logoColor=white)
[![Platforms](https://img.shields.io/badge/platforms-windows%20%7C%20android%20%7C%20ios%20%7C%20web%20%7C%20macos%20%7C%20linux-blue.svg)](pubspec.yaml)

A resilient multi-provider LLM router for Flutter AI Toolkit. `RouterLlmProvider` implements `LlmProvider`, so it drops into `LlmChatView` and adds failover, live cost tracking, and attempt logs across Windows, macOS, Linux, Android, iOS, and Web.

This package is **not published**. Use the path dependency and the example app below to test it against real providers before any upload.

## Problem

A single upstream outage, HTTP 429, or timeout ends the chat. Token spend is invisible until the provider invoice arrives, and there is no record of which provider answered or failed.

## Solution

Point `LlmChatView` at one `RouterLlmProvider`. The router tries each `ProviderConfig` in order:

- HTTP 429, 408, 5xx, timeouts, and dropped sockets raise `RetryableLlmException` and move to the next provider, as long as no text has been yielded yet.
- HTTP 400, 401, and 403 raise `TerminalLlmException` and stop the chain.
- If every provider fails, the router throws `AllProvidersFailedException` with the attempt list.
- A finished stream updates `CostTracker` and `lastAttemptLogs`.

Built-in adapter names are `openai`, `anthropic`, `gemini`, and `openrouter`. `openrouter` calls `https://openrouter.ai/api/v1` with one key. Repeat that name and change `model` to fail over across OpenRouter slugs.

## Quickstart

From an app that sits next to this repo:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_ai_toolkit: ^1.0.0
  flutter_llm_router:
    path: ../flutter_llm_router
```

```dart
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';

final costTracker = CostTracker();

final router = RouterLlmProvider(
  costTracker: costTracker,
  providers: [
    ProviderConfig(
      name: 'openai',
      apiKey: openAiKey,
      model: 'gpt-4o-mini',
      pricePerInputToken: 0.00000015,
      pricePerOutputToken: 0.0000006,
    ),
    ProviderConfig(
      name: 'gemini',
      apiKey: geminiKey,
      model: 'gemini-2.0-flash',
      pricePerInputToken: 0.0000001,
      pricePerOutputToken: 0.0000004,
    ),
  ],
);

// Pass `router` to LlmChatView. Dispose `router` and `costTracker` yourself
// when the page is disposed, because the tracker was injected.
```

```dart
LlmChatView(
  provider: router,
  welcomeMessage: 'Ask a question. A 429 on OpenAI fails over to Gemini.',
)
```

The runnable harness is `example/`, supporting Windows desktop (`flutter run -d windows`), Web, Android, and iOS. It adds a 429 switch, key entry, the spend label, and the attempt sheet.

## Live cost tracking

Prices on `ProviderConfig` are USD per token. `0.000001` is one micro-dollar. After a successful stream the router uses the provider's reported token counts when the stream includes them, and estimates a missing side as `(text.length + 3) ~/ 4`, then calls `recordUsage`.

```dart
ValueListenableBuilder<double>(
  valueListenable: router.costTracker.totalCostNotifier,
  builder: (context, totalCost, _) {
    return Text('\$${totalCost.toStringAsFixed(8)}');
  },
)
```

That figure is the router's estimate, not the provider's invoice. Bind the notifier for a live label, and read `totalInputTokens` and `totalOutputTokens` for the counts.

## Documentation

- [Quickstart](doc/01-quickstart.md)
- [Configuration](doc/02-configuration.md)
- [Cost tracking](doc/03-cost-tracking.md)
- [Example app](example/README.md)
- [Changelog](CHANGELOG.md)

`getDocumentEmbedding` and `getQueryEmbedding` throw `UnimplementedError`. Chat streaming is the supported path.

## License

MIT. See [LICENSE](LICENSE).
