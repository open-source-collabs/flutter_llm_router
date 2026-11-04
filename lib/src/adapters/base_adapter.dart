import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exceptions/router_exceptions.dart';
import '../models/adapter_chunk.dart';
import '../models/chat_turn.dart';
import '../models/provider_capabilities.dart';
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

  /// Attachment kinds this adapter can send, used when
  /// [ProviderConfig.capabilities] is null.
  ///
  /// Defaults to [ProviderCapabilities.all], so custom adapters are never
  /// skipped. Built-in adapters override it with what their vendor accepts.
  ProviderCapabilities get capabilities => ProviderCapabilities.all;

  /// Streams text and usage for [messages] using [config].
  ///
  /// [messages] is the conversation in order, one entry per turn, including
  /// each turn's [ChatTurn.attachments]. [ProviderConfig.settings] holds the
  /// system prompt and sampling settings, already merged with the router's
  /// defaults. Implementations call [postSse] and decode vendor payloads
  /// into [AdapterText], [AdapterUsage] when the provider reports counts,
  /// and [AdapterFinish] when it reports why it stopped. Cancelling the
  /// returned stream should stop the upstream request, which a stream
  /// derived from [postSse] does.
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  });

  /// POSTs [body] as JSON and yields each SSE `data:` payload.
  ///
  /// Payloads are the text after the `data:` prefix. Blank lines, comments,
  /// and the OpenAI `[DONE]` sentinel are skipped. [timeout] bounds the wait
  /// for response headers, and for the body of an error response, and
  /// defaults to 30 seconds. [idleTimeout] bounds the gap between two lines
  /// of the stream. [deadline] bounds the whole call. Null disables either.
  ///
  /// HTTP 429, 408, and 5xx responses throw [RetryableLlmException], with
  /// [RetryableLlmException.retryAfter] set from a `retry-after-ms` header or
  /// a `Retry-After` header given in seconds. Statuses that
  /// [isProviderScopedFailure] accepts throw
  /// [ProviderUnavailableLlmException]. Other non-success statuses, such as
  /// 400, throw [TerminalLlmException]. Timeouts and transport errors (socket
  /// drop, DNS failure, TLS failure, connection reset) are retryable. Each
  /// exception's [LlmRouterException.redactedMessage] leaves out the
  /// response body.
  ///
  /// Cancelling the returned stream, or any timeout, aborts the request.
  Stream<String> postSse({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    Duration timeout = const Duration(seconds: 30),
    Duration? idleTimeout,
    Duration? deadline,
  }) {
    final abort = Completer<void>();
    StreamSubscription<String>? payloads;
    Timer? deadlineTimer;
    late final StreamController<String> controller;

    void finish() {
      deadlineTimer?.cancel();
      if (!abort.isCompleted) abort.complete();
      final current = payloads;
      payloads = null;
      if (current != null) _ignoreErrors(current.cancel());
    }

    controller = StreamController<String>(
      onListen: () {
        if (deadline != null) {
          deadlineTimer = Timer(deadline, () {
            controller.addError(
              RetryableLlmException(
                'Request to ${url.host} exceeded its '
                '${deadline.inMilliseconds}ms deadline',
                cause: TimeoutException('Deadline exceeded', deadline),
              ),
            );
            finish();
            unawaited(controller.close());
          });
        }
        payloads =
            _ssePayloads(
              url: url,
              headers: headers,
              body: body,
              timeout: timeout,
              idleTimeout: idleTimeout,
              abortTrigger: abort.future,
            ).listen(
              controller.add,
              onError: controller.addError,
              onDone: () {
                finish();
                unawaited(controller.close());
              },
            );
      },
      onPause: () => payloads?.pause(),
      onResume: () => payloads?.resume(),
      onCancel: finish,
    );
    return controller.stream;
  }

  /// Whether a non-success [statusCode] means only this provider cannot
  /// serve the request, so the router should try the next one.
  ///
  /// The default accepts 401, 402, 403, and 404: a bad key, no credit, no
  /// access, or an unknown model. Adapters override this for providers that
  /// report those cases with another status. [body] is the error response.
  bool isProviderScopedFailure(int statusCode, String body) {
    return statusCode == 401 ||
        statusCode == 402 ||
        statusCode == 403 ||
        statusCode == 404;
  }

  /// Throws [RetryableLlmException] for an [error] object the provider sent
  /// inside a successful (HTTP 200) stream.
  ///
  /// Uses the error's `message` field when there is one. [statusCode] is the
  /// HTTP status the error stands for, when the vendor documents one, such
  /// as 529 for Anthropic's `overloaded_error`. It lets `RetryPolicy` retry.
  Never throwStreamError(Object? error, {int? statusCode}) {
    final detail = switch (error) {
      {'message': final String message} => message,
      final String message => message,
      _ => jsonEncode(error),
    };
    throw RetryableLlmException(
      'Provider reported an error mid-stream: ${_truncate(detail)}',
      statusCode: statusCode,
      redactedMessage: 'Provider reported an error mid-stream',
    );
  }

  /// Decodes a tool call's JSON [arguments] into an object.
  ///
  /// An empty string is an empty object. Malformed JSON and non-object
  /// values throw [RetryableLlmException], so the router can fail over.
  Map<String, Object?> decodeToolArguments(String arguments) {
    if (arguments.trim().isEmpty) return <String, Object?>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(arguments);
    } on FormatException catch (error) {
      throw RetryableLlmException(
        'Malformed tool call arguments',
        cause: error,
        redactedMessage: 'Malformed tool call arguments',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const RetryableLlmException(
        'Tool call arguments were not a JSON object',
      );
    }
    return decoded;
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

  Stream<String> _ssePayloads({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required Duration? idleTimeout,
    required Future<void> abortTrigger,
  }) async* {
    final request = http.AbortableRequest(
      'POST',
      url,
      abortTrigger: abortTrigger,
    )..headers.addAll(headers);
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
        redactedMessage: 'Connection to ${url.host} failed',
      );
    } on Exception catch (error) {
      throw RetryableLlmException(
        'Connection to ${url.host} failed: $error',
        cause: error,
        redactedMessage: 'Connection to ${url.host} failed',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final responseBody = await _readBody(response, timeout);
      _throwForStatus(response.statusCode, responseBody, response.headers);
    }

    var lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    if (idleTimeout != null) lines = lines.timeout(idleTimeout);

    try {
      await for (final line in lines) {
        final payload = _payloadFromSseLine(line);
        if (payload != null) yield payload;
      }
    } on http.ClientException catch (error) {
      throw RetryableLlmException(
        'Connection to ${url.host} dropped while reading SSE',
        statusCode: response.statusCode,
        cause: error,
      );
    } on TimeoutException catch (error) {
      throw RetryableLlmException(
        'Stream from ${url.host} was idle for '
        '${idleTimeout?.inMilliseconds}ms',
        statusCode: response.statusCode,
        cause: error,
      );
    } on FormatException catch (error) {
      throw RetryableLlmException(
        'SSE stream from ${url.host} was not valid UTF-8',
        statusCode: response.statusCode,
        cause: error,
      );
    } on Exception catch (error) {
      throw RetryableLlmException(
        'Connection to ${url.host} failed while reading SSE: $error',
        statusCode: response.statusCode,
        cause: error,
        redactedMessage: 'Connection to ${url.host} failed while reading SSE',
      );
    }
  }

  Future<String> _readBody(
    http.StreamedResponse response,
    Duration timeout,
  ) async {
    try {
      return await response.stream.bytesToString().timeout(timeout);
    } on Exception catch (error) {
      throw RetryableLlmException(
        'Connection dropped while reading the error response',
        statusCode: response.statusCode,
        cause: error,
      );
    }
  }

  Never _throwForStatus(
    int statusCode,
    String body,
    Map<String, String> headers,
  ) {
    final snippet = _truncate(body);
    final redacted = 'HTTP $statusCode';
    final message = snippet.isEmpty ? redacted : '$redacted: $snippet';
    if (statusCode == 429 ||
        statusCode == 408 ||
        (statusCode >= 500 && statusCode <= 599)) {
      throw RetryableLlmException(
        message,
        statusCode: statusCode,
        redactedMessage: redacted,
        retryAfter: _retryAfter(headers),
      );
    }
    if (isProviderScopedFailure(statusCode, body)) {
      throw ProviderUnavailableLlmException(
        message,
        statusCode: statusCode,
        redactedMessage: redacted,
      );
    }
    throw TerminalLlmException(
      message,
      statusCode: statusCode,
      redactedMessage: redacted,
    );
  }
}

/// Reads `retry-after-ms`, then `Retry-After` in seconds. HTTP-date values
/// are ignored.
Duration? _retryAfter(Map<String, String> headers) {
  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value.trim();
    }
    return null;
  }

  final millis = num.tryParse(header('retry-after-ms') ?? '');
  if (millis != null && millis >= 0) {
    return Duration(milliseconds: millis.round());
  }
  final seconds = num.tryParse(header('retry-after') ?? '');
  if (seconds != null && seconds >= 0) {
    return Duration(milliseconds: (seconds * 1000).round());
  }
  return null;
}

String _truncate(String text) =>
    text.length > 500 ? text.substring(0, 500) : text;

void _ignoreErrors(Future<void> future) {
  unawaited(future.then<void>((_) {}, onError: (Object _) {}));
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
  String? baseUrl,
  String defaultBase,
  String relativePath,
) {
  final root = baseUrl ?? defaultBase;
  final normalized = root.endsWith('/') ? root : '$root/';
  return Uri.parse(normalized).resolve(relativePath);
}
