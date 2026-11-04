import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Attachments, request settings, finish reasons, presets, and cached-token
/// pricing.
void main() {
  final png = FileTurnAttachment(
    name: 'cat.png',
    mimeType: 'image/png',
    bytes: Uint8List.fromList(<int>[1, 2, 3]),
  );
  final pdf = FileTurnAttachment(
    name: 'spec.pdf',
    mimeType: 'application/pdf',
    bytes: Uint8List.fromList(<int>[4, 5]),
  );
  final notes = FileTurnAttachment(
    name: 'notes.txt',
    mimeType: 'text/plain',
    bytes: Uint8List.fromList(utf8.encode('remember milk')),
  );
  const settings = GenerationSettings(
    systemPrompt: 'Be brief.',
    temperature: 0.2,
    topP: 0.9,
    stopSequences: <String>['END'],
  );

  group('attachment kinds', () {
    test('MIME types map to kinds', () {
      expect(AttachmentKind.fromMimeType('image/webp'), AttachmentKind.image);
      expect(
        AttachmentKind.fromMimeType('application/pdf'),
        AttachmentKind.pdf,
      );
      expect(AttachmentKind.fromMimeType('text/csv'), AttachmentKind.text);
      expect(
        AttachmentKind.fromMimeType('application/ld+json'),
        AttachmentKind.text,
      );
      expect(AttachmentKind.fromMimeType('audio/mpeg'), AttachmentKind.audio);
      expect(AttachmentKind.fromMimeType('video/mp4'), AttachmentKind.video);
      expect(
        AttachmentKind.fromMimeType('application/zip'),
        AttachmentKind.other,
      );
    });

    test('a non-image link is text and an image link is an image', () {
      final page = LinkTurnAttachment(
        name: 'docs',
        mimeType: 'text/html',
        url: Uri.parse('https://example.test/docs'),
      );
      final photo = LinkTurnAttachment(
        name: 'photo',
        mimeType: 'image/jpeg',
        url: Uri.parse('https://example.test/a.jpg'),
      );
      expect(page.kind, AttachmentKind.text);
      expect(photo.kind, AttachmentKind.image);
    });

    test('capabilities always accept text', () {
      expect(
        ProviderCapabilities.textOnly.accepts(AttachmentKind.text),
        isTrue,
      );
      expect(
        ProviderCapabilities.textOnly.unsupported(<AttachmentKind>[
          AttachmentKind.text,
          AttachmentKind.image,
        ]),
        <AttachmentKind>[AttachmentKind.image],
      );
    });
  });

  group('finish reasons', () {
    test('vendor values map to normalised reasons', () {
      const openAi = <Object?, FinishReason?>{
        null: null,
        'stop': FinishReason.stop,
        'length': FinishReason.length,
        'content_filter': FinishReason.contentFilter,
        'tool_calls': FinishReason.toolCall,
        'function_call': FinishReason.toolCall,
        'weird': FinishReason.other,
      };
      const anthropic = <Object?, FinishReason?>{
        null: null,
        'end_turn': FinishReason.stop,
        'stop_sequence': FinishReason.stop,
        'max_tokens': FinishReason.length,
        'refusal': FinishReason.contentFilter,
        'tool_use': FinishReason.toolCall,
        'pause_turn': FinishReason.other,
      };
      const gemini = <Object?, FinishReason?>{
        null: null,
        'FINISH_REASON_UNSPECIFIED': null,
        'STOP': FinishReason.stop,
        'MAX_TOKENS': FinishReason.length,
        'SAFETY': FinishReason.contentFilter,
        'RECITATION': FinishReason.contentFilter,
        'BLOCKLIST': FinishReason.contentFilter,
        'PROHIBITED_CONTENT': FinishReason.contentFilter,
        'SPII': FinishReason.contentFilter,
        'IMAGE_SAFETY': FinishReason.contentFilter,
        'MALFORMED_FUNCTION_CALL': FinishReason.toolCall,
        'UNEXPECTED_TOOL_CALL': FinishReason.toolCall,
        'OTHER': FinishReason.other,
      };
      openAi.forEach((raw, reason) {
        expect(FinishReason.fromOpenAi(raw), reason, reason: '$raw');
      });
      anthropic.forEach((raw, reason) {
        expect(FinishReason.fromAnthropic(raw), reason, reason: '$raw');
      });
      gemini.forEach((raw, reason) {
        expect(FinishReason.fromGemini(raw), reason, reason: '$raw');
      });
    });

    test('Gemini sends audio inline and rejects other binaries', () {
      final audio = ChatTurn(
        role: ChatTurnRole.user,
        text: '',
        attachments: <TurnAttachment>[
          FileTurnAttachment(
            name: 'a.wav',
            mimeType: 'audio/wav',
            bytes: Uint8List(1),
          ),
        ],
      ).toGeminiContent();
      expect(((audio['parts'] as List).single as Map).keys, <String>[
        'inlineData',
      ]);
      final zip = ChatTurn(
        role: ChatTurnRole.user,
        text: 'x',
        attachments: <TurnAttachment>[
          FileTurnAttachment(
            name: 'a.zip',
            mimeType: 'application/zip',
            bytes: Uint8List(1),
          ),
        ],
      );
      expect(
        zip.toGeminiContent,
        throwsA(isA<ProviderUnavailableLlmException>()),
      );
      expect(
        zip.toAnthropicMessage,
        throwsA(isA<ProviderUnavailableLlmException>()),
      );
    });
  });

  group('OpenAI requests', () {
    test('send images, PDFs, inline text, and settings', () async {
      final captured = await _capture(
        (client) => OpenAiAdapter(client: client),
        _config(settings: settings),
        <ChatTurn>[
          ChatTurn(
            role: ChatTurnRole.user,
            text: 'describe',
            attachments: <TurnAttachment>[png, pdf, notes],
          ),
        ],
      );
      final body = captured.body;

      expect(body['max_completion_tokens'], 1024);
      expect(body['temperature'], 0.2);
      expect(body['top_p'], 0.9);
      expect(body['stop'], <String>['END']);
      final messages = body['messages'] as List<dynamic>;
      expect(messages.first, <String, Object?>{
        'role': 'system',
        'content': 'Be brief.',
      });
      final parts = (messages[1] as Map<String, dynamic>)['content'] as List;
      expect(parts[0], <String, Object?>{'type': 'text', 'text': 'describe'});
      expect(parts[1], <String, Object?>{
        'type': 'image_url',
        'image_url': <String, Object?>{'url': 'data:image/png;base64,AQID'},
      });
      expect(parts[2], <String, Object?>{
        'type': 'file',
        'file': <String, Object?>{
          'filename': 'spec.pdf',
          'file_data': 'data:application/pdf;base64,BAU=',
        },
      });
      expect((parts[3] as Map)['text'], contains('remember milk'));
    });

    test('omit settings that are not set', () async {
      final captured = await _capture(
        (client) => OpenAiAdapter(client: client),
        _config(),
        _turns('hi'),
      );
      expect(captured.body.containsKey('temperature'), isFalse);
      expect(captured.body.containsKey('stop'), isFalse);
      expect((captured.body['messages'] as List).length, 1);
    });

    test('audio is provider-scoped, so the router can fail over', () {
      final turn = ChatTurn(
        role: ChatTurnRole.user,
        text: 'listen',
        attachments: <TurnAttachment>[
          FileTurnAttachment(
            name: 'a.mp3',
            mimeType: 'audio/mpeg',
            bytes: Uint8List(1),
          ),
        ],
      );
      expect(
        turn.toOpenAiMessage,
        throwsA(isA<ProviderUnavailableLlmException>()),
      );
    });

    test('finish_reason and cached tokens are reported', () async {
      final chunks = await _stream(
        (client) => OpenAiAdapter(client: client),
        'data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n'
        'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n'
        'data: {"choices":[],"usage":{"prompt_tokens":100,'
        '"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}\n\n',
      );
      expect(
        chunks.whereType<AdapterFinish>().single.reason,
        FinishReason.length,
      );
      final usage = chunks.whereType<AdapterUsage>().single;
      expect(usage.inputTokens, 100);
      expect(usage.cachedInputTokens, 80);
    });

    test('Groq usage under x_groq is read', () async {
      final chunks = await _stream(
        (client) => OpenAiAdapter(client: client),
        'data: {"choices":[{"delta":{"content":"Hi"}}],'
        '"x_groq":{"usage":{"prompt_tokens":7,"completion_tokens":2}}}\n\n',
      );
      expect(chunks.whereType<AdapterUsage>().single.outputTokens, 2);
    });
  });

  group('Anthropic requests', () {
    test('send image and document blocks before the prompt', () async {
      final captured = await _capture(
        (client) => AnthropicAdapter(client: client),
        _config(settings: settings),
        <ChatTurn>[
          ChatTurn(
            role: ChatTurnRole.user,
            text: 'describe',
            attachments: <TurnAttachment>[png, pdf],
          ),
        ],
      );
      final body = captured.body;

      expect(body['system'], 'Be brief.');
      expect(body['temperature'], 0.2);
      expect(body['stop_sequences'], <String>['END']);
      final content =
          ((body['messages'] as List).single as Map)['content'] as List;
      expect(content[0], <String, Object?>{
        'type': 'image',
        'source': <String, Object?>{
          'type': 'base64',
          'media_type': 'image/png',
          'data': 'AQID',
        },
      });
      expect((content[1] as Map)['type'], 'document');
      expect(content[2], <String, Object?>{'type': 'text', 'text': 'describe'});
    });

    test('an image link is sent as a URL source', () {
      final message = ChatTurn(
        role: ChatTurnRole.user,
        text: '',
        attachments: <TurnAttachment>[
          LinkTurnAttachment(
            name: 'photo',
            mimeType: 'image/jpeg',
            url: Uri.parse('https://example.test/a.jpg'),
          ),
        ],
      ).toAnthropicMessage();
      expect(message['content'], <Object?>[
        <String, Object?>{
          'type': 'image',
          'source': <String, Object?>{
            'type': 'url',
            'url': 'https://example.test/a.jpg',
          },
        },
      ]);
    });

    test(
      'stop_reason, cache reads, and overloaded status are reported',
      () async {
        final chunks = await _stream(
          (client) => AnthropicAdapter(client: client),
          'data: {"type":"message_start","message":{"usage":{"input_tokens":10,'
          '"cache_read_input_tokens":90,"cache_creation_input_tokens":5}}}\n\n'
          'data: {"type":"content_block_delta","delta":{"type":"text_delta",'
          '"text":"Hi"}}\n\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},'
          '"usage":{"output_tokens":3}}\n\n',
        );
        final input = chunks.whereType<AdapterUsage>().first;
        expect(input.inputTokens, 105);
        expect(input.cachedInputTokens, 90);
        expect(
          chunks.whereType<AdapterFinish>().single.reason,
          FinishReason.length,
        );

        await expectLater(
          _stream(
            (client) => AnthropicAdapter(client: client),
            'data: {"type":"error","error":{"type":"overloaded_error",'
            '"message":"Overloaded"}}\n\n',
          ),
          throwsA(
            isA<RetryableLlmException>().having(
              (error) => error.statusCode,
              'statusCode',
              529,
            ),
          ),
        );
      },
    );
  });

  group('Gemini requests', () {
    test('send inlineData, systemInstruction, and generationConfig', () async {
      final captured = await _capture(
        (client) => GeminiAdapter(client: client),
        _config(settings: settings),
        <ChatTurn>[
          ChatTurn(
            role: ChatTurnRole.user,
            text: 'describe',
            attachments: <TurnAttachment>[png],
          ),
        ],
      );
      final body = captured.body;

      expect(body['systemInstruction'], <String, Object?>{
        'parts': <Object?>[
          <String, Object?>{'text': 'Be brief.'},
        ],
      });
      expect(body['generationConfig'], <String, Object?>{
        'maxOutputTokens': 1024,
        'temperature': 0.2,
        'topP': 0.9,
        'stopSequences': <String>['END'],
      });
      final parts = ((body['contents'] as List).single as Map)['parts'] as List;
      expect(parts[1], <String, Object?>{
        'inlineData': <String, Object?>{
          'mimeType': 'image/png',
          'data': 'AQID',
        },
      });
    });

    test(
      'a SAFETY finish with no text fails over as a content filter',
      () async {
        final router = _router(
          providers: <ProviderConfig>[
            _config(name: 'alpha'),
            _config(name: 'beta'),
          ],
          adapters: <String, _Handler>{
            'alpha': (config, messages) => Stream<AdapterChunk>.value(
              const AdapterFinish(FinishReason.contentFilter),
            ),
            'beta': (config, messages) =>
                Stream<AdapterChunk>.value(const AdapterText('ok')),
          },
        );

        expect(await router.generateStream('hi').join(), 'ok');
        expect(router.lastAttemptLogs.first.error, contains('content filter'));
        expect(
          router.lastAttemptLogs.first.finishReason,
          FinishReason.contentFilter,
        );
      },
    );

    test('thought parts are not shown and thinking tokens are billed', () async {
      final chunks = await _stream(
        (client) => GeminiAdapter(client: client),
        'data: {"candidates":[{"content":{"parts":[{"text":"hmm","thought":true},'
        '{"text":"Answer"}]},"finishReason":"STOP"}],"usageMetadata":'
        '{"promptTokenCount":4,"candidatesTokenCount":1,"thoughtsTokenCount":9,'
        '"cachedContentTokenCount":2}}\n\n',
      );
      expect(chunks.whereType<AdapterText>().single.text, 'Answer');
      expect(chunks.whereType<AdapterUsage>().single.outputTokens, 10);
      expect(chunks.whereType<AdapterUsage>().single.cachedInputTokens, 2);
      expect(
        chunks.whereType<AdapterFinish>().single.reason,
        FinishReason.stop,
      );
    });
  });

  group('capability routing', () {
    test(
      'a provider that cannot take an image is skipped and logged',
      () async {
        final seen = <String>[];
        final router = _router(
          providers: <ProviderConfig>[
            _config(name: 'text', capabilities: ProviderCapabilities.textOnly),
            _config(name: 'vision', capabilities: ProviderCapabilities.vision),
          ],
          adapters: <String, _Handler>{
            'text': (config, messages) {
              seen.add('text');
              return Stream<AdapterChunk>.value(const AdapterText('no'));
            },
            'vision': (config, messages) {
              seen.add('vision');
              expect(messages.single.attachments.single.name, 'cat.png');
              return Stream<AdapterChunk>.value(const AdapterText('a cat'));
            },
          },
        );

        final reply = await router
            .generateStream('what?', attachments: <Attachment>[_toolkitImage()])
            .join();

        expect(reply, 'a cat');
        expect(seen, <String>['vision']);
        final skipped = router.lastAttemptLogs.first;
        expect(skipped.isSkipped, isTrue);
        expect(skipped.skipReason, contains('image'));
        expect(skipped.isSuccess, isFalse);
      },
    );

    test('built-in adapters declare what their vendor accepts', () {
      expect(
        OpenAiAdapter().capabilities.accepts(AttachmentKind.audio),
        isFalse,
      );
      expect(
        GeminiAdapter().capabilities.accepts(AttachmentKind.video),
        isTrue,
      );
      expect(
        AnthropicAdapter().capabilities.accepts(AttachmentKind.pdf),
        isTrue,
      );
    });

    test(
      'when no provider can take the attachment, the error says so',
      () async {
        final router = _router(
          providers: <ProviderConfig>[
            _config(name: 'text', capabilities: ProviderCapabilities.textOnly),
          ],
        );

        await expectLater(
          router
              .generateStream(
                'what?',
                attachments: <Attachment>[_toolkitImage()],
              )
              .join(),
          throwsA(
            isA<AllProvidersFailedException>().having(
              (error) => error.message,
              'message',
              contains('No provider accepts'),
            ),
          ),
        );
      },
    );

    test('an HTTP 400 on a request with an image fails over', () async {
      final router = _router(
        providers: <ProviderConfig>[
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        adapters: <String, _Handler>{
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const TerminalLlmException('HTTP 400: bad image', statusCode: 400),
          ),
          'beta': (config, messages) =>
              Stream<AdapterChunk>.value(const AdapterText('a cat')),
        },
      );

      final reply = await router
          .generateStream('what?', attachments: <Attachment>[_toolkitImage()])
          .join();
      expect(reply, 'a cat');
      expect(router.lastAttemptLogs.first.statusCode, 400);
    });

    test('an HTTP 400 without attachments still stops the chain', () async {
      final router = _router(
        providers: <ProviderConfig>[
          _config(name: 'alpha'),
          _config(name: 'beta'),
        ],
        adapters: <String, _Handler>{
          'alpha': (config, messages) => Stream<AdapterChunk>.error(
            const TerminalLlmException('HTTP 400', statusCode: 400),
          ),
        },
      );
      await expectLater(
        router.generateStream('hi').join(),
        throwsA(isA<TerminalLlmException>()),
      );
    });
  });

  group('settings', () {
    test('router settings are defaults and provider settings win', () async {
      final seen = <GenerationSettings>[];
      final router = _router(
        providers: <ProviderConfig>[
          _config(
            name: 'alpha',
            settings: const GenerationSettings(temperature: 1),
          ),
        ],
        settings: const GenerationSettings(
          systemPrompt: 'Be kind.',
          temperature: 0.1,
        ),
        adapters: <String, _Handler>{
          'alpha': (config, messages) {
            seen.add(config.settings);
            return Stream<AdapterChunk>.value(const AdapterText('ok'));
          },
        },
      );

      await router.generateStream('hi').drain<void>();
      router.settings = const GenerationSettings(systemPrompt: 'Be terse.');
      await router.generateStream('hi').drain<void>();

      expect(seen[0].systemPrompt, 'Be kind.');
      expect(seen[0].temperature, 1);
      expect(seen[1].systemPrompt, 'Be terse.');
    });

    test(
      'a truncated reply is a success that logs FinishReason.length',
      () async {
        final router = _router(
          providers: <ProviderConfig>[_config(name: 'alpha')],
          adapters: <String, _Handler>{
            'alpha': (config, messages) =>
                Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
                  AdapterText('cut'),
                  AdapterFinish(FinishReason.length),
                ]),
          },
        );

        expect(await router.generateStream('hi').join(), 'cut');
        expect(router.lastAttemptLogs.single.isSuccess, isTrue);
        expect(router.lastAttemptLogs.single.finishReason, FinishReason.length);
        expect(router.lastAttemptLogs.single.timeToFirstTokenMs, isNotNull);
      },
    );
  });

  group('presets', () {
    test('local presets are free, local, and use the OpenAI adapter', () {
      final ollama = ProviderConfig.ollama(model: 'llama3.2');
      expect(ollama.baseUrl, 'http://localhost:11434/v1');
      expect(ollama.adapter, 'openai');
      expect(ollama.isFree, isTrue);
      expect(ollama.capabilities, ProviderCapabilities.textOnly);
      expect(ProviderConfig.lmStudio(model: 'qwen').baseUrl, contains('1234'));
    });

    test('hosted presets set their endpoints', () {
      final groq = ProviderConfig.groq(
        apiKey: 'k',
        model: 'llama-3.3-70b-versatile',
        pricePerInputToken: 0,
        pricePerOutputToken: 0,
      );
      final mistral = ProviderConfig.mistral(
        apiKey: 'k',
        model: 'mistral-small-latest',
        pricePerInputToken: 0,
        pricePerOutputToken: 0,
      );
      final deepSeek = ProviderConfig.deepSeek(
        apiKey: 'k',
        model: 'deepseek-chat',
        pricePerInputToken: 0,
        pricePerOutputToken: 0,
      );
      expect(groq.baseUrl, 'https://api.groq.com/openai/v1');
      expect(mistral.requestStreamUsage, isFalse);
      expect(deepSeek.capabilities, ProviderCapabilities.textOnly);
    });

    test('an Azure deployment gets its URL, api-key, and api-version', () async {
      final config = ProviderConfig.azureOpenAi(
        endpoint: 'https://res.openai.azure.com/',
        deployment: 'gpt-4o',
        apiKey: 'secret',
        pricePerInputToken: 0,
        pricePerOutputToken: 0,
      );
      final captured = await _capture(
        (client) => AzureOpenAiAdapter(client: client),
        config,
        _turns('hi'),
      );

      expect(
        captured.url.toString(),
        'https://res.openai.azure.com/openai/deployments/gpt-4o/chat/completions'
        '?api-version=2024-10-21',
      );
      expect(captured.headers['api-key'], 'secret');
      expect(captured.headers.containsKey('authorization'), isFalse);
      expect(captured.body['max_completion_tokens'], 1024);
      expect(config.model, 'gpt-4o');
    });

    test(
      'ProviderConfig.adapter selects a built-in adapter for any name',
      () async {
        // The built-in OpenAiAdapter owns a real client, so point it at a
        // closed local port: a connection failure, rather than the terminal
        // "No adapter registered" error, proves the key resolved.
        final router = RouterLlmProvider(
          providers: <ProviderConfig>[
            _config(name: 'fast').copyWith(
              adapter: 'OpenAI',
              baseUrl: 'http://127.0.0.1:9/v1',
              timeout: const Duration(seconds: 5),
            ),
          ],
          connectivityChecker: const AssumeOnlineConnectivityChecker(),
        );
        addTearDown(router.dispose);

        await expectLater(
          router.generateStream('hi').join(),
          throwsA(isA<AllProvidersFailedException>()),
        );
        expect(router.lastAttemptLogs.single.providerName, 'fast');
        expect(router.lastAttemptLogs.single.error, contains('127.0.0.1'));
      },
      testOn: 'vm',
    );

    test('an unknown adapter key is terminal and names the options', () async {
      final router = RouterLlmProvider(
        providers: <ProviderConfig>[
          _config(name: 'fast').copyWith(adapter: 'nope'),
        ],
        connectivityChecker: const AssumeOnlineConnectivityChecker(),
      );
      addTearDown(router.dispose);

      await expectLater(
        router.generateStream('hi').join(),
        throwsA(
          isA<TerminalLlmException>().having(
            (error) => error.message,
            'message',
            contains('azure-openai'),
          ),
        ),
      );
    });
  });

  group('cached-token pricing', () {
    test('cached tokens use their own price when set', () {
      final config = _config().copyWith(
        pricePerInputToken: 0.000002,
        pricePerOutputToken: 0.00001,
        pricePerCachedInputToken: 0.0000005,
      );
      expect(
        config.calculateCost(
          inputTokens: 1000,
          cachedInputTokens: 800,
          outputTokens: 10,
        ),
        closeTo(200 * 0.000002 + 800 * 0.0000005 + 10 * 0.00001, 1e-12),
      );
      expect(
        config
            .copyWith(pricePerCachedInputToken: null)
            .calculateCost(
              inputTokens: 1000,
              cachedInputTokens: 800,
              outputTokens: 0,
            ),
        closeTo(1000 * 0.000002, 1e-12),
      );
    });

    test('the router bills cached tokens reported by the provider', () async {
      final tracker = CostTracker();
      addTearDown(tracker.dispose);
      final router = _router(
        providers: <ProviderConfig>[
          _config(name: 'alpha').copyWith(
            pricePerInputToken: 1,
            pricePerOutputToken: 0,
            pricePerCachedInputToken: 0.5,
          ),
        ],
        tracker: tracker,
        adapters: <String, _Handler>{
          'alpha': (config, messages) =>
              Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
                AdapterText('ok'),
                AdapterUsage(
                  inputTokens: 10,
                  cachedInputTokens: 4,
                  outputTokens: 1,
                ),
              ]),
        },
      );

      await router.generateStream('hi').drain<void>();
      expect(tracker.totalCost, 6 * 1 + 4 * 0.5);
      expect(tracker.totalCachedInputTokens, 4);
      expect(tracker.usageByProvider['alpha']?.cachedInputTokens, 4);
    });
  });

  group('error responses', () {
    test('Retry-After is parsed and the body is redacted', () async {
      final client = MockClient(
        (request) async => http.Response(
          'secret prompt echo',
          429,
          headers: <String, String>{'retry-after': '2'},
        ),
      );
      addTearDown(client.close);

      await expectLater(
        OpenAiAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')).toList(),
        throwsA(
          isA<RetryableLlmException>()
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 2),
              )
              .having((error) => error.message, 'message', contains('secret'))
              .having(
                (error) => error.redactedMessage,
                'redactedMessage',
                'HTTP 429',
              ),
        ),
      );
    });

    test('retry-after-ms takes precedence', () async {
      final client = MockClient(
        (request) async => http.Response(
          '',
          503,
          headers: <String, String>{
            'retry-after-ms': '250',
            'retry-after': '9',
          },
        ),
      );
      addTearDown(client.close);

      await expectLater(
        OpenAiAdapter(
          client: client,
        ).streamCompletion(config: _config(), messages: _turns('hi')).toList(),
        throwsA(
          isA<RetryableLlmException>().having(
            (error) => error.retryAfter,
            'retryAfter',
            const Duration(milliseconds: 250),
          ),
        ),
      );
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
  ProviderCapabilities? capabilities,
}) {
  return ProviderConfig(
    name: name,
    apiKey: 'test-key',
    model: '$name-model',
    pricePerInputToken: 0,
    pricePerOutputToken: 0,
    settings: settings,
    capabilities: capabilities,
  );
}

List<ChatTurn> _turns(String text) => <ChatTurn>[
  ChatTurn(role: ChatTurnRole.user, text: text),
];

ImageFileAttachment _toolkitImage() => ImageFileAttachment(
  name: 'cat.png',
  mimeType: 'image/png',
  bytes: Uint8List.fromList(<int>[1, 2, 3]),
);

typedef _Captured = ({
  Uri url,
  Map<String, String> headers,
  Map<String, dynamic> body,
});

Future<_Captured> _capture(
  BaseLlmAdapter Function(http.Client client) build,
  ProviderConfig config,
  List<ChatTurn> messages,
) async {
  late _Captured captured;
  final client = MockClient.streaming((request, bodyStream) async {
    final body = await utf8.decodeStream(bodyStream);
    captured = (
      url: request.url,
      headers: request.headers,
      body: jsonDecode(body) as Map<String, dynamic>,
    );
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'),
      ),
      200,
    );
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
  GenerationSettings settings = const GenerationSettings(),
  CostTracker? tracker,
}) {
  final client = MockClient((request) async => http.Response('', 200));
  final router = RouterLlmProvider(
    providers: providers,
    costTracker: tracker,
    settings: settings,
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
