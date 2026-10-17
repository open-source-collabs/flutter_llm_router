# flutter_llm_router

[![pub package](https://img.shields.io/pub/v/flutter_llm_router.svg)](https://pub.dev/packages/flutter_llm_router)
[![pub points](https://img.shields.io/pub/points/flutter_llm_router)](https://pub.dev/packages/flutter_llm_router/score)
[![pub likes](https://img.shields.io/pub/likes/flutter_llm_router)](https://pub.dev/packages/flutter_llm_router)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Dart](https://img.shields.io/badge/Dart-%5E3.7.0-0175C2?logo=dart&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.27.0-02569B?logo=flutter&logoColor=white)
[![Platforms](https://img.shields.io/badge/platforms-windows%20%7C%20android%20%7C%20ios%20%7C%20web%20%7C%20macos%20%7C%20linux-blue.svg)](pubspec.yaml)

A resilient multi-provider LLM router for Flutter AI Toolkit. `RouterLlmProvider` implements `LlmProvider`, so it seamlessly drops into `LlmChatView` and adds automatic failover, real-time token cost tracking, and attempt logging across Windows, macOS, Linux, Android, iOS, and Web.

## Features

- **Transparent Failover**: Tries configured LLM providers in priority order. Automatically recovers from rate limits (HTTP 429), timeouts, and 5xx errors.
- **Connectivity-Aware Failover**: On a connection error, silently probes the internet. If the device is offline, it stops with a clear `NoInternetConnectionException` instead of cycling through every provider.
- **Drop-in UI Integration**: Compatible with Flutter AI Toolkit's `LlmChatView`.
- **Multi-Provider Support**: Built-in adapters for OpenAI, Google Gemini, Anthropic Claude, and OpenRouter, plus custom adapters.
- **Live Token & Cost Tracking**: Configurable USD token pricing with real-time `ValueNotifier` updates.
- **Observability**: Detailed attempt logging (`lastAttemptLogs`) for debugging and monitoring which provider responded or failed.

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
  flutter_llm_router: ^1.1.0
```

## Problem

A single upstream outage, HTTP 429 rate limit, or network timeout breaks the chat experience. In addition, token spend remains hidden until the vendor invoice arrives, and there is no record of which provider responded or failed.

## Solution

Point `LlmChatView` at one `RouterLlmProvider`. The router tries each `ProviderConfig` in order:

- HTTP 429, 408, 5xx, timeouts, and dropped sockets raise `RetryableLlmException` and move to the next provider (as long as no text has been yielded yet).
- On a connection error or timeout, the router silently checks whether the device is online (once per request). If it is offline, the router throws `NoInternetConnectionException`. If it is online, only that provider is unreachable, so the router moves to the next one.
- HTTP 400, 401, and 403 raise `TerminalLlmException` and stop the chain immediately.
- If every provider fails, the router throws `AllProvidersFailedException` containing the complete attempt history.
- Completed streams update `CostTracker` and `lastAttemptLogs`.

### Supported Providers

| Name | Adapter | Default Base URL | Model Example |
| :--- | :--- | :--- | :--- |
| `openai` | `OpenAiAdapter` | `https://api.openai.com/v1` | `gpt-4o-mini` |
| `gemini` | `GeminiAdapter` | `https://generativelanguage.googleapis.com/v1beta` | `gemini-2.0-flash` |
| `anthropic` | `AnthropicAdapter` | `https://api.anthropic.com/v1` | `claude-3-5-haiku-latest` |
| `openrouter` | `OpenRouterAdapter` | `https://openrouter.ai/api/v1` | `openai/gpt-4o-mini`, `anthropic/claude-3.5-haiku` |

You can repeat `openrouter` across multiple entries with different `model` slugs to fail over between upstream models using a single OpenRouter API key.

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

The runnable demonstration is in [example/](example/), supporting Windows desktop (`flutter run -d windows`), Web, Android, and iOS. It adds simulated outage toggles, API key management, the live spend label, and an attempt history inspection sheet.

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

Read `router.costTracker.totalInputTokens` and `router.costTracker.totalOutputTokens` to inspect token counts.

## Attempt History & Logging

Inspect `router.lastAttemptLogs` to see how each provider attempt performed during the last turn:

```dart
for (final log in router.lastAttemptLogs) {
  print('${log.providerName} (${log.model}): status=${log.status}, error=${log.errorMessage}');
}
```

## Documentation

- [Quickstart Guide](doc/01-quickstart.md)
- [Configuration](doc/02-configuration.md)
- [Cost Tracking](doc/03-cost-tracking.md)
- [Example App](example/README.md)
- [Changelog](CHANGELOG.md)

*Note: `getDocumentEmbedding` and `getQueryEmbedding` throw `UnimplementedError`. Chat streaming is the supported path.*

## License

MIT. See [LICENSE](LICENSE).

