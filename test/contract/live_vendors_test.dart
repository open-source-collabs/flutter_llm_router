@Tags(<String>['contract'])
library;

import 'dart:convert';

import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Live calls to each vendor, to catch API drift and retired models.
///
/// Every test skips unless its key is passed with `--dart-define`, so the
/// normal test run never touches the network. The nightly `contract`
/// workflow runs them with repository secrets:
///
/// ```sh
/// flutter test test/contract \
///   --dart-define=OPENAI_API_KEY=... \
///   --dart-define=ANTHROPIC_API_KEY=... \
///   --dart-define=GEMINI_API_KEY=...
/// ```
///
/// Override a model with `OPENAI_MODEL`, `ANTHROPIC_MODEL`, or
/// `GEMINI_MODEL` when a default is retired.
void main() {
  const vendors = <_Vendor>[
    _Vendor(
      name: 'openai',
      key: String.fromEnvironment('OPENAI_API_KEY'),
      model: String.fromEnvironment(
        'OPENAI_MODEL',
        defaultValue: 'gpt-4o-mini',
      ),
    ),
    _Vendor(
      name: 'anthropic',
      key: String.fromEnvironment('ANTHROPIC_API_KEY'),
      model: String.fromEnvironment(
        'ANTHROPIC_MODEL',
        defaultValue: 'claude-haiku-4-5',
      ),
    ),
    _Vendor(
      name: 'gemini',
      key: String.fromEnvironment('GEMINI_API_KEY'),
      model: String.fromEnvironment(
        'GEMINI_MODEL',
        defaultValue: 'gemini-2.5-flash',
      ),
    ),
  ];

  for (final vendor in vendors) {
    group(vendor.name, () {
      test('streams text, usage, and a finish reason', () async {
        final router = vendor.router();
        addTearDown(router.dispose);
        final events = <RouterEvent>[];
        router.events.listen(events.add);

        final reply = await router
            .generateStream('Reply with the single word: pong')
            .join();

        expect(reply.toLowerCase(), contains('pong'));
        final log = router.lastAttemptLogs.single;
        expect(log.isSuccess, isTrue, reason: log.error);
        expect(log.finishReason, isNotNull);
        await Future<void>.delayed(Duration.zero);
        final usage = events.whereType<UsageRecorded>().single;
        expect(usage.estimated, isFalse, reason: 'usage was not reported');
      }, skip: vendor.skipReason);

      test('reads an image attachment', () async {
        final router = vendor.router();
        addTearDown(router.dispose);

        final reply = await router
            .generateStream(
              'What colour is this image? Answer in one word.',
              attachments: <Attachment>[_redPixel()],
            )
            .join();

        expect(reply.toLowerCase(), contains('red'));
      }, skip: vendor.skipReason);

      test('runs a tool round-trip', () async {
        final asked = <String>[];
        final router = RouterLlmProvider(
          providers: <ProviderConfig>[vendor.config],
          connectivityChecker: const AssumeOnlineConnectivityChecker(),
          tools: <RouterTool>[
            RouterTool(
              name: 'get_secret_word',
              description: 'Returns the secret word for a given topic.',
              parameters: const <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'topic': <String, Object?>{'type': 'string'},
                },
                'required': <String>['topic'],
              },
              handler: (arguments) {
                asked.add('${arguments['topic']}');
                return <String, Object?>{'word': 'pelican'};
              },
            ),
          ],
        );
        addTearDown(router.dispose);

        final reply = await router
            .generateStream(
              'Call get_secret_word with topic "birds", then tell me the word.',
            )
            .join();

        expect(asked, isNotEmpty);
        expect(reply.toLowerCase(), contains('pelican'));
      }, skip: vendor.skipReason);

      test('returns structured output', () async {
        final router = vendor.router();
        addTearDown(router.dispose);

        final capital = await router.generateObject(
          'What is the capital of France?',
          schema: const ResponseSchema(
            name: 'capital',
            schema: <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'city': <String, Object?>{'type': 'string'},
              },
              'required': <String>['city'],
            },
          ),
          decode: (json) => (json! as Map)['city'] as String,
        );

        expect(capital.toLowerCase(), contains('paris'));
      }, skip: vendor.skipReason);

      test('a bad key fails over as provider-scoped', () async {
        final router = RouterLlmProvider(
          providers: <ProviderConfig>[
            vendor.config.copyWith(apiKey: 'invalid-key'),
          ],
          connectivityChecker: const AssumeOnlineConnectivityChecker(),
        );
        addTearDown(router.dispose);

        await expectLater(
          router.generateStream('hi').join(),
          throwsA(isA<AllProvidersFailedException>()),
        );
        expect(router.lastAttemptLogs.single.statusCode, isNotNull);
      }, skip: vendor.skipReason);
    });
  }
}

class _Vendor {
  const _Vendor({required this.name, required this.key, required this.model});

  final String name;
  final String key;
  final String model;

  Object get skipReason => key.isEmpty ? 'no ${name.toUpperCase()} key' : false;

  ProviderConfig get config => ProviderConfig(
    name: name,
    apiKey: key,
    model: model,
    pricePerInputToken: 0,
    pricePerOutputToken: 0,
    // Room for thinking models to reason before answering.
    maxOutputTokens: 512,
    timeout: const Duration(seconds: 60),
  );

  RouterLlmProvider router() => RouterLlmProvider(
    providers: <ProviderConfig>[config],
    connectivityChecker: const AssumeOnlineConnectivityChecker(),
  );
}

/// A 16x16 solid red PNG.
ImageFileAttachment _redPixel() => ImageFileAttachment(
  name: 'red.png',
  mimeType: 'image/png',
  bytes: base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiG'
    'UQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII=',
  ),
);
