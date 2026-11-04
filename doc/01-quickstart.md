# Quickstart

Get started with `flutter_llm_router` in your Flutter application.

## 1. Add the dependencies

Add `flutter_llm_router` and `flutter_ai_toolkit` to your Flutter app:

```sh
flutter pub add flutter_llm_router flutter_ai_toolkit
```

Or add them directly to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_ai_toolkit: ^1.0.0
  flutter_llm_router: ^1.2.0
```

Requires Dart `^3.8.0` and Flutter `>=3.32.0`. Fully supported on Windows, macOS, Linux, Android, iOS, and Web.

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

The example uses direct OpenAI, Gemini, and Anthropic keys and walks `gpt-4o-mini`, then `gemini-2.0-flash`, then `claude-3-5-haiku-20241022`. Enter the keys from the key icon. Send a prompt with the switches off, then turn on **Simulate OpenAI outage (HTTP 429)**, then also turn on **Also simulate Gemini outage**. The spend label and the attempt sheet are the checks.

Keys in a client app can be extracted. For a production app using your own keys, route requests through a backend proxy by setting `baseUrl`. See [Protecting API Keys](../README.md#protecting-api-keys).
