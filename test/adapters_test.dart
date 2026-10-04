import 'dart:async';
import 'dart:convert';

import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// SSE parsing and HTTP error mapping for the streaming adapters.
void main() {
  group('OpenAiAdapter', () {
    test('parses chunked chat-completion deltas into text', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        expect(request.url.path, '/v1/chat/completions');
        expect(request.headers['authorization'], 'Bearer sk-test');
        expect(request.headers['accept'], 'text/event-stream');

        final body = _jsonMap(utf8.decode(await bodyStream.toBytes()));
        expect(body['model'], 'gpt-4o-mini');
        expect(body['stream'], isTrue);
        expect(body['max_tokens'], 1024);
        expect(
          body['stream_options'],
          <String, Object?>{'include_usage': true},
        );
        final messages = body['messages']! as List<dynamic>;
        final first = messages.first as Map<String, dynamic>;
        expect(first['role'], 'user');
        expect(first['content'], 'Hello');

        return http.StreamedResponse(_openAiChunks(), 200);
      });
      addTearDown(client.close);

      final text = await OpenAiAdapter(client: client)
          .streamCompletion(config: _config(), messages: _userTurn('Hello'))
          .text();

      expect(text, 'Hello world');
    });

    test('reads prompt and completion tokens from the usage chunk', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(_openAiUsageSse)),
          200,
        );
      });
      addTearDown(client.close);

      final chunks = await OpenAiAdapter(client: client)
          .streamCompletion(config: _config(), messages: _userTurn('Hello'))
          .toList();

      expect(
        chunks.whereType<AdapterText>().map((chunk) => chunk.text).join(),
        'Hi',
      );
      final usage = chunks.whereType<AdapterUsage>().single;
      expect(usage.inputTokens, 9);
      expect(usage.outputTokens, 2);
    });

    test('uses baseUrl when the config overrides the default host', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        expect(request.url.host, 'example.test');
        expect(request.url.path, '/openai/v1/chat/completions');
        return http.StreamedResponse(Stream<List<int>>.empty(), 200);
      });
      addTearDown(client.close);

      final text = await OpenAiAdapter(client: client)
          .streamCompletion(
            config: _config(baseUrl: 'https://example.test/openai/v1'),
            messages: _userTurn('Hello'),
          )
          .text();

      expect(text, isEmpty);
    });
  });

  group('OpenRouterAdapter', () {
    test('posts chat completions to the OpenRouter root', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        expect(
          request.url,
          Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        );
        expect(request.headers['authorization'], 'Bearer sk-test');

        final body = _jsonMap(utf8.decode(await bodyStream.toBytes()));
        expect(body['model'], 'openai/gpt-4o-mini');
        expect(body['stream'], isTrue);
        expect(body['max_tokens'], 1024);

        return http.StreamedResponse(_openAiChunks(), 200);
      });
      addTearDown(client.close);

      final text = await OpenRouterAdapter(client: client)
          .streamCompletion(
            config: _config(model: 'openai/gpt-4o-mini'),
            messages: _userTurn('Hello'),
          )
          .text();

      expect(text, 'Hello world');
    });
  });

  group('AnthropicAdapter', () {
    test('parses content_block_delta text and ignores other events', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        expect(request.url.path, '/v1/messages');
        expect(request.headers['x-api-key'], 'sk-test');
        expect(request.headers['anthropic-version'], '2023-06-01');

        final body = _jsonMap(utf8.decode(await bodyStream.toBytes()));
        expect(body['model'], 'claude-3-5-haiku-latest');
        expect(body['max_tokens'], 1024);
        expect(body['stream'], isTrue);

        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(_anthropicSse)),
          200,
        );
      });
      addTearDown(client.close);

      final chunks = await AnthropicAdapter(client: client)
          .streamCompletion(
            config: _config(model: 'claude-3-5-haiku-latest'),
            messages: _userTurn('Hello'),
          )
          .toList();

      expect(
        chunks.whereType<AdapterText>().map((chunk) => chunk.text).toList(),
        <String>['Hello', ' world'],
      );
    });

    test('reads input tokens from message_start and output from message_delta',
        () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(_anthropicUsageSse)),
          200,
        );
      });
      addTearDown(client.close);

      final chunks = await AnthropicAdapter(client: client)
          .streamCompletion(
            config: _config(model: 'claude-3-5-haiku-latest'),
            messages: _userTurn('Hello'),
          )
          .toList();
      final usage = chunks.whereType<AdapterUsage>().toList();

      expect(
          usage.map((event) => event.inputTokens).toList(), <int?>[25, null]);
      expect(
          usage.map((event) => event.outputTokens).toList(), <int?>[null, 4]);
    });
  });

  group('GeminiAdapter', () {
    test('parses alt=sse candidate parts into text', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        expect(
          request.url.path,
          '/v1beta/models/gemini-2.0-flash:streamGenerateContent',
        );
        expect(request.url.queryParameters['alt'], 'sse');
        expect(request.headers['x-goog-api-key'], 'sk-test');
        expect(request.url.queryParameters.containsKey('key'), isFalse);

        final body = _jsonMap(utf8.decode(await bodyStream.toBytes()));
        final contents = body['contents'];
        expect(contents, isA<List<dynamic>>());

        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(_geminiSse)),
          200,
        );
      });
      addTearDown(client.close);

      final text = await GeminiAdapter(client: client)
          .streamCompletion(
            config: _config(model: 'gemini-2.0-flash'),
            messages: _userTurn('Hello'),
          )
          .text();

      expect(text, 'Hello world');
    });

    test('reads usageMetadata token counts', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(_geminiUsageSse)),
          200,
        );
      });
      addTearDown(client.close);

      final chunks = await GeminiAdapter(client: client)
          .streamCompletion(
            config: _config(model: 'gemini-2.0-flash'),
            messages: _userTurn('Hello'),
          )
          .toList();
      final usage = chunks.whereType<AdapterUsage>().single;

      expect(usage.inputTokens, 8);
      expect(usage.outputTokens, 3);
    });
  });

  group('BaseLlmAdapter HTTP mapping', () {
    test('HTTP 429 throws RetryableLlmException', () async {
      await _expectStatus<RetryableLlmException>(429, 'rate limited');
    });

    test('HTTP 503 throws RetryableLlmException', () async {
      await _expectStatus<RetryableLlmException>(503, 'unavailable');
    });

    test('HTTP 401 throws TerminalLlmException', () async {
      await _expectStatus<TerminalLlmException>(401, 'unauthorized');
    });

    test('HTTP 400 throws TerminalLlmException', () async {
      await _expectStatus<TerminalLlmException>(400, 'invalid prompt');
    });

    test('HTTP 403 throws TerminalLlmException', () async {
      await _expectStatus<TerminalLlmException>(403, 'forbidden');
    });

    test('HTTP 402 throws TerminalLlmException', () async {
      await _expectStatus<TerminalLlmException>(402, 'insufficient credits');
    });

    test('a timed-out request throws RetryableLlmException', () async {
      final client = MockClient((request) => Completer<http.Response>().future);
      addTearDown(client.close);

      expect(
        OpenAiAdapter(client: client)
            .streamCompletion(
              config: _config(timeout: const Duration(milliseconds: 50)),
              messages: _userTurn('Hello'),
            )
            .toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.cause,
            'cause',
            isA<TimeoutException>(),
          ),
        ),
      );
    });

    test('a dropped socket throws RetryableLlmException', () async {
      final client = MockClient((request) async {
        throw http.ClientException('socket closed');
      });
      addTearDown(client.close);

      expect(
        OpenAiAdapter(client: client)
            .streamCompletion(config: _config(), messages: _userTurn('Hello'))
            .toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.message,
            'message',
            contains('socket closed'),
          ),
        ),
      );
    });

    test('malformed SSE JSON throws RetryableLlmException', () async {
      final client = MockClient((request) async {
        return http.Response('data: {not-json}\n\n', 200);
      });
      addTearDown(client.close);

      expect(
        OpenAiAdapter(client: client)
            .streamCompletion(config: _config(), messages: _userTurn('Hello'))
            .toList(),
        throwsA(isA<RetryableLlmException>()),
      );
    });

    test('close releases an adapter-owned client and ignores an injected one',
        () {
      OpenAiAdapter().close();

      final client = MockClient((request) async => http.Response('', 200));
      addTearDown(client.close);
      OpenAiAdapter(client: client).close();
    });
  });

  group('AllProvidersFailedException', () {
    test('keeps the attempt list that exhausted the chain', () {
      final timestamp = DateTime.utc(2026, 10, 1);
      final attempts = <AttemptLog>[
        AttemptLog(
          providerName: 'openai',
          model: 'gpt-4o-mini',
          timestamp: timestamp,
          latencyMs: 12,
          isSuccess: false,
          error: 'HTTP 503',
          statusCode: 503,
        ),
      ];

      final error = AllProvidersFailedException(attempts);

      expect(error.attempts, hasLength(1));
      expect(error.attempts.single.providerName, 'openai');
      expect(error.message, contains('1 attempts'));
      expect(() => error.attempts.add(attempts.single), throwsUnsupportedError);
    });
  });
}

const _openAiTail = 'lo"}}]}\n\n'
    'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n'
    'data: {"choices":[{"delta":{"content":" world"}}]}\n\n'
    'data: [DONE]\n\n';

Stream<List<int>> _openAiChunks() async* {
  yield utf8.encode('data: {"choices":[{"delta":{"content":"Hel');
  yield utf8.encode(_openAiTail);
}

const _openAiUsageSse = '''
data: {"choices":[{"delta":{"content":"Hi"}}]}

data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":2,"total_tokens":11}}

data: [DONE]

''';

const _anthropicUsageSse = '''
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1}}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}

''';

const _geminiUsageSse = '''
data: {"candidates":[{"content":{"parts":[{"text":"Hi"}],"role":"model"}}],"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":3,"totalTokenCount":11}}

''';

const _anthropicSse = '''
event: message_start
data: {"type":"message_start","message":{"id":"msg_1"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

event: message_stop
data: {"type":"message_stop"}

''';

const _geminiSse = '''
data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}

data: {"candidates":[{"content":{"parts":[{"text":" world"}],"role":"model"},"finishReason":"STOP"}]}

''';

ProviderConfig _config({
  String model = 'gpt-4o-mini',
  String? baseUrl,
  Duration timeout = const Duration(seconds: 30),
}) {
  return ProviderConfig(
    name: 'primary',
    apiKey: 'sk-test',
    model: model,
    pricePerInputToken: 0.000001,
    pricePerOutputToken: 0.000002,
    baseUrl: baseUrl,
    timeout: timeout,
  );
}

extension on Stream<AdapterChunk> {
  Future<String> text() async {
    final buffer = StringBuffer();
    await for (final chunk in this) {
      if (chunk is AdapterText) buffer.write(chunk.text);
    }
    return buffer.toString();
  }
}

List<ChatTurn> _userTurn(String text) {
  return <ChatTurn>[ChatTurn(role: ChatTurnRole.user, text: text)];
}

Map<String, dynamic> _jsonMap(String source) {
  final decoded = jsonDecode(source);
  expect(decoded, isA<Map<String, dynamic>>());
  return decoded as Map<String, dynamic>;
}

Future<void> _expectStatus<T extends LlmRouterException>(
  int statusCode,
  String body,
) {
  final client = MockClient(
    (request) async => http.Response(body, statusCode),
  );
  addTearDown(client.close);

  return expectLater(
    OpenAiAdapter(client: client)
        .streamCompletion(config: _config(), messages: _userTurn('Hello'))
        .toList(),
    throwsA(
      isA<T>()
          .having((error) => error.statusCode, 'statusCode', statusCode)
          .having((error) => error.message, 'message', contains(body)),
    ),
  );
}
