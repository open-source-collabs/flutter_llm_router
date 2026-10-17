import 'dart:async';

import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('HttpConnectivityChecker', () {
    test('defaults to Google generate_204', () {
      expect(
        HttpConnectivityChecker().probeUrl.toString(),
        'https://www.google.com/generate_204',
      );
    });

    test('reports online for a 204 response', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('', 204);
      });
      addTearDown(client.close);

      final checker = HttpConnectivityChecker(client: client);

      expect(await checker.hasInternet(), isTrue);
      expect(requests.single.method, 'HEAD');
      expect(requests.single.url, HttpConnectivityChecker.defaultProbeUrl);
    });

    test('reports online for any HTTP status', () async {
      final client = MockClient((request) async => http.Response('', 500));
      addTearDown(client.close);

      final checker = HttpConnectivityChecker(client: client);

      expect(await checker.hasInternet(), isTrue);
    });

    test('probes a custom URL', () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        return http.Response('', 200);
      });
      addTearDown(client.close);
      final probeUrl = Uri.parse('https://example.com/ping');

      final checker = HttpConnectivityChecker(probeUrl: probeUrl, client: client);

      expect(await checker.hasInternet(), isTrue);
      expect(requests, [probeUrl]);
    });

    test('reports offline for a connection error', () async {
      final client = MockClient(
        (request) async => throw http.ClientException('Failed host lookup'),
      );
      addTearDown(client.close);

      final checker = HttpConnectivityChecker(client: client);

      expect(await checker.hasInternet(), isFalse);
    });

    test('reports offline when no response arrives in time', () async {
      final client = MockClient(
        (request) => Completer<http.Response>().future,
      );
      addTearDown(client.close);

      final checker = HttpConnectivityChecker(
        client: client,
        timeout: const Duration(milliseconds: 20),
      );

      expect(await checker.hasInternet(), isFalse);
    });
  });
}
