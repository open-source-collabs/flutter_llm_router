import 'dart:async';
import 'dart:convert';

import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Tool calling and structured output, on the wire and in the router.
void main() {
  const weather = ToolDefinition(
    name: 'get_weather',
    description: 'Current weather for a city.',
    parameters: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'city': <String, Object?>{'type': 'string'},
      },
      'required': <String>['city'],
    },
  );
  const call = ToolCall(
    id: 'call_1',
    name: 'get_weather',
    arguments: <String, Object?>{'city': 'Oslo'},
    providerData: <String, Object?>{'thoughtSignature': 'sig=='},
  );
  const result = ToolResult(
    callId: 'call_1',
    name: 'get_weather',
    content: '{"tempC":4}',
  );
  final conversation = <ChatTurn>[
    const ChatTurn(role: ChatTurnRole.user, text: 'Weather in Oslo?'),
    const ChatTurn(
      role: ChatTurnRole.assistant,
      text: '',
      toolCalls: <ToolCall>[call],
    ),
    const ChatTurn(
      role: ChatTurnRole.user,
      text: '',
      toolResults: <ToolResult>[result],
    ),
  ];
  const withTools = GenerationSettings(tools: <ToolDefinition>[weather]);

  group('OpenAI tools', () {
    test('sends tools and maps calls and results', () async {
      final body = await _capture(
        (client) => OpenAiAdapter(client: client),
        _config(settings: withTools),
        conversation,
      );

      expect(body['tools'], <Object?>[
        <String, Object?>{
          'type': 'function',
          'function': <String, Object?>{
            'name': 'get_weather',
            'description': 'Current weather for a city.',
            'parameters': weather.parameters,
          },
        },
      ]);
      final messages = body['messages'] as List<dynamic>;
      expect(messages[1], <String, Object?>{
        'role': 'assistant',
        'content': null,
        'tool_calls': <Object?>[
          <String, Object?>{
            'id': 'call_1',
            'type': 'function',
            'function': <String, Object?>{
              'name': 'get_weather',
              'arguments': '{"city":"Oslo"}',
            },
          },
        ],
      });
      expect(messages[2], <String, Object?>{
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': '{"tempC":4}',
      });
    });

    test('assembles streamed tool call fragments by index', () async {
      final chunks = await _stream(
        (client) => OpenAiAdapter(client: client),
        _sse(<String>[
          '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a",'
              '"function":{"name":"get_weather","arguments":"{\\"ci"}}]}}]}',
          '{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b",'
              '"function":{"name":"get_weather","arguments":"{}"}}]}}]}',
          '{"choices":[{"delta":{"tool_calls":[{"index":0,'
              '"function":{"arguments":"ty\\":\\"Oslo\\"}"}}]}}]}',
          '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
        ]),
      );

      final calls = chunks.whereType<AdapterToolCall>().toList();
      expect(calls.map((c) => c.call.id), <String>['a', 'b']);
      expect(calls.first.call.arguments, <String, Object?>{'city': 'Oslo'});
      expect(calls.last.call.arguments, isEmpty);
      expect(chunks.last, isA<AdapterFinish>());
      expect((chunks.last as AdapterFinish).reason, FinishReason.toolCall);
    });

    test('malformed arguments fail over', () async {
      await expectLater(
        _stream(
          (client) => OpenAiAdapter(client: client),
          _sse(<String>[
            '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a",'
                '"function":{"name":"x","arguments":"{oops"}}]},'
                '"finish_reason":"tool_calls"}]}',
          ]),
        ),
        throwsA(isA<RetryableLlmException>()),
      );
    });

    test('sends response_format for a schema', () async {
      final body = await _capture(
        (client) => OpenAiAdapter(client: client),
        _config(
          settings: const GenerationSettings(
            responseSchema: ResponseSchema(
              name: 'city',
              schema: <String, Object?>{'type': 'object'},
              strict: true,
            ),
          ),
        ),
        _turns('hi'),
      );
      expect(body['response_format'], <String, Object?>{
        'type': 'json_schema',
        'json_schema': <String, Object?>{
          'name': 'city',
          'schema': <String, Object?>{'type': 'object'},
          'strict': true,
        },
      });
    });
  });

  group('Anthropic tools', () {
    test('sends input_schema and maps tool_use and tool_result', () async {
      final body = await _capture(
        (client) => AnthropicAdapter(client: client),
        _config(settings: withTools),
        conversation,
      );

      expect((body['tools'] as List).single, <String, Object?>{
        'name': 'get_weather',
        'description': 'Current weather for a city.',
        'input_schema': weather.parameters,
      });
      final messages = body['messages'] as List<dynamic>;
      expect((messages[1] as Map)['content'], <Object?>[
        <String, Object?>{
          'type': 'tool_use',
          'id': 'call_1',
          'name': 'get_weather',
          'input': <String, Object?>{'city': 'Oslo'},
        },
      ]);
      expect((messages[2] as Map)['content'], <Object?>[
        <String, Object?>{
          'type': 'tool_result',
          'tool_use_id': 'call_1',
          'content': '{"tempC":4}',
        },
      ]);
    });

    test('assembles a tool_use block from input_json_delta', () async {
      final chunks = await _stream(
        (client) => AnthropicAdapter(client: client),
        _sse(<String>[
          '{"type":"content_block_start","index":1,"content_block":'
              '{"type":"tool_use","id":"toolu_9","name":"get_weather","input":{}}}',
          '{"type":"content_block_delta","index":1,"delta":'
              '{"type":"input_json_delta","partial_json":"{\\"city\\":"}}',
          '{"type":"content_block_delta","index":1,"delta":'
              '{"type":"input_json_delta","partial_json":"\\"Oslo\\"}"}}',
          '{"type":"content_block_stop","index":1}',
          '{"type":"message_delta","delta":{"stop_reason":"tool_use"},'
              '"usage":{"output_tokens":9}}',
        ]),
      );

      final toolCall = chunks.whereType<AdapterToolCall>().single.call;
      expect(toolCall.id, 'toolu_9');
      expect(toolCall.arguments, <String, Object?>{'city': 'Oslo'});
      expect(
        chunks.whereType<AdapterFinish>().single.reason,
        FinishReason.toolCall,
      );
    });
  });

  group('Gemini tools', () {
    test('sends functionDeclarations and echoes thought signatures', () async {
      final body = await _capture(
        (client) => GeminiAdapter(client: client),
        _config(settings: withTools),
        conversation,
      );

      expect(body['tools'], <Object?>[
        <String, Object?>{
          'functionDeclarations': <Object?>[
            <String, Object?>{
              'name': 'get_weather',
              'description': 'Current weather for a city.',
              'parameters': weather.parameters,
            },
          ],
        },
      ]);
      final contents = body['contents'] as List<dynamic>;
      expect((contents[1] as Map)['parts'], <Object?>[
        <String, Object?>{
          'functionCall': <String, Object?>{
            'name': 'get_weather',
            'args': <String, Object?>{'city': 'Oslo'},
          },
          'thoughtSignature': 'sig==',
        },
      ]);
      expect((contents[2] as Map)['parts'], <Object?>[
        <String, Object?>{
          'functionResponse': <String, Object?>{
            'name': 'get_weather',
            'response': <String, Object?>{'tempC': 4},
          },
        },
      ]);
    });

    test('reads a functionCall part and keeps its signature', () async {
      final chunks = await _stream(
        (client) => GeminiAdapter(client: client),
        _sse(<String>[
          '{"candidates":[{"content":{"parts":[{"functionCall":'
              '{"name":"get_weather","args":{"city":"Oslo"}},'
              '"thoughtSignature":"abc"}]},"finishReason":"STOP"}]}',
        ]),
      );

      final toolCall = chunks.whereType<AdapterToolCall>().single.call;
      expect(toolCall.name, 'get_weather');
      expect(toolCall.arguments, <String, Object?>{'city': 'Oslo'});
      expect(toolCall.providerData['thoughtSignature'], 'abc');
      expect(toolCall.id, startsWith('gemini_call_'));
    });

    test('a schema switches Gemini to JSON mode', () async {
      final body = await _capture(
        (client) => GeminiAdapter(client: client),
        _config(
          settings: const GenerationSettings(
            responseSchema: ResponseSchema(
              name: 'x',
              schema: <String, Object?>{'type': 'object'},
            ),
          ),
        ),
        _turns('hi'),
      );
      expect(
        (body['generationConfig'] as Map)['responseMimeType'],
        'application/json',
      );
    });
  });

  group('router tool loop', () {
    test('runs the tool and streams the final reply', () async {
      final seenArguments = <Map<String, Object?>>[];
      final rounds = <List<ChatTurn>>[];
      final router = _router(
        providers: [_config(name: 'alpha')],
        tools: [
          RouterTool(
            name: 'get_weather',
            description: weather.description,
            parameters: weather.parameters,
            handler: (arguments) {
              seenArguments.add(arguments);
              return <String, Object?>{'tempC': 4};
            },
          ),
        ],
        adapters: {
          'alpha': (config, messages) {
            rounds.add(messages);
            expect(config.settings.tools?.single.name, 'get_weather');
            if (messages.length == 1) {
              return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
                AdapterText('Checking. '),
                AdapterToolCall(call),
                AdapterFinish(FinishReason.toolCall),
              ]);
            }
            return Stream<AdapterChunk>.value(const AdapterText('It is 4C.'));
          },
        },
      );
      final tools = router.events.only<ToolCallFinished>().first;

      expect(
        await router.generateStream('Weather in Oslo?').join(),
        'Checking. It is 4C.',
      );
      expect(seenArguments.single, <String, Object?>{'city': 'Oslo'});
      final followUp = rounds.last;
      expect(followUp[1].toolCalls.single.id, 'call_1');
      expect(followUp[1].text, 'Checking. ');
      expect(followUp[2].toolResults.single.content, '{"tempC":4}');
      expect(followUp[2].toolResults.single.isError, isFalse);
      expect(router.lastAttemptLogs.length, 2);
      expect(router.lastAttemptLogs.first.finishReason, FinishReason.toolCall);
      final event = await tools;
      expect(event.toolName, 'get_weather');
      expect(event.isError, isFalse);
    });

    test('a throwing handler and an unknown tool send error results', () async {
      List<ToolResult>? results;
      final router = _router(
        providers: [_config(name: 'alpha')],
        tools: [
          RouterTool(
            name: 'get_weather',
            description: 'x',
            handler: (arguments) => throw const FormatException('no city'),
          ),
        ],
        adapters: {
          'alpha': (config, messages) {
            if (messages.length == 1) {
              return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
                AdapterToolCall(call),
                AdapterToolCall(
                  ToolCall(id: 'call_2', name: 'missing', arguments: {}),
                ),
              ]);
            }
            results = messages.last.toolResults;
            return Stream<AdapterChunk>.value(const AdapterText('sorry'));
          },
        },
      );

      expect(await router.generateStream('hi').join(), 'sorry');
      expect(results!.map((r) => r.isError), <bool>[true, true]);
      expect(results!.first.content, contains('no city'));
      expect(results!.last.content, contains('Unknown tool'));
    });

    test('stops after maxToolRounds', () async {
      final router = _router(
        providers: [_config(name: 'alpha')],
        maxToolRounds: 2,
        tools: [
          RouterTool(name: 'get_weather', description: 'x', handler: (_) => 1),
        ],
        adapters: {
          'alpha': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterToolCall(call)),
        },
      );

      await expectLater(
        router.generateStream('hi').join(),
        throwsA(
          isA<TerminalLlmException>().having(
            (error) => error.message,
            'message',
            contains('2 tool rounds'),
          ),
        ),
      );
    });

    test('no failover once a tool has run', () async {
      var toolRuns = 0;
      var betaCalls = 0;
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        tools: [
          RouterTool(
            name: 'get_weather',
            description: 'x',
            handler: (_) => ++toolRuns,
          ),
        ],
        adapters: {
          'alpha': (config, messages) => messages.length == 1
              ? Stream<AdapterChunk>.value(const AdapterToolCall(call))
              : Stream<AdapterChunk>.error(
                  const RetryableLlmException('HTTP 503', statusCode: 503),
                ),
          'beta': (config, messages) {
            betaCalls++;
            return Stream<AdapterChunk>.value(const AdapterText('beta'));
          },
        },
      );

      await expectLater(
        router.generateStream('hi').join(),
        throwsA(isA<RetryableLlmException>()),
      );
      expect(toolRuns, 1);
      expect(betaCalls, 0);
    });

    test('the same provider is still retried after a tool ran', () async {
      var toolRuns = 0;
      var followUps = 0;
      final client = MockClient((request) async => http.Response('', 200));
      final router = RouterLlmProvider(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        retryPolicy: const RetryPolicy(
          maxRetries: 1,
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
          jitter: 0,
        ),
        tools: [
          RouterTool(
            name: 'get_weather',
            description: 'x',
            handler: (_) => ++toolRuns,
          ),
        ],
        customAdapters: <String, BaseLlmAdapter>{
          'alpha': _ScriptedAdapter(client, (config, messages) {
            if (messages.length == 1) {
              return Stream<AdapterChunk>.value(const AdapterToolCall(call));
            }
            return ++followUps == 1
                ? Stream<AdapterChunk>.error(
                    const RetryableLlmException('HTTP 503', statusCode: 503),
                  )
                : Stream<AdapterChunk>.value(const AdapterText('4C'));
          }),
        },
        connectivityChecker: const AssumeOnlineConnectivityChecker(),
      );
      addTearDown(() {
        router.dispose();
        client.close();
      });

      expect(await router.generateStream('hi').join(), '4C');
      expect(toolRuns, 1);
      expect(router.lastAttemptLogs.map((log) => log.retry), <int>[0, 0, 1]);
    });

    test('failover before any tool runs still works', () async {
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        tools: [
          RouterTool(name: 'get_weather', description: 'x', handler: (_) => 4),
        ],
        adapters: {
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const RetryableLlmException('HTTP 503', statusCode: 503),
          ),
          'beta': (config, messages) => messages.length == 1
              ? Stream<AdapterChunk>.value(const AdapterToolCall(call))
              : Stream<AdapterChunk>.value(const AdapterText('done')),
        },
      );

      expect(await router.generateStream('hi').join(), 'done');
    });

    test('providers without tool support are skipped', () async {
      final router = _router(
        providers: [
          _config(name: 'alpha').copyWith(
            capabilities: const ProviderCapabilities(
              <AttachmentKind>{},
              tools: false,
            ),
          ),
          _config(name: 'beta'),
        ],
        tools: [
          RouterTool(name: 'get_weather', description: 'x', handler: (_) => 4),
        ],
        adapters: {
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('beta')),
        },
      );

      expect(await router.generateStream('hi').join(), 'beta');
      expect(router.lastAttemptLogs.first.skipReason, contains('tool'));
    });

    test('duplicate tool names are rejected', () {
      expect(
        () => RouterLlmProvider(
          providers: [_config()],
          tools: [
            RouterTool(name: 'a', description: 'x', handler: (_) => 1),
            RouterTool(name: 'a', description: 'y', handler: (_) => 2),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('generateObject', () {
    const schema = ResponseSchema(
      name: 'city',
      schema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'name': <String, Object?>{'type': 'string'},
        },
        'required': <String>['name'],
      },
    );
    String decodeCity(Object? json) => (json! as Map)['name'] as String;

    test('decodes a valid reply and tells the provider the schema', () async {
      GenerationSettings? seen;
      final router = _router(
        providers: [_config(name: 'alpha')],
        settings: const GenerationSettings(systemPrompt: 'Be exact.'),
        adapters: {
          'alpha': (config, messages) {
            seen = config.settings;
            return Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
              AdapterText('{"name":'),
              AdapterText('"Oslo"}'),
            ]);
          },
        },
      );

      final city = await router.generateObject(
        'Capital of Norway?',
        schema: schema,
        decode: decodeCity,
      );

      expect(city, 'Oslo');
      expect(seen?.responseSchema?.name, 'city');
      expect(seen?.systemPrompt, startsWith('Be exact.'));
      expect(seen?.systemPrompt, contains('"required":["name"]'));
    });

    test('invalid JSON and a failed decode both fail over', () async {
      final router = _router(
        providers: [
          _config(name: 'alpha'),
          _config(name: 'beta'),
          _config(name: 'gamma'),
        ],
        adapters: {
          'alpha': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('Sure! Oslo.')),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('{"city":1}')),
          'gamma': (config, messages) => Stream<AdapterChunk>.value(
            const AdapterText('```json\n{"name":"Oslo"}\n```'),
          ),
        },
      );

      final city = await router.generateObject(
        'Capital of Norway?',
        schema: schema,
        decode: decodeCity,
      );

      expect(city, 'Oslo');
      final logs = router.lastAttemptLogs;
      expect(logs[0].error, contains('not valid JSON'));
      expect(logs[1].error, contains('expected shape'));
      expect(logs[2].isSuccess, isTrue);
    });

    test('when every reply is invalid, all providers failed', () async {
      final router = _router(
        providers: [_config(name: 'alpha')],
        adapters: {
          'alpha': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('nope')),
        },
      );

      await expectLater(
        router.generateObject('x', schema: schema, decode: decodeCity),
        throwsA(isA<AllProvidersFailedException>()),
      );
    });

    test('a cached object reply is keyed by schema', () async {
      var calls = 0;
      final router = _router(
        providers: [_config(name: 'alpha')],
        cache: InMemoryResponseCache(),
        adapters: {
          'alpha': (config, messages) {
            calls++;
            return Stream<AdapterChunk>.value(
              const AdapterText('{"name":"Oslo"}'),
            );
          },
        },
      );

      await router.generateObject('q', schema: schema, decode: decodeCity);
      final again = await router.generateObject(
        'q',
        schema: schema,
        decode: decodeCity,
      );
      await router.generateStream('q').drain<void>();

      expect(again, 'Oslo');
      expect(calls, 2);
      expect(router.lastAttemptLogs.single.fromCache, isFalse);
    });
  });
}

typedef _Handler =
    Stream<AdapterChunk> Function(
      ProviderConfig config,
      List<ChatTurn> messages,
    );

ProviderConfig _config({
  String name = 'openai',
  GenerationSettings settings = const GenerationSettings(),
}) {
  return ProviderConfig(
    name: name,
    apiKey: 'test-key',
    model: '$name-model',
    pricePerInputToken: 0,
    pricePerOutputToken: 0,
    settings: settings,
  );
}

List<ChatTurn> _turns(String text) => <ChatTurn>[
  ChatTurn(role: ChatTurnRole.user, text: text),
];

String _sse(List<String> payloads) =>
    payloads.map((payload) => 'data: $payload\n\n').join();

Future<Map<String, dynamic>> _capture(
  BaseLlmAdapter Function(http.Client client) build,
  ProviderConfig config,
  List<ChatTurn> messages,
) async {
  late Map<String, dynamic> captured;
  final client = MockClient.streaming((request, bodyStream) async {
    captured =
        jsonDecode(await utf8.decodeStream(bodyStream)) as Map<String, dynamic>;
    return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
  });
  addTearDown(client.close);
  await build(
    client,
  ).streamCompletion(config: config, messages: messages).drain<void>();
  return captured;
}

Future<List<AdapterChunk>> _stream(
  BaseLlmAdapter Function(http.Client client) build,
  String sse,
) {
  final client = MockClient.streaming(
    (request, body) async =>
        http.StreamedResponse(Stream<List<int>>.value(utf8.encode(sse)), 200),
  );
  addTearDown(client.close);
  return build(
    client,
  ).streamCompletion(config: _config(), messages: _turns('hi')).toList();
}

RouterLlmProvider _router({
  required List<ProviderConfig> providers,
  Map<String, _Handler> adapters = const <String, _Handler>{},
  List<RouterTool> tools = const <RouterTool>[],
  int maxToolRounds = 8,
  GenerationSettings settings = const GenerationSettings(),
  ResponseCache? cache,
}) {
  final client = MockClient((request) async => http.Response('', 200));
  final router = RouterLlmProvider(
    providers: providers,
    tools: tools,
    maxToolRounds: maxToolRounds,
    settings: settings,
    responseCache: cache,
    customAdapters: <String, BaseLlmAdapter>{
      for (final entry in adapters.entries)
        entry.key: _ScriptedAdapter(client, entry.value),
    },
    connectivityChecker: const AssumeOnlineConnectivityChecker(),
  );
  addTearDown(() {
    router.dispose();
    client.close();
  });
  return router;
}

class _ScriptedAdapter extends BaseLlmAdapter {
  _ScriptedAdapter(http.Client client, this._handler) : super(client: client);

  final _Handler _handler;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    return _handler(config, messages);
  }
}

extension on Stream<RouterEvent> {
  Stream<T> only<T extends RouterEvent>() =>
      where((event) => event is T).cast<T>();
}
