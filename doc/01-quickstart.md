# Quickstart

This package is not on pub.dev. Depend on it with a path until you have tested it against real providers.

## 1. Add the dependencies

From an app next to the `flutter_llm_router` checkout:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_ai_toolkit: ^1.0.0
  flutter_llm_router:
    path: ../flutter_llm_router
```

Then run:

```sh
flutter pub get
```

Requires Dart `^3.7.0` and Flutter `>=3.27.0`. Fully supported on Windows, macOS, Linux, Android, iOS, and Web.

## 2. Create the router

`name` selects the adapter: `openai`, `anthropic`, `gemini`, or `openrouter`. List the provider you want tried first at the front of `providers`.

```dart
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
```

Prices are USD per token. See [Configuration](02-configuration.md) and [Cost tracking](03-cost-tracking.md).

## 3. Hand it to the chat view

```dart
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';

LlmChatView(provider: router)
```

`sendMessageStream` appends the user message and the assistant reply to `router.history`. `generateStream` does not.

## 4. Dispose what you created

If you pass `costTracker` in, you own it. The router disposes a tracker it created itself, and it closes adapters it constructed. Injected `customAdapters` stay open.

```dart
@override
void dispose() {
  router.dispose();
  costTracker.dispose();
  super.dispose();
}
```

## 5. Run the example before you trust it

```sh
cd example
flutter run -d windows  # or -d chrome, or connected device
```

The example sends one OpenRouter key to `https://openrouter.ai/api/v1` and walks `openai/gpt-4o-mini`, then `google/gemini-2.5-flash`, then `anthropic/claude-haiku-4.5`. Enter that key from the key icon. Send a prompt with the 429 switch off, then with it on, then with both outage switches on. The spend label and the attempt sheet are the checks. Direct vendor keys, as in the snippet above, are the production setup.
