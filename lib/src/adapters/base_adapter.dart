import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exceptions/router_exceptions.dart';
import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/provider_config.dart';

/// Shared HTTP engine for vendor streaming adapters.
///
/// Uses `package:http` only. Nothing in this type imports `dart:io`, so the
/// same code compiles for Flutter web.
abstract class BaseLlmAdapter {
  /// Creates an adapter.
  ///
  /// When [client] is omitted, the adapter owns an [http.Client] and [close]
  /// releases it. When [client] is provided, the caller keeps ownership.
  BaseLlmAdapter({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// Streams text and usage for [messages] using [config].
  ///
  /// [messages] is the conversation in order, one entry per turn.
  /// Implementations call [postSse] and decode vendor payloads into
  /// [AdapterText] and, when the provider reports counts, [AdapterUsage].
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  });

  /// POSTs [body] as JSON and yields each SSE `data:` payload.
  ///
  /// Payloads are the text after the `data:` prefix. Blank lines, comments,
  /// and the OpenAI `[DONE]` sentinel are skipped. [timeout] bounds how long
  /// the adapter waits for response headers and defaults to 30 seconds.
  ///
  /// HTTP 429, 408, and 5xx responses throw [RetryableLlmException]. Other
  /// non-success statuses, including 400, 401, and 403, throw
  /// [TerminalLlmException]. A timeout or [http.ClientException] (socket
  /// drop, DNS failure, connection reset) is retryable.
  Stream<String> postSse({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    Duration timeout = const Duration(seconds: 30),
  }) async* {
    final request = http.Request('POST', url)..headers.addAll(headers);
    request.body = jsonEncode(body);

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException catch (error) {
      throw RetryableLlmException(
        'Request to ${url.host} timed out after ${timeout.inMilliseconds}ms',
        cause: error,
      );
    } on http.ClientException catch (error) {
      throw RetryableLlmException(
        'Connection to ${url.host} failed: ${error.message}',
        cause: error,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final responseBody = await _readBody(response);
      _throwForStatus(response.statusCode, responseBody);
    }

    try {
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final payload = _payloadFromSseLine(line);
        if (payload != null) yield payload;
      }
    } on http.ClientException catch (error) {
      throw RetryableLlmException(
        'Connection to ${url.host} dropped while reading SSE',
        statusCode: response.statusCode,
        cause: error,
      );
    } on FormatException catch (error) {
      throw RetryableLlmException(
        'SSE stream from ${url.host} was not valid UTF-8',
        statusCode: response.statusCode,
        cause: error,
      );
    }
  }

  /// Decodes one SSE data payload into a JSON object.
  ///
  /// Malformed JSON and non-object payloads throw [RetryableLlmException]
  /// so the router can fail over.
  Map<String, dynamic> decodeSseObject(String payload) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException catch (error) {
      throw RetryableLlmException('Malformed SSE JSON', cause: error);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const RetryableLlmException('SSE JSON payload was not an object');
    }
    return decoded;
  }

  /// Releases the [http.Client] created by this adapter.
  ///
  /// Injected clients are left open.
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<String> _readBody(http.StreamedResponse response) async {
    try {
      return await response.stream.bytesToString();
    } on http.ClientException catch (error) {
      throw RetryableLlmException(
        'Connection dropped while reading the error response',
        statusCode: response.statusCode,
        cause: error,
      );
    }
  }

  Never _throwForStatus(int statusCode, String body) {
    final snippet = body.length > 500 ? body.substring(0, 500) : body;
    final message =
        snippet.isEmpty ? 'HTTP $statusCode' : 'HTTP $statusCode: $snippet';
    if (statusCode == 429 ||
        statusCode == 408 ||
        (statusCode >= 500 && statusCode <= 599)) {
      throw RetryableLlmException(message, statusCode: statusCode);
    }
    throw TerminalLlmException(message, statusCode: statusCode);
  }
}

/// Returns the JSON after an SSE `data:` prefix, or null when [line] carries
/// no payload.
String? _payloadFromSseLine(String line) {
  if (line.isEmpty || line.startsWith(':')) return null;
  if (!line.startsWith('data:')) return null;
  final data = line.substring(5).trim();
  if (data.isEmpty || data == '[DONE]') return null;
  return data;
}

/// Joins [baseUrl] (or [defaultBase]) with [relativePath].
Uri resolveProviderUrl(
    String? baseUrl, String defaultBase, String relativePath) {
  final root = baseUrl ?? defaultBase;
  final normalized = root.endsWith('/') ? root : '$root/';
  return Uri.parse(normalized).resolve(relativePath);
}
