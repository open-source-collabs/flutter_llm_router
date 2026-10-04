import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';

import 'adapters/anthropic_adapter.dart';
import 'adapters/base_adapter.dart';
import 'adapters/gemini_adapter.dart';
import 'adapters/openai_adapter.dart';
import 'adapters/openrouter_adapter.dart';
import 'exceptions/router_exceptions.dart';
import 'models/adapter_chunk.dart';
import 'models/attempt_log.dart';
import 'models/chat_turn.dart';
import 'models/provider_config.dart';
import 'tracking/cost_tracker.dart';

/// An [LlmProvider] that fails over across [providers] in list order.
///
/// [generateStream] and [sendMessageStream] share one routing loop. A
/// [RetryableLlmException] that arrives before any text is yielded is logged
/// and the next provider is tried. A [TerminalLlmException] is logged and
/// rethrown. When every provider fails, the loop throws
/// [AllProvidersFailedException].
///
/// Built-in adapter names are `openai`, `anthropic`, `gemini`, and
/// `openrouter` (case-insensitive). `openrouter` speaks the OpenAI
/// chat-completions protocol at `https://openrouter.ai/api/v1`, so several
/// [ProviderConfig] entries can share that name and differ only by [ProviderConfig.model].
/// [customAdapters] replaces that lookup for tests and for providers the
/// router does not know.
///
/// Token counts passed to [CostTracker.recordUsage] prefer counts the
/// provider reported on the stream. A missing side falls back to
/// `(text.length + 3) ~/ 4`, which is the character length divided by 4,
/// rounded up. An empty string is zero tokens.
class RouterLlmProvider extends LlmProvider with ChangeNotifier {
  /// Creates a router over [providers], in failover order.
  ///
  /// [providers] must not be empty. [costTracker] defaults to a new
  /// [CostTracker] that this router disposes. Pass an existing tracker to
  /// keep ownership in the caller. [customAdapters] is keyed by
  /// [ProviderConfig.name]; injected adapters are not closed by [dispose].
  /// [history] seeds the conversation shown by `LlmChatView`.
  RouterLlmProvider({
    required List<ProviderConfig> providers,
    CostTracker? costTracker,
    Map<String, BaseLlmAdapter>? customAdapters,
    Iterable<ChatMessage>? history,
  })  : assert(providers.isNotEmpty, 'providers must not be empty'),
        providers = List<ProviderConfig>.unmodifiable(providers),
        _ownsCostTracker = costTracker == null,
        costTracker = costTracker ?? CostTracker(),
        _customAdapters = Map<String, BaseLlmAdapter>.unmodifiable(
          customAdapters ?? const <String, BaseLlmAdapter>{},
        ),
        _history = List<ChatMessage>.from(history ?? const <ChatMessage>[]);

  /// Upstream providers, in the order failover should try them.
  final List<ProviderConfig> providers;

  /// Accumulated token usage and estimated spend.
  final CostTracker costTracker;

  final bool _ownsCostTracker;
  final Map<String, BaseLlmAdapter> _customAdapters;
  final Map<String, BaseLlmAdapter> _ownedAdapters = <String, BaseLlmAdapter>{};
  final List<ChatMessage> _history;
  final List<AttemptLog> _lastAttemptLogs = <AttemptLog>[];

  /// Attempt records from the most recent [generateStream] or
  /// [sendMessageStream] call, in provider order.
  List<AttemptLog> get lastAttemptLogs =>
      List<AttemptLog>.unmodifiable(_lastAttemptLogs);

  @override
  Iterable<ChatMessage> get history => List<ChatMessage>.unmodifiable(_history);

  @override
  set history(Iterable<ChatMessage> history) {
    _history
      ..clear()
      ..addAll(history);
    notifyListeners();
  }

  @override
  Stream<String> generateStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) {
    return _route(<ChatTurn>[
      ChatTurn(
        role: ChatTurnRole.user,
        text: _composePrompt(prompt, attachments),
      ),
    ]);
  }

  @override
  Stream<String> sendMessageStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) async* {
    final userMessage = ChatMessage.user(prompt, attachments);
    final llmMessage = ChatMessage.llm();
    _history.addAll([userMessage, llmMessage]);
    notifyListeners();
    try {
      await for (final chunk in _route(_historyTurns())) {
        llmMessage.append(chunk);
        yield chunk;
      }
    } finally {
      notifyListeners();
    }
  }

  @override
  Future<List<double>> getDocumentEmbedding(String document) {
    throw UnimplementedError(
      'RouterLlmProvider.getDocumentEmbedding is not implemented '
      '(${document.length} characters).',
    );
  }

  @override
  Future<List<double>> getQueryEmbedding(String query) {
    throw UnimplementedError(
      'RouterLlmProvider.getQueryEmbedding is not implemented '
      '(${query.length} characters).',
    );
  }

  /// Closes adapters this router constructed and, when this router created
  /// [costTracker], disposes that tracker.
  ///
  /// Adapters supplied through [customAdapters] stay open.
  @override
  void dispose() {
    for (final adapter in _ownedAdapters.values) {
      adapter.close();
    }
    _ownedAdapters.clear();
    if (_ownsCostTracker) {
      costTracker.dispose();
    }
    super.dispose();
  }

  Stream<String> _route(List<ChatTurn> messages) async* {
    final logs = <AttemptLog>[];
    _replaceLogs(logs);

    for (final config in providers) {
      final stopwatch = Stopwatch()..start();
      var emitted = false;
      try {
        final adapter = _adapterFor(config);
        final iterator = StreamIterator<AdapterChunk>(
          adapter.streamCompletion(config: config, messages: messages),
        );
        final output = StringBuffer();
        int? reportedInput;
        int? reportedOutput;
        try {
          while (await iterator.moveNext()) {
            switch (iterator.current) {
              case AdapterText(:final text):
                emitted = true;
                output.write(text);
                yield text;
              case AdapterUsage(:final inputTokens, :final outputTokens):
                if (inputTokens != null) reportedInput = inputTokens;
                if (outputTokens != null) reportedOutput = outputTokens;
            }
          }
        } finally {
          await iterator.cancel();
        }
        stopwatch.stop();
        logs.add(_log(config: config, stopwatch: stopwatch, isSuccess: true));
        _replaceLogs(logs);
        costTracker.recordUsage(
          config: config,
          inputTokens: reportedInput ?? _estimateTokens(_turnText(messages)),
          outputTokens: reportedOutput ?? _estimateTokens(output.toString()),
        );
        return;
      } on RetryableLlmException catch (error) {
        stopwatch.stop();
        logs.add(
          _log(
            config: config,
            stopwatch: stopwatch,
            isSuccess: false,
            error: error,
          ),
        );
        _replaceLogs(logs);
        if (emitted) rethrow;
      } on TerminalLlmException catch (error) {
        stopwatch.stop();
        logs.add(
          _log(
            config: config,
            stopwatch: stopwatch,
            isSuccess: false,
            error: error,
          ),
        );
        _replaceLogs(logs);
        rethrow;
      }
    }

    throw AllProvidersFailedException(logs);
  }

  BaseLlmAdapter _adapterFor(ProviderConfig config) {
    final custom = _customAdapters[config.name];
    if (custom != null) return custom;

    final key = config.name.toLowerCase();
    final existing = _ownedAdapters[key];
    if (existing != null) return existing;

    final created = switch (key) {
      'openai' => OpenAiAdapter(),
      'anthropic' => AnthropicAdapter(),
      'gemini' => GeminiAdapter(),
      'openrouter' => OpenRouterAdapter(),
      _ => null,
    };
    if (created == null) {
      throw TerminalLlmException(
        'No adapter registered for provider "${config.name}". '
        'Use openai, anthropic, gemini, openrouter, or customAdapters.',
      );
    }
    _ownedAdapters[key] = created;
    return created;
  }

  void _replaceLogs(List<AttemptLog> logs) {
    _lastAttemptLogs
      ..clear()
      ..addAll(logs);
  }

  AttemptLog _log({
    required ProviderConfig config,
    required Stopwatch stopwatch,
    required bool isSuccess,
    LlmRouterException? error,
  }) {
    return AttemptLog(
      providerName: config.name,
      model: config.model,
      timestamp: DateTime.now(),
      latencyMs: stopwatch.elapsedMilliseconds,
      isSuccess: isSuccess,
      error: error?.message,
      statusCode: error?.statusCode,
    );
  }

  String _composePrompt(String prompt, Iterable<Attachment> attachments) {
    if (attachments.isEmpty) return prompt;
    final notes =
        attachments.map((attachment) => attachment.toString()).join('\n');
    return '$prompt\n\n$notes';
  }

  List<ChatTurn> _historyTurns() {
    final turns = <ChatTurn>[];
    for (final message in _history) {
      final text = message.text?.trim() ?? '';
      final notes =
          message.attachments.map((attachment) => attachment.toString());
      final body = <String>[
        if (text.isNotEmpty) text,
        if (notes.isNotEmpty) notes.join('\n'),
      ].join('\n\n');
      if (body.isEmpty) continue;
      turns.add(
        ChatTurn(
          role: message.origin.isUser
              ? ChatTurnRole.user
              : ChatTurnRole.assistant,
          text: body,
        ),
      );
    }
    return turns;
  }
}

String _turnText(List<ChatTurn> messages) {
  return messages.map((message) => message.text).join('\n');
}

int _estimateTokens(String text) => (text.length + 3) ~/ 4;
