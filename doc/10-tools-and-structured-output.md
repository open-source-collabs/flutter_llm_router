# Tools and structured output

Tool calling lets the model call Dart functions you provide. Structured output returns a reply decoded against a JSON Schema. Both work across OpenAI, Anthropic, Gemini, and OpenAI-compatible hosts, and both keep failover.

## Tool calling

### Define tools

A `RouterTool` is a `ToolDefinition` (name, description, JSON Schema for the arguments) plus a `ToolHandler`.

```dart
final router = RouterLlmProvider(
  providers: providers,
  tools: [
    RouterTool(
      name: 'get_weather',
      description: 'Current weather for a city. Call it when asked about weather.',
      parameters: const {
        'type': 'object',
        'properties': {
          'city': {'type': 'string', 'description': 'City name'},
        },
        'required': ['city'],
      },
      handler: (arguments) async {
        final city = arguments['city'] as String;
        return {'city': city, 'tempC': 4};
      },
    ),
  ],
);
```

Tool names must be unique. A duplicate throws `ArgumentError` from the constructor.

The handler gets the decoded arguments object. Its return value goes back to the model: a `String` as is, anything else encoded as JSON.

### How a request runs

1. The router sends the conversation and the tool definitions to the first provider.
2. If the reply contains tool calls, the router logs that attempt as a success, runs the handlers, and appends two turns to the conversation: an assistant turn with `ChatTurn.toolCalls`, and a user turn with `ChatTurn.toolResults`.
3. It calls the same provider again with the longer conversation. This repeats until the model replies without a tool call.
4. Any text the model streams along the way, such as "Let me check", reaches your stream as usual.

Each round is its own entry in `lastAttemptLogs`, and its own usage record in `CostTracker`.

### Rules

- **Round limit.** `maxToolRounds` (default 8) caps the rounds in one request. Going past it throws `TerminalLlmException`.
- **Concurrency.** All tool calls in one round run at the same time. Results are sent back in call order.
- **Handler errors.** A handler that throws an `Exception` produces an error result (`ToolResult.isError`), with the message as content. The model sees it and can recover. An `Error` thrown by a handler is a bug. It is not caught and fails the request.
- **Unknown tools.** A call to a tool name you didn't register produces an error result.
- **Values that aren't JSON.** A return value that `jsonEncode` rejects produces an error result.
- **No failover after a tool runs.** Once any tool has run in a request, a later provider failure is rethrown instead of failing over, because another provider would start over and run the tools again. `RetryPolicy` still retries the same provider, which is safe: the tool results are already in the conversation, so nothing runs twice. Before the first tool call, failover and retries work as usual.
- **Capabilities.** When `tools` is set, providers whose `ProviderCapabilities.tools` is false are skipped and the reason is logged. Every built-in adapter and preset defaults to `tools: true`. Set it to false for a local model without tool support:

```dart
ProviderConfig.ollama(
  model: 'gemma2',
  capabilities: const ProviderCapabilities({}, tools: false),
)
```

- **Events.** Each finished tool emits `ToolCallFinished` on `router.events`, with the tool name, call id, duration, and `isError`.
- **History.** With `sendMessageStream`, only the final text is kept in `history`. The intermediate tool turns are not, because the toolkit's `ChatMessage` can't hold them.

### Vendor details

| Vendor | Request | Calls in the stream | Results |
| --- | --- | --- | --- |
| OpenAI and compatible | `tools` with `type: function` | `delta.tool_calls` fragments, assembled by index | One `role: tool` message per result |
| Anthropic | `tools` with `input_schema` | `tool_use` blocks, input from `input_json_delta` | `tool_result` blocks in a user message |
| Gemini | `tools[].functionDeclarations` | Whole `functionCall` parts | `functionResponse` parts |

Gemini notes:

- Gemini attaches a `thoughtSignature` to function call parts and expects it back on the next request. The adapter keeps it in `ToolCall.providerData` and sends it back with the call.
- When Gemini gives no call id, the adapter generates one.
- Gemini's `functionResponse.response` must be an object. A result that is a JSON object is sent as is. Anything else is wrapped as `{"result": ...}`, and an error result as `{"error": ...}`.
- Gemini accepts only an OpenAPI-style subset of JSON Schema for parameters. If Gemini is in the chain, keep schemas to `type`, `properties`, `required`, `items`, `enum`, and `description`.

### Custom adapters

A custom adapter reads the definitions from `config.settings.tools`, yields `AdapterToolCall` once per complete call, and maps `ChatTurn.toolCalls` and `ChatTurn.toolResults` when building its request. `BaseLlmAdapter.decodeToolArguments` turns streamed JSON into an arguments map, and throws a retryable error for malformed input. An adapter that ignores tools still works: the model never sees them, so it never calls them.

## Structured output

```dart
class City {
  City(this.name, this.country);
  final String name;
  final String country;
}

final city = await router.generateObject(
  'What is the capital of Norway?',
  schema: const ResponseSchema(
    name: 'city',
    description: 'A city and its country',
    schema: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'country': {'type': 'string'},
      },
      'required': ['name', 'country'],
    },
  ),
  decode: (json) {
    final map = json! as Map<String, Object?>;
    return City(map['name']! as String, map['country']! as String);
  },
);
```

### How it works

- **Every provider** gets the schema in its system prompt, after your own system prompt, with an instruction to reply with JSON only.
- **OpenAI and compatible hosts** also get `response_format` of type `json_schema`. `ResponseSchema.strict` turns on OpenAI's strict mode, which needs `additionalProperties: false` and every property listed in `required`.
- **Gemini** also switches to JSON mode with `responseMimeType: application/json`. The schema itself is sent only in the system prompt. Google's current API reference marks `responseSchema` and `_responseJsonSchema` as deprecated in favour of a newer `responseFormat` object, so the adapter uses only the JSON-mode switch until that settles.
- **Anthropic** relies on the system prompt instruction.

### Validation and failover

The router buffers each reply. Nothing reaches the caller until it passes:

1. Surrounding whitespace and a Markdown code fence (```` ```json ... ``` ````) are stripped.
2. The text is parsed with `jsonDecode`.
3. The result is passed to your `decode` function.

If parsing fails, or `decode` throws anything (a `TypeError` from a bad cast counts), the attempt fails with `InvalidStructuredOutputException` and the router fails over. The attempt log shows why. When every provider fails, you get `AllProvidersFailedException`.

`decode` is your schema check, so make it strict. The router doesn't validate against the JSON Schema itself.

### Other rules

- `generateObject` doesn't use or change `history`.
- `tools` may run before the final reply.
- With a response cache, the key includes the schema and the tools. A cached `generateStream` reply never answers `generateObject`, and the reverse.
