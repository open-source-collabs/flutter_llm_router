import 'dart:convert';

import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Status mapping, SSE noise, and vendor payload edges the happy path skips.
void main() {
  group('HTTP status boundaries', () {
    test('408, 500, and 599 are retryable', () async {
      await _expectStatus<RetryableLlmException>(408, 'request timeout');
      await _expectStatus<RetryableLlmException>(500, 'boom');
      await _expectStatus<RetryableLlmException>(599, 'edge');
    });

    test('404, 418, and 301 stop the chain', () async {
      await _expectStatus<TerminalLlmException>(404, 'missing');
      await _expectStatus<TerminalLlmException>(418, 'teapot');
      await _expectStatus<TerminalLlmException>(301, 'moved');
    });

    test('an empty error body is reported as the status alone', () async {
      final client = MockClient((request) async => http.Response('', 401));
      addTearDown(client.close);

      await expectLater(
        _openAi(client).toList(),
        throwsA(
          isA<TerminalLlmException>().having(
            (error) => error.message,
            'message',
            'HTTP 401',
          ),
        ),
      );
    });

    test('a long error body is cut at 500 characters', () async {
      final body = '${'x' * 500}TAIL';
      final client = MockClient((request) async => http.Response(body, 400));
      addTearDown(client.close);

      await expectLater(
        _openAi(client).toList(),
        throwsA(
          isA<TerminalLlmException>().having(
            (error) => error.message,
            'message',
            'HTTP 400: ${'x' * 500}',
          ),
        ),
      );
    });

    test('a dropped error body stays retryable and keeps the status', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(
          Stream<List<int>>.error(http.ClientException('reset')),
          503,
        );
      });
      addTearDown(client.close);

      await expectLater(
        _openAi(client).toList(),
        throwsA(
          isA<RetryableLlmException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having(
                (error) => error.message,
                'message',
                contains('reading the error response'),
              ),
        ),
      );
    });
  });

  group('SSE framing', () {
    test('skips comments, blanks, event names, and the DONE sentinel',
        () async {
      const body = '''
: keep-alive

event: ping
data:
data: [DONE]
data:{"choices":[{"delta":{"content":"Yo"}}]}

''';
      final client = _sse(body);
      addTearDown(client.close);

      expect(await _openAi(client).text(), 'Yo');
    });

    test('a 200 body that is not SSE yields no text', () async {
      final client = MockClient(
        (request) async => http.Response('{"error":"hidden"}', 200),
      );
      addTearDown(client.close);

      expect(await _openAi(client).text(), isEmpty);
    });

    test('a JSON array, string, or null is retryable', () async {
      for (final payload in <String>['[1,2]', '"hello"', 'null']) {
        final client = _sse('data: $payload\n\n');
        addTearDown(client.close);

        await expectLater(
          _openAi(client).toList(),
          throwsA(
            isA<RetryableLlmException>().having(
              (error) => error.message,
              'message',
              'SSE JSON payload was not an object',
            ),
          ),
        );
      }
    });

    test('invalid UTF-8 after a text chunk is retryable', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(_utf8ThenGarbage(), 200);
      });
      addTearDown(client.close);

      final text = <String>[];
      await expectLater(
        _collectText(_openAi(client), text),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.message,
            'message',
            contains('UTF-8'),
          ),
        ),
      );
      expect(text, <String>['Hi']);
    });

    test('a socket drop after text keeps the status and the fragment',
        () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        return http.StreamedResponse(_textThenReset(), 200);
      });
      addTearDown(client.close);

      final text = <String>[];
      await expectLater(
        _collectText(_openAi(client), text),
        throwsA(
          isA<RetryableLlmException>()
              .having((error) => error.statusCode, 'statusCode', 200)
              .having(
                (error) => error.cause,
                'cause',
                isA<http.ClientException>(),
              ),
        ),
      );
      expect(text, <String>['Hi']);
    });

    test('CRLF framed events still parse', () async {
      final client = _sse(
        'data: {"choices":[{"delta":{"content":"A"}}]}\r\n\r\n'
        'data: {"choices":[{"delta":{"content":"B"}}]}\r\n\r\n'
        'data: [DONE]\r\n',
      );
      addTearDown(client.close);

      expect(await _openAi(client).text(), 'AB');
    });
  });

  group('OpenAI payload edges', () {
    test('ignores role chunks, empty content, and negative usage', () async {
      const body = '''
data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

data: {"choices":[{"delta":{"content":"Ok"}}],"usage":{"prompt_tokens":-1,"completion_tokens":3}}

data: {"choices":[],"usage":{"prompt_tokens":"9","completion_tokens":1.9}}

data: [DONE]

''';
      final client = _sse(body);
      addTearDown(client.close);

      final chunks = await _openAi(client).toList();
      final usage = chunks.whereType<AdapterUsage>().toList();

      expect(
        chunks.whereType<AdapterText>().map((chunk) => chunk.text).join(),
        'Ok',
      );
      expect(usage, hasLength(2));
      expect(usage.first.inputTokens, isNull);
      expect(usage.first.outputTokens, 3);
      expect(usage.last.inputTokens, isNull);
      expect(usage.last.outputTokens, 1);
    });

    test('sends the configured cap, trailing-slash root, and both roles',
        () async {
      final client = MockClient.streaming((request, bodyStream) async {
        final body = jsonDecode(utf8.decode(await bodyStream.toBytes()))
            as Map<String, dynamic>;
        expect(body['max_tokens'], 128);
        final messages = body['messages']! as List<dynamic>;
        expect(
          messages.map((message) => (message as Map)['role']).toList(),
          <String>['user', 'assistant'],
        );
        expect(request.url.path, '/openai/v1/chat/completions');
        return http.StreamedResponse(Stream<List<int>>.empty(), 200);
      });
      addTearDown(client.close);

      await OpenAiAdapter(client: client).streamCompletion(
        config: _config(
          baseUrl: 'https://example.test/openai/v1/',
          maxOutputTokens: 128,
        ),
        messages: const <ChatTurn>[
          ChatTurn(role: ChatTurnRole.user, text: 'Hi'),
          ChatTurn(role: ChatTurnRole.assistant, text: 'Hello'),
        ],
      ).drain<void>();
    });
  });

  group('Anthropic payload edges', () {
    test('ignores tool deltas and empty text, and honors baseUrl', () async {
      const body = '''
data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}

data: {"type":"content_block_delta","delta":{"type":"text_delta","text":""}}

data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Sure"}}

data: {"type":"message_start","message":{"id":"msg_1"}}

''';
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        expect(request.url.path, '/anthropic/v1/messages');
        expect(request.headers['x-api-key'], 'sk-test');
        expect(request.headers['anthropic-version'], '2023-06-01');
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(body)),
          200,
        );
      });
      addTearDown(client.close);

      final chunks = await AnthropicAdapter(client: client).streamCompletion(
        config: _config(
          model: 'claude-3-5-haiku-latest',
          baseUrl: 'https://example.test/anthropic/v1',
        ),
        messages: const <ChatTurn>[
          ChatTurn(role: ChatTurnRole.user, text: 'Hi'),
        ],
      ).toList();

      expect(
        chunks.whereType<AdapterText>().map((chunk) => chunk.text).toList(),
        <String>['Sure'],
      );
      expect(chunks.whereType<AdapterUsage>(), isEmpty);
    });
  });

  group('Gemini payload edges', () {
    test('joins parts, skips blanks, and encodes the model id', () async {
      const body = '''
data: {"candidates":[{"content":{"parts":[{"text":"A"},{"text":""},{"inlineData":{"data":"x"}},{"text":"B"}]}},{"content":{"parts":[{"text":"C"}]}}],"usageMetadata":{"promptTokenCount":4}}

''';
      final client = MockClient.streaming((request, bodyStream) async {
        final decoded = jsonDecode(utf8.decode(await bodyStream.toBytes()))
            as Map<String, dynamic>;
        final generation = decoded['generationConfig']! as Map<String, dynamic>;
        expect(generation['maxOutputTokens'], 64);
        expect(
          request.url.path,
          '/gemini/models/gemini%202.0:streamGenerateContent',
        );
        expect(request.url.queryParameters, <String, String>{'alt': 'sse'});
        expect(request.url.queryParameters.containsKey('key'), isFalse);
        expect(request.headers['x-goog-api-key'], 'sk-test');
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(body)),
          200,
        );
      });
      addTearDown(client.close);

      final chunks = await GeminiAdapter(client: client).streamCompletion(
        config: _config(
          model: 'gemini 2.0',
          baseUrl: 'https://example.test/gemini',
          maxOutputTokens: 64,
        ),
        messages: const <ChatTurn>[
          ChatTurn(role: ChatTurnRole.user, text: 'Hi'),
        ],
      ).toList();

      expect(
        chunks.whereType<AdapterText>().map((chunk) => chunk.text).join(),
        'ABC',
      );
      expect(chunks.whereType<AdapterUsage>().single.inputTokens, 4);
      expect(chunks.whereType<AdapterUsage>().single.outputTokens, isNull);
    });
  });

  group('OpenRouter payload edges', () {
    test('keeps an explicit baseUrl instead of the OpenRouter default',
        () async {
      final client = MockClient.streaming((request, bodyStream) async {
        await bodyStream.drain<void>();
        expect(
          request.url,
          Uri.parse('https://proxy.example/api/v1/chat/completions'),
        );
        return http.StreamedResponse(Stream<List<int>>.empty(), 200);
      });
      addTearDown(client.close);

      await OpenRouterAdapter(client: client).streamCompletion(
        config: _config(
          model: 'openai/gpt-4o-mini',
          baseUrl: 'https://proxy.example/api/v1/',
        ),
        messages: const <ChatTurn>[
          ChatTurn(role: ChatTurnRole.user, text: 'Hi'),
        ],
      ).drain<void>();
    });
  });
}

const _user = <ChatTurn>[
  ChatTurn(role: ChatTurnRole.user, text: 'Hello'),
];

ProviderConfig _config({
  String model = 'gpt-4o-mini',
  String? baseUrl,
  int maxOutputTokens = 1024,
}) {
  return ProviderConfig(
    name: 'primary',
    apiKey: 'sk-test',
    model: model,
    pricePerInputToken: 0.000001,
    pricePerOutputToken: 0.000002,
    baseUrl: baseUrl,
    maxOutputTokens: maxOutputTokens,
  );
}

Stream<AdapterChunk> _openAi(http.Client client) {
  return OpenAiAdapter(client: client).streamCompletion(
    config: _config(),
    messages: _user,
  );
}

MockClient _sse(String body) {
  return MockClient((request) async => http.Response(body, 200));
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
    _openAi(client).toList(),
    throwsA(
      isA<T>()
          .having((error) => error.statusCode, 'statusCode', statusCode)
          .having((error) => error.message, 'message', contains(body)),
    ),
  );
}

Future<void> _collectText(
    Stream<AdapterChunk> chunks, List<String> into) async {
  await for (final chunk in chunks) {
    if (chunk is AdapterText) into.add(chunk.text);
  }
}

Stream<List<int>> _utf8ThenGarbage() async* {
  yield utf8.encode('data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n');
  yield <int>[0x80];
}

Stream<List<int>> _textThenReset() async* {
  yield utf8.encode('data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n');
  throw http.ClientException('connection reset');
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
