# Attachments and settings

## Attachments

`LlmChatView` lets users attach images, files, and links. The router converts each toolkit `Attachment` into a `TurnAttachment` on `ChatTurn.attachments`, and each adapter sends it in its vendor's format.

| Kind (`AttachmentKind`) | OpenAI-compatible | Anthropic | Gemini |
| --- | --- | --- | --- |
| `image` file | `image_url` part with a `data:` URL | `image` block, base64 source | `inlineData` |
| `image` link | `image_url` part with the URL | `image` block, URL source | Text reference |
| `pdf` | `file` part with a `data:` URL | `document` block, base64 source | `inlineData` |
| `text` (text/*, JSON, XML, YAML, and non-image links) | Text part | Text block | Text part |
| `audio`, `video` | Not supported | Not supported | `inlineData` |
| `other` | Not supported | Not supported | Not supported |

Text files are decoded as UTF-8 and inlined with their file name, so every provider can read them. Links that are not images are sent as `Attached link "name": url`; the model sees the URL, not the page.

`AttachmentKind.fromMimeType` decides the kind from the MIME type.

## Capabilities

`ProviderCapabilities` lists the attachment kinds a provider accepts. Text is always accepted. Before calling a provider, the router checks every attachment in the conversation, including earlier turns in `history`. If one kind isn't supported, the provider is skipped and logged:

```dart
for (final log in router.lastAttemptLogs) {
  if (log.isSkipped) print('${log.providerName}: ${log.skipReason}');
}
// openai: Does not accept image attachments
```

If no provider can take the attachments, the router throws `AllProvidersFailedException` with the message `No provider accepts these attachments`.

Capabilities come from `ProviderConfig.capabilities` when set, otherwise from the adapter:

| Adapter | Default capabilities |
| --- | --- |
| `OpenAiAdapter`, `OpenRouterAdapter` | image, pdf |
| `AzureOpenAiAdapter` | `ProviderCapabilities.vision` (image) |
| `AnthropicAdapter` | image, pdf |
| `GeminiAdapter` | image, pdf, audio, video |
| Custom `BaseLlmAdapter` | `ProviderCapabilities.all` (never skipped) |

The vendor default doesn't fit every model. Set capabilities for models without vision:

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

Use `ProviderCapabilities.vision` for text and images, or `ProviderCapabilities({AttachmentKind.image, AttachmentKind.pdf})` for an explicit set.

As a safety net, an HTTP 400 on a request that has image, PDF, audio, or video attachments fails over instead of stopping the chain. The model may not accept that media even when its capabilities say it does. Without such attachments, HTTP 400 still stops the chain.

### Custom adapters

`ChatTurn.toOpenAiMessage`, `toAnthropicMessage`, and `toGeminiContent` build each vendor's message, attachments included. They throw `ProviderUnavailableLlmException` for an attachment the vendor can't take, so the router fails over. Override `BaseLlmAdapter.capabilities` to let the router skip your adapter up front instead.

## Generation settings

`GenerationSettings` holds the system prompt and sampling settings. Null fields are left out of the request, so the provider default applies.

| Field | OpenAI-compatible | Anthropic | Gemini |
| --- | --- | --- | --- |
| `systemPrompt` | Leading `system` message | `system` | `systemInstruction` |
| `temperature` | `temperature` | `temperature` | `generationConfig.temperature` |
| `topP` | `top_p` | `top_p` | `generationConfig.topP` |
| `stopSequences` | `stop` | `stop_sequences` | `generationConfig.stopSequences` |

Set defaults on the router and override per provider:

```dart
final router = RouterLlmProvider(
  settings: const GenerationSettings(
    systemPrompt: 'Answer in two sentences.',
    temperature: 0.3,
  ),
  providers: [
    ProviderConfig(
      name: 'anthropic',
      apiKey: anthropicKey,
      model: 'claude-3-5-haiku-latest',
      pricePerInputToken: 0.0000008,
      pricePerOutputToken: 0.000004,
      // Uses the router's system prompt with a different temperature.
      settings: const GenerationSettings(temperature: 0.7),
    ),
  ],
);

// Takes effect on the next request.
router.settings = const GenerationSettings(systemPrompt: 'Answer in French.');
```

Some models reject some settings. OpenAI reasoning models reject `temperature`, newer Anthropic models reject `temperature` and `topP` together, and OpenAI accepts at most four stop sequences. A rejected setting returns HTTP 400, which stops the chain, so set such values per provider.

## Finish reasons

Adapters report why the provider stopped as an `AdapterFinish`. The router stores it on `AttemptLog.finishReason`:

| `FinishReason` | Meaning |
| --- | --- |
| `stop` | The model finished or hit a stop sequence |
| `length` | Cut off at `maxOutputTokens` |
| `contentFilter` | A safety filter stopped or blocked the reply |
| `toolCall` | The model asked to call a tool |
| `other` | Any other vendor reason |

A truncated reply is still a success. Check for `FinishReason.length` and raise `maxOutputTokens` if it happens often. A content-filtered reply with no text fails over to the next provider, and it does not count against that provider's circuit breaker.

## Presets

Presets fill in the endpoint, adapter, and capabilities of common hosts:

| Preset | Endpoint | Notes |
| --- | --- | --- |
| `ProviderConfig.ollama(model: ...)` | `http://localhost:11434/v1` | Free, text-only by default, 2-minute `timeout` for model loading |
| `ProviderConfig.lmStudio(model: ...)` | `http://localhost:1234/v1` | Same as Ollama |
| `ProviderConfig.groq(...)` | `https://api.groq.com/openai/v1` | Vision by default |
| `ProviderConfig.mistral(...)` | `https://api.mistral.ai/v1` | `requestStreamUsage: false`, vision by default |
| `ProviderConfig.deepSeek(...)` | `https://api.deepseek.com/v1` | Text only, optional cached-token price |
| `ProviderConfig.azureOpenAi(...)` | `{endpoint}/openai/deployments/{deployment}?api-version=...` | `api-key` header, deployment shown as `model` |

On an Android emulator, reach the host's Ollama at `http://10.0.2.2:11434/v1`:

```dart
ProviderConfig.ollama(
  model: 'llava',
  baseUrl: 'http://10.0.2.2:11434/v1',
  capabilities: ProviderCapabilities.vision,
)
```

Change anything else with `copyWith`, for example `ProviderConfig.groq(...).copyWith(maxOutputTokens: 4096)`.
