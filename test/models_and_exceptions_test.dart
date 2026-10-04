import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_llm_router/src/models/adapter_chunk.dart';
import 'package:flutter_llm_router/src/models/chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';

/// Message mapping, usage parsing, and exception contracts.
void main() {
  group('ChatTurn', () {
    test('maps a user turn onto OpenAI and Gemini roles', () {
      const turn = ChatTurn(role: ChatTurnRole.user, text: 'Hello');

      expect(turn.toOpenAiMessage(), <String, Object?>{
        'role': 'user',
        'content': 'Hello',
      });
      expect(turn.toGeminiContent(), <String, Object?>{
        'role': 'user',
        'parts': <Object?>[
          <String, Object?>{'text': 'Hello'},
        ],
      });
    });

    test('maps an assistant turn to Gemini model role', () {
      const turn = ChatTurn(role: ChatTurnRole.assistant, text: 'Hi');

      expect(turn.toOpenAiMessage()['role'], 'assistant');
      expect(turn.toOpenAiMessage()['content'], 'Hi');
      expect(turn.toGeminiContent()['role'], 'model');
    });

    test('keeps an empty body instead of inventing text', () {
      const turn = ChatTurn(role: ChatTurnRole.user, text: '');

      expect(turn.toOpenAiMessage()['content'], isEmpty);
      final parts = turn.toGeminiContent()['parts']! as List<Object?>;
      final part = parts.single as Map<String, Object?>;
      expect(part['text'], isEmpty);
    });
  });

  group('AdapterUsage.count', () {
    test('accepts non-negative ints and truncates fractional numbers', () {
      expect(AdapterUsage.count(0), 0);
      expect(AdapterUsage.count(12), 12);
      expect(AdapterUsage.count(9.9), 9);
      expect(AdapterUsage.count(0.0), 0);
    });

    test('rejects missing, negative, and non-numeric values', () {
      expect(AdapterUsage.count(null), isNull);
      expect(AdapterUsage.count(-1), isNull);
      expect(AdapterUsage.count(-0.1), isNull);
      expect(AdapterUsage.count('9'), isNull);
      expect(AdapterUsage.count(true), isNull);
    });

    test('constructor rejects a negative side and allows a missing side', () {
      const usage = AdapterUsage(inputTokens: 0);
      expect(usage.inputTokens, 0);
      expect(usage.outputTokens, isNull);

      expect(
        () => AdapterUsage(inputTokens: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => AdapterUsage(outputTokens: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('AttemptLog', () {
    test('success log leaves error and status empty', () {
      final timestamp = DateTime.utc(2026, 10, 1, 8, 30);
      final log = AttemptLog(
        providerName: 'gemini',
        model: 'gemini-2.0-flash',
        timestamp: timestamp,
        latencyMs: 0,
        isSuccess: true,
      );

      expect(log.error, isNull);
      expect(log.statusCode, isNull);
      expect(log.toString(), contains('isSuccess: true'));
      expect(log.toString(), contains('error: null'));
      expect(log.toString(), contains(timestamp.toIso8601String()));
    });
  });

  group('LlmRouterException', () {
    test('toString is the runtime type plus the message', () {
      const cause = FormatException('bad json');
      const retryable = RetryableLlmException(
        'slow down',
        statusCode: 429,
        cause: cause,
      );
      const terminal = TerminalLlmException('denied', statusCode: 401);

      expect(retryable.toString(), 'RetryableLlmException: slow down');
      expect(retryable.statusCode, 429);
      expect(retryable.cause, same(cause));
      expect(terminal.toString(), 'TerminalLlmException: denied');
      expect(terminal.cause, isNull);
    });

    test('AllProvidersFailedException can override the summary', () {
      final error = AllProvidersFailedException(
        const <AttemptLog>[],
        message: 'chain down',
      );

      expect(error.attempts, isEmpty);
      expect(error.message, 'chain down');
      expect(
        error.toString(),
        'AllProvidersFailedException: chain down attempts=0',
      );
      expect(() => error.attempts.clear(), throwsUnsupportedError);
    });

    test('default summary counts the attempts it stored', () {
      final error = AllProvidersFailedException(const <AttemptLog>[]);

      expect(error.message, 'All providers failed (0 attempts)');
      expect(error.toString(), contains('attempts=0'));
    });
  });
}
