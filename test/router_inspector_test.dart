import 'package:flutter/material.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('RouterInspector shows attempts, health, and spend live', (
    tester,
  ) async {
    final client = MockClient((request) async => http.Response('', 200));
    final router = RouterLlmProvider(
      providers: const <ProviderConfig>[
        ProviderConfig(
          name: 'alpha',
          apiKey: 'k',
          model: 'a1',
          pricePerInputToken: 0.5,
          pricePerOutputToken: 0.5,
        ),
        ProviderConfig(
          name: 'beta',
          apiKey: 'k',
          model: 'b1',
          pricePerInputToken: 0.5,
          pricePerOutputToken: 0.5,
        ),
      ],
      customAdapters: <String, BaseLlmAdapter>{
        'alpha': _Scripted(
          client,
          () => Stream<AdapterChunk>.error(
            const RetryableLlmException('HTTP 503', statusCode: 503),
          ),
        ),
        'beta': _Scripted(
          client,
          () => Stream<AdapterChunk>.fromIterable(const <AdapterChunk>[
            AdapterText('ok'),
            AdapterUsage(inputTokens: 2, outputTokens: 2),
          ]),
        ),
      },
      connectivityChecker: const AssumeOnlineConnectivityChecker(),
    );
    addTearDown(() {
      router.dispose();
      client.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: RouterInspector(router: router)),
        ),
      ),
    );
    expect(find.text('No requests yet.'), findsOneWidget);

    await tester.runAsync(() => router.generateStream('hi').drain<void>());
    await tester.pump();

    expect(find.text('alpha · a1'), findsOneWidget);
    expect(find.text('beta · b1'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsWidgets);
    expect(find.textContaining('\$2.000000 spent'), findsOneWidget);
    expect(find.byType(Chip), findsNWidgets(2));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.error), findsOneWidget);
  });
}

class _Scripted extends BaseLlmAdapter {
  _Scripted(http.Client client, this._stream) : super(client: client);

  final Stream<AdapterChunk> Function() _stream;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) => _stream();
}
