import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
// The toolkit's public barrel also exports FirebaseProvider, which pulls in
// firebase_ai -> web_socket_channel/io.dart -> dart:io and makes this package
// WASM-incompatible on pub.dev. Import only the provider interfaces instead.
// ignore_for_file: implementation_imports
import 'package:flutter_ai_toolkit/src/providers/interface/attachments.dart';
import 'package:flutter_ai_toolkit/src/providers/interface/chat_message.dart';
import 'package:flutter_ai_toolkit/src/providers/interface/llm_provider.dart';

import 'adapters/anthropic_adapter.dart';
import 'adapters/azure_openai_adapter.dart';
import 'adapters/base_adapter.dart';
import 'adapters/gemini_adapter.dart';
import 'adapters/openai_adapter.dart';
import 'adapters/openrouter_adapter.dart';
import 'connectivity/connectivity_checker.dart';
import 'exceptions/router_exceptions.dart';
import 'models/adapter_chunk.dart';
import 'models/attempt_log.dart';
import 'models/chat_turn.dart';
import 'models/finish_reason.dart';
import 'models/generation_settings.dart';
import 'models/provider_capabilities.dart';
import 'models/provider_config.dart';
import 'models/response_schema.dart';
import 'models/tool.dart';
import 'models/turn_attachment.dart';
import 'routing/budget_policy.dart';
import 'routing/key_pool.dart';
import 'routing/provider_health.dart';
import 'routing/response_cache.dart';
import 'routing/retry_policy.dart';
import 'routing/router_event.dart';
import 'routing/routing_strategy.dart';
import 'tracking/cost_tracker.dart';

/// An [LlmProvider] that fails over across [providers].
///
/// [generateStream] and [sendMessageStream] share one routing loop. A
/// [RetryableLlmException] that arrives before any text is yielded is logged
/// and the next provider is tried. That includes
/// [ProviderUnavailableLlmException] (bad key, no credit, unknown model), a
/// reply with no text, and any other [Exception] from an adapter. A
/// [TerminalLlmException] is logged and rethrown. A failure after text was
/// yielded is rethrown, because the reply is already partly shown. When
/// every provider fails, the loop throws [AllProvidersFailedException].
///
/// Each request goes through these steps, all logged in [lastAttemptLogs]
/// and reported on [events]:
///
/// 1. [responseCache], when set, may answer without a provider call.
/// 2. [routingStrategy] orders [providers]. The default keeps list order.
/// 3. A provider is skipped when it cannot take the conversation's
///    attachments (see [ProviderCapabilities]), when [budget] blocks it, or
///    when its circuit is open under [circuitBreaker].
/// 4. A provider with several [ProviderConfig.apiKeys] moves to its next key
///    when a key is rate limited or rejected, as set by [keyPool].
/// 5. A transient failure is retried on the same provider under
///    [retryPolicy] before failing over. The default does not retry.
///
/// When a provider fails with a connection error or timeout, the router asks
/// [connectivityChecker] whether the device is online, at most once per
/// request. If it is offline, the loop stops with
/// [NoInternetConnectionException] instead of trying the remaining
/// providers. If it is online, failover continues as usual. Providers whose
/// [ProviderConfig.baseUrl] is a local or private address do not trigger
/// the check.
///
/// Cancelling the returned stream stops the chain and aborts the pending
/// request. [dispose] cancels every active request.
///
/// Built-in adapter names are `openai`, `anthropic`, `gemini`,
/// `openrouter`, and `azure-openai` (case-insensitive), chosen by
/// [ProviderConfig.adapter] or else [ProviderConfig.name]. `openrouter`
/// speaks the OpenAI chat-completions protocol at
/// `https://openrouter.ai/api/v1`, so several [ProviderConfig] entries can
/// share that name and differ only by [ProviderConfig.model].
/// [customAdapters] is looked up by [ProviderConfig.name] first, for tests
/// and for providers the router does not know.
///
/// Token counts passed to [CostTracker.recordUsage] prefer counts the
/// provider reported on the stream. A missing side falls back to
/// `(text.length + 3) ~/ 4`, which is the character length divided by 4,
/// rounded up. An empty string is zero tokens. Successful, cancelled, and
/// partly streamed attempts are recorded, because providers bill for them.
/// A failed attempt with no text and no reported usage is not.
class RouterLlmProvider extends LlmProvider with ChangeNotifier {
  /// Creates a router over [providers].
  ///
  /// [providers] must not be empty, or an [ArgumentError] is thrown.
  /// [costTracker] defaults to a new [CostTracker] that this router
  /// disposes. Pass an existing tracker to keep ownership in the caller.
  /// [customAdapters] is keyed by [ProviderConfig.name]; injected adapters
  /// are not closed by [dispose]. [history] seeds the conversation shown by
  /// `LlmChatView`. [connectivityChecker] defaults to an
  /// [HttpConnectivityChecker]. Pass [AssumeOnlineConnectivityChecker] to
  /// turn the offline check off.
  ///
  /// [settings], [retryPolicy], [circuitBreaker], [routingStrategy],
  /// [budget], and [responseCache] are optional; the defaults change
  /// nothing about plain failover.
  RouterLlmProvider({
    required List<ProviderConfig> providers,
    CostTracker? costTracker,
    Map<String, BaseLlmAdapter>? customAdapters,
    Iterable<ChatMessage>? history,
    ConnectivityChecker? connectivityChecker,
    this.settings = const GenerationSettings(),
    this.retryPolicy = RetryPolicy.none,
    this.circuitBreaker,
    this.routingStrategy = const PriorityRoutingStrategy(),
    this.budget,
    this.responseCache,
    this.keyPool = const KeyPoolPolicy(),
    this.redactEventErrors = true,
    List<RouterTool> tools = const <RouterTool>[],
    this.maxToolRounds = 8,
  }) : assert(maxToolRounds > 0),
       providers = _checkProviders(providers),
       tools = _checkTools(tools),
       connectivityChecker = connectivityChecker ?? HttpConnectivityChecker(),
       _ownsCostTracker = costTracker == null,
       costTracker = costTracker ?? CostTracker(),
       _customAdapters = Map<String, BaseLlmAdapter>.unmodifiable(
         customAdapters ?? const <String, BaseLlmAdapter>{},
       ),
       _history = List<ChatMessage>.from(history ?? const <ChatMessage>[]) {
    _health = ProviderHealthRegistry(
      policy: circuitBreaker,
      onStateChange: (providerId, from, to) => _emit(
        CircuitStateChanged(
          _eventRequestId,
          providerId: providerId,
          from: from,
          to: to,
        ),
      ),
    );
  }

  /// Upstream providers, in the order failover should try them.
  final List<ProviderConfig> providers;

  /// Accumulated token usage and estimated spend.
  final CostTracker costTracker;

  /// Decides whether a connection failure means the device is offline.
  final ConnectivityChecker connectivityChecker;

  /// System prompt and sampling settings sent with every request.
  ///
  /// [ProviderConfig.settings] overrides each field per provider. Changes
  /// apply to the next request.
  GenerationSettings settings;

  /// Same-provider retries before failing over. Defaults to
  /// [RetryPolicy.none].
  final RetryPolicy retryPolicy;

  /// Skips providers that keep failing, or null to always call them.
  final CircuitBreakerPolicy? circuitBreaker;

  /// Orders [providers] for each request. Defaults to
  /// [PriorityRoutingStrategy].
  final RoutingStrategy routingStrategy;

  /// Spending limits, or null for none.
  final BudgetPolicy? budget;

  /// Answers repeated requests without a provider call, or null for none.
  final ResponseCache? responseCache;

  /// How providers with several [ProviderConfig.apiKeys] rotate and bench
  /// keys. Providers with a single key ignore it.
  final KeyPoolPolicy keyPool;

  /// Whether [events] leave provider response text out of error messages.
  ///
  /// Defaults to true, because error bodies can echo the prompt. Event logs
  /// then carry [LlmRouterException.redactedMessage]. [lastAttemptLogs] and
  /// thrown exceptions always keep the full message.
  final bool redactEventErrors;

  /// Tools the model may call during a request.
  ///
  /// When a model calls one, the router runs its handler, sends the result
  /// back to the same provider, and continues until the model replies
  /// without a tool call, for at most [maxToolRounds] rounds. Failover is
  /// allowed only before the first tool runs, so a tool never runs twice
  /// for one request because of a provider failure. Providers whose
  /// [ProviderCapabilities.tools] is false are skipped.
  final List<RouterTool> tools;

  /// Most tool rounds in one request before it fails with
  /// [TerminalLlmException]. Defaults to 8.
  final int maxToolRounds;

  final bool _ownsCostTracker;
  final Map<String, BaseLlmAdapter> _customAdapters;
  final Map<String, BaseLlmAdapter> _ownedAdapters = <String, BaseLlmAdapter>{};
  late final Map<String, RouterTool> _toolsByName = <String, RouterTool>{
    for (final tool in tools) tool.name: tool,
  };
  final List<ChatMessage> _history;
  final ValueNotifier<List<AttemptLog>> _attemptLogs =
      ValueNotifier<List<AttemptLog>>(const <AttemptLog>[]);
  final StreamController<RouterEvent> _events =
      StreamController<RouterEvent>.broadcast();
  late final ProviderHealthRegistry _health;
  late final KeyPoolRegistry _keys = KeyPoolRegistry(keyPool);
  final Set<_RouteRequest> _activeRequests = <_RouteRequest>{};
  final Set<ChatMessage> _unsentMessages = Set<ChatMessage>.identity();
  int _requestCount = 0;
  int _latestRequest = 0;
  int _eventRequestId = 0;
  bool _disposed = false;

  /// Attempt records from the most recent [generateStream] or
  /// [sendMessageStream] call, in the order they happened.
  List<AttemptLog> get lastAttemptLogs => _attemptLogs.value;

  /// Listenable version of [lastAttemptLogs].
  ///
  /// Notifies as each attempt of the most recent call finishes. An older
  /// call that is still running does not overwrite a newer one.
  ValueListenable<List<AttemptLog>> get attemptLogs => _attemptLogs;

  /// Health of each provider called so far, keyed by [ProviderConfig.id].
  ///
  /// Tracks circuit state, success and failure counts, and average time to
  /// first token, which [LowestLatencyRoutingStrategy] uses.
  ValueListenable<Map<String, ProviderHealth>> get providerHealth =>
      _health.listenable;

  /// Broadcast stream of what the router does, for logging and tracing.
  ///
  /// Events are delivered asynchronously. The stream closes on [dispose].
  Stream<RouterEvent> get events => _events.stream;

  /// Closes every circuit, so providers skipped by [circuitBreaker] are
  /// called again on the next request.
  void resetCircuits() {
    _eventRequestId = 0;
    _health.resetCircuits();
  }

  @override
  Iterable<ChatMessage> get history => List<ChatMessage>.unmodifiable(_history);

  @override
  set history(Iterable<ChatMessage> history) {
    _history
      ..clear()
      ..addAll(history);
    _unsentMessages.retainAll(_history);
    notifyListeners();
  }

  /// Streams a reply to [prompt] without using or changing [history].
  ///
  /// [attachments] are sent to providers that accept them; see
  /// [ProviderCapabilities].
  @override
  Stream<String> generateStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) {
    return _route(<ChatTurn>[
      ChatTurn(
        role: ChatTurnRole.user,
        text: prompt,
        attachments: _turnAttachments(attachments),
      ),
    ]);
  }

  /// Asks for a reply that matches [schema] and returns it decoded.
  ///
  /// Every provider is told the schema in its system prompt, and
  /// OpenAI-compatible APIs and Gemini also use their JSON modes. The reply
  /// is parsed as JSON (a surrounding code fence is tolerated) and passed to
  /// [decode]. When parsing or [decode] fails, the attempt is logged with
  /// [InvalidStructuredOutputException] and the router fails over. Nothing
  /// is streamed, and [history] is not used or changed. [tools] may run
  /// before the final reply.
  ///
  /// Throws what [generateStream] would, for example
  /// [AllProvidersFailedException] when no provider produced a valid reply.
  Future<T> generateObject<T>(
    String prompt, {
    required ResponseSchema schema,
    required T Function(Object? json) decode,
    Iterable<Attachment> attachments = const [],
  }) async {
    late T value;
    await _route(
      <ChatTurn>[
        ChatTurn(
          role: ChatTurnRole.user,
          text: prompt,
          attachments: _turnAttachments(attachments),
        ),
      ],
      schema: schema,
      validate: (text) => value = _decodeStructured(text, decode),
    ).drain<void>();
    return value;
  }

  /// Appends the prompt and the reply to [history] and streams the reply.
  ///
  /// When the send fails or is cancelled before any text arrives, both
  /// messages stay in [history] for display but are not sent to providers
  /// with later prompts.
  @override
  Stream<String> sendMessageStream(
    String prompt, {
    Iterable<Attachment> attachments = const [],
  }) async* {
    final userMessage = ChatMessage.user(prompt, attachments);
    final llmMessage = ChatMessage.llm();
    _history.addAll([userMessage, llmMessage]);
    notifyListeners();
    var completed = false;
    try {
      yield* _route(_historyTurns()).map((chunk) {
        llmMessage.append(chunk);
        return chunk;
      });
      completed = true;
    } finally {
      if (!completed && (llmMessage.text ?? '').isEmpty) {
        _unsentMessages
          ..add(userMessage)
          ..add(llmMessage);
      }
      if (!_disposed) notifyListeners();
    }
  }

  /// Embeddings are not supported by [RouterLlmProvider]; always throws
  /// [UnimplementedError].
  @Deprecated('Embeddings are not supported. Removed in 2.0.0.')
  Future<List<double>> getDocumentEmbedding(String document) {
    throw UnimplementedError(
      'RouterLlmProvider.getDocumentEmbedding is not implemented '
      '(${document.length} characters).',
    );
  }

  /// Embeddings are not supported by [RouterLlmProvider]; always throws
  /// [UnimplementedError].
  @Deprecated('Embeddings are not supported. Removed in 2.0.0.')
  Future<List<double>> getQueryEmbedding(String query) {
    throw UnimplementedError(
      'RouterLlmProvider.getQueryEmbedding is not implemented '
      '(${query.length} characters).',
    );
  }

  /// Cancels active requests, closes adapters this router constructed and,
  /// when this router created [costTracker], disposes that tracker. Closes
  /// [events].
  ///
  /// Adapters supplied through [customAdapters] stay open. Calling [dispose]
  /// again does nothing.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in List<_RouteRequest>.of(_activeRequests)) {
      request.cancel();
    }
    for (final adapter in _ownedAdapters.values) {
      adapter.close();
    }
    _ownedAdapters.clear();
    if (_ownsCostTracker) {
      costTracker.dispose();
    }
    _attemptLogs.dispose();
    _health.dispose();
    unawaited(_events.close());
    super.dispose();
  }

  Stream<String> _route(
    List<ChatTurn> messages, {
    ResponseSchema? schema,
    void Function(String text)? validate,
  }) {
    final request = _RouteRequest(schema: schema, validate: validate);
    final output = StreamController<String>();
    output
      ..onListen = () {
        if (_disposed) {
          unawaited(output.close());
          return;
        }
        request.id = ++_requestCount;
        _latestRequest = request.id;
        _activeRequests.add(request);
        unawaited(
          _run(messages, request, output).whenComplete(() {
            _activeRequests.remove(request);
            unawaited(output.close());
          }),
        );
      }
      ..onCancel = request.cancel;
    return output.stream;
  }

  Future<void> _run(
    List<ChatTurn> messages,
    _RouteRequest request,
    StreamController<String> output,
  ) async {
    final logs = <AttemptLog>[];
    _publishLogs(request, logs);
    final stopwatch = Stopwatch()..start();
    try {
      await _execute(messages, request, output, logs);
      _emit(
        RequestFinished(
          request.id,
          outcome: request.isCancelled
              ? RequestOutcome.cancelled
              : RequestOutcome.succeeded,
          latency: stopwatch.elapsed,
        ),
      );
    } on Object catch (error, stackTrace) {
      _emit(
        RequestFinished(
          request.id,
          outcome: RequestOutcome.failed,
          latency: stopwatch.elapsed,
          errorType: error.runtimeType.toString(),
          errorMessage: !redactEventErrors
              ? error.toString()
              : error is LlmRouterException
              ? error.redactedMessage
              : error.runtimeType.toString(),
        ),
      );
      output.addError(error, stackTrace);
    }
  }

  /// Routes one request. Returns on success or cancellation and throws the
  /// error the caller should see.
  Future<void> _execute(
    List<ChatTurn> messages,
    _RouteRequest request,
    StreamController<String> output,
    List<AttemptLog> logs,
  ) async {
    final requestSettings = GenerationSettings(
      tools: tools.isEmpty ? null : tools,
      responseSchema: request.schema,
    ).withDefaults(settings);
    final cache = responseCache;
    final cacheKey = cache == null
        ? null
        : _cacheKey(messages, requestSettings);
    if (cache != null && cacheKey != null) {
      final cached = await _readCache(cache, cacheKey);
      if (request.isCancelled) return;
      if (cached != null && _passes(request, cached.text)) {
        output.add(cached.text);
        _addLog(
          request,
          logs,
          AttemptLog(
            providerName: cached.providerName,
            model: cached.model,
            timestamp: DateTime.now(),
            latencyMs: 0,
            isSuccess: true,
            fromCache: true,
          ),
        );
        return;
      }
    }

    final kinds = _attachmentKinds(messages);
    final hasMedia = kinds.any((kind) => kind != AttachmentKind.text);
    final ordered = routingStrategy.order(providers, _health.snapshot);
    _emit(
      RequestStarted(
        request.id,
        providerOrder: <String>[for (final config in ordered) config.id],
      ),
    );
    final start = DateTime.now();
    final ignoreCircuits = ordered.every(
      (config) => _health.isBlocked(config, start),
    );
    var confirmedOnline = false;
    var calledAny = false;
    var budgetBlocked = false;
    var toolsRan = false;

    for (final config in ordered) {
      if (request.isCancelled) return;

      final capabilities = _capabilitiesOf(config);
      if (requestSettings.hasTools && !capabilities.tools) {
        _skip(request, logs, config, 'Does not support tool calls');
        continue;
      }
      final unsupported = capabilities.unsupported(kinds);
      if (unsupported.isNotEmpty) {
        _skip(
          request,
          logs,
          config,
          'Does not accept '
          '${unsupported.map((kind) => kind.name).join(', ')} attachments',
        );
        continue;
      }
      final budgetReason = budget?.blockReason(config, costTracker);
      if (budgetReason != null) {
        budgetBlocked = true;
        _skip(request, logs, config, budgetReason);
        continue;
      }
      final keyOrder = _keys.order(config, DateTime.now());
      if (keyOrder.isEmpty) {
        final until = _keys.nextAvailable(config);
        _skip(
          request,
          logs,
          config,
          'All ${config.allKeys.length} API keys are cooling down until '
          '${until?.toIso8601String() ?? 'later'}',
        );
        continue;
      }
      _eventRequestId = request.id;
      if (!ignoreCircuits && !_health.tryAcquire(config, DateTime.now())) {
        final until = _health.snapshot[config.id]?.openUntil;
        _skip(
          request,
          logs,
          config,
          'Circuit open until ${until?.toIso8601String() ?? 'a trial ends'}',
        );
        continue;
      }

      calledAny = true;
      final effective = config.copyWith(
        settings: _effectiveSettings(config.settings, requestSettings),
      );
      final keys = config.allKeys;
      final pooled = keys.length > 1;
      var keyPosition = 0;
      var conversation = messages;
      var round = 0;
      late _Attempt attempt;
      for (var retry = 0; ; retry++) {
        final keyIndex = keyOrder[keyPosition];
        final attemptConfig = pooled
            ? effective.copyWith(apiKey: keys[keyIndex])
            : effective;
        final loggedKey = pooled ? keyIndex : null;
        _emit(
          AttemptStarted(
            request.id,
            providerName: config.name,
            model: config.model,
            retry: retry,
          ),
        );
        attempt = await _attempt(
          config,
          attemptConfig,
          conversation,
          request,
          output,
        );
        _recordUsage(request, config, conversation, attempt);
        _eventRequestId = request.id;

        if (request.isCancelled) {
          _health.release(config);
          _addLog(
            request,
            logs,
            _log(
              config,
              attempt,
              retry: retry,
              error: 'Cancelled by the caller',
              keyIndex: loggedKey,
            ),
          );
          return;
        }

        var error = _classify(config, attempt, hasMedia: hasMedia);
        if (error == null && attempt.toolCalls.isNotEmpty && tools.isNotEmpty) {
          _health.recordSuccess(
            config,
            timeToFirstTokenMs: attempt.timeToFirstTokenMs,
          );
          _addLog(
            request,
            logs,
            _log(config, attempt, retry: retry, keyIndex: loggedKey),
          );
          if (round >= maxToolRounds) {
            throw TerminalLlmException(
              'Stopped after $maxToolRounds tool rounds without a final reply',
            );
          }
          final results = await _runTools(request, attempt.toolCalls);
          if (request.isCancelled) return;
          toolsRan = true;
          round++;
          conversation = <ChatTurn>[
            ...conversation,
            ChatTurn(
              role: ChatTurnRole.assistant,
              text: attempt.text.toString(),
              toolCalls: attempt.toolCalls,
            ),
            ChatTurn(role: ChatTurnRole.user, text: '', toolResults: results),
          ];
          retry = -1;
          continue;
        }
        if (error == null && request.validate != null) {
          error = _validate(request, attempt.text.toString());
        }
        if (error == null) {
          if (!attempt.emitted) output.add(attempt.text.toString());
          _health.recordSuccess(
            config,
            timeToFirstTokenMs: attempt.timeToFirstTokenMs,
          );
          _addLog(
            request,
            logs,
            _log(config, attempt, retry: retry, keyIndex: loggedKey),
          );
          if (cache != null && cacheKey != null) {
            _writeCache(
              cache,
              cacheKey,
              CachedResponse(
                text: attempt.text.toString(),
                providerName: config.name,
                model: config.model,
              ),
            );
          }
          return;
        }
        final failure = error;
        _health.recordAttemptFailure(config);
        _addLog(
          request,
          logs,
          _log(
            config,
            attempt,
            retry: retry,
            failure: failure,
            keyIndex: loggedKey,
          ),
          failure.redactedMessage,
        );

        if (failure is TerminalLlmException) {
          _health.release(config);
          Error.throwWithStackTrace(failure, attempt.trace ?? StackTrace.empty);
        }
        if (attempt.emitted) {
          // This attempt's text is already shown; a retry would repeat it.
          _health.recordRequestFailure(config, DateTime.now());
          Error.throwWithStackTrace(failure, attempt.trace ?? StackTrace.empty);
        }
        if (_keys.recordFailure(config, keyIndex, failure, DateTime.now()) &&
            keyPosition + 1 < keyOrder.length) {
          // This key is rate limited or rejected; the same provider may
          // still answer with its next key.
          keyPosition++;
          retry = -1;
          continue;
        }
        if (!confirmedOnline &&
            !_isLocalProvider(config) &&
            _isConnectionFailure(failure)) {
          final online = await connectivityChecker.hasInternet();
          if (request.isCancelled) {
            _health.release(config);
            return;
          }
          if (!online) {
            _health.release(config);
            throw NoInternetConnectionException(logs, cause: failure);
          }
          confirmedOnline = true;
        }

        final delay = retryPolicy.shouldRetry(failure)
            ? retryPolicy.delayFor(retry, failure)
            : null;
        if (delay == null) {
          if (toolsRan) {
            // Retrying this provider is safe because the tool results are in
            // the conversation, but another provider would start over and
            // run the tools again.
            _health.recordRequestFailure(config, DateTime.now());
            Error.throwWithStackTrace(
              failure,
              attempt.trace ?? StackTrace.empty,
            );
          }
          break;
        }
        _emit(
          RetryScheduled(
            request.id,
            providerName: config.name,
            model: config.model,
            retry: retry + 1,
            delay: delay,
          ),
        );
        await request.wait(delay);
        if (request.isCancelled) {
          _health.release(config);
          return;
        }
      }

      _eventRequestId = request.id;
      if (attempt.finishReason == FinishReason.contentFilter) {
        // The prompt was filtered; that says nothing about provider health.
        _health.release(config);
      } else {
        _health.recordRequestFailure(config, DateTime.now());
      }
    }

    if (!calledAny && budgetBlocked) {
      throw BudgetExceededException(logs, spentUsd: _totalCostOrZero());
    }
    if (!calledAny && hasMedia) {
      throw AllProvidersFailedException(
        logs,
        message:
            'No provider accepts these attachments '
            '(${logs.length} skipped)',
      );
    }
    throw AllProvidersFailedException(logs);
  }

  /// Streams one provider call into [output].
  Future<_Attempt> _attempt(
    ProviderConfig config,
    ProviderConfig effective,
    List<ChatTurn> messages,
    _RouteRequest request,
    StreamController<String> output,
  ) async {
    final attempt = _Attempt();
    final stopwatch = Stopwatch()..start();
    try {
      final iterator = StreamIterator<AdapterChunk>(
        _adapterFor(
          config,
        ).streamCompletion(config: effective, messages: messages),
      );
      request.attempt = iterator;
      try {
        while (await iterator.moveNext()) {
          switch (iterator.current) {
            case AdapterText(text: final chunk) when chunk.isNotEmpty:
              attempt.timeToFirstTokenMs ??= stopwatch.elapsedMilliseconds;
              attempt.text.write(chunk);
              // Structured output is shown only once it validates.
              if (request.validate == null) {
                output.add(chunk);
                attempt.emitted = true;
              }
            case AdapterText():
              break;
            case AdapterToolCall(:final call):
              attempt.timeToFirstTokenMs ??= stopwatch.elapsedMilliseconds;
              attempt.toolCalls.add(call);
            case AdapterUsage(
              :final inputTokens,
              :final outputTokens,
              :final cachedInputTokens,
            ):
              if (inputTokens != null) attempt.inputTokens = inputTokens;
              if (outputTokens != null) attempt.outputTokens = outputTokens;
              if (cachedInputTokens != null) {
                attempt.cachedInputTokens = cachedInputTokens;
              }
            case AdapterFinish(:final reason):
              attempt.finishReason = reason;
          }
        }
      } finally {
        request.attempt = null;
        _ignoreErrors(iterator.cancel());
      }
    } on Exception catch (error, stackTrace) {
      attempt.failure = _asRouterException(config, error);
      attempt.trace = stackTrace;
    }
    stopwatch.stop();
    attempt.latencyMs = stopwatch.elapsedMilliseconds;
    return attempt;
  }

  /// [own] settings with [request] settings as defaults, and the schema
  /// instruction appended to the system prompt when there is a schema.
  GenerationSettings _effectiveSettings(
    GenerationSettings own,
    GenerationSettings request,
  ) {
    final merged = own.withDefaults(request);
    final schema = merged.responseSchema;
    if (schema == null) return merged;
    return GenerationSettings(
      systemPrompt: <String>[
        if (merged.hasSystemPrompt) merged.systemPrompt!,
        'Respond with only a JSON value that matches the JSON Schema below. '
            'Do not add prose, comments, or code fences.\n'
            'Schema "${schema.name}"'
            '${schema.description == null ? '' : ' (${schema.description})'}: '
            '${jsonEncode(schema.schema)}',
      ].join('\n\n'),
      temperature: merged.temperature,
      topP: merged.topP,
      stopSequences: merged.stopSequences,
      tools: merged.tools,
      responseSchema: schema,
    );
  }

  /// Runs [calls] concurrently and returns their results in call order.
  Future<List<ToolResult>> _runTools(
    _RouteRequest request,
    List<ToolCall> calls,
  ) {
    return Future.wait(<Future<ToolResult>>[
      for (final call in calls) _runTool(request, call),
    ]);
  }

  Future<ToolResult> _runTool(_RouteRequest request, ToolCall call) async {
    final stopwatch = Stopwatch()..start();
    ToolResult result;
    final tool = _toolsByName[call.name];
    if (tool == null) {
      result = ToolResult(
        callId: call.id,
        name: call.name,
        content: 'Unknown tool "${call.name}"',
        isError: true,
      );
    } else {
      try {
        final value = await tool.handler(call.arguments);
        result = ToolResult(
          callId: call.id,
          name: call.name,
          content: value is String ? value : jsonEncode(value),
        );
      } on Exception catch (error) {
        result = ToolResult(
          callId: call.id,
          name: call.name,
          content: 'Tool failed: $error',
          isError: true,
        );
      } on JsonUnsupportedObjectError catch (error) {
        result = ToolResult(
          callId: call.id,
          name: call.name,
          content: 'Tool returned a value that is not JSON: ${error.cause}',
          isError: true,
        );
      }
    }
    _emit(
      ToolCallFinished(
        request.id,
        toolName: call.name,
        callId: call.id,
        duration: stopwatch.elapsed,
        isError: result.isError,
      ),
    );
    return result;
  }

  /// Whether [text] passes the request's structured output check, if any.
  bool _passes(_RouteRequest request, String text) =>
      request.validate == null || _validate(request, text) == null;

  /// Runs the request's structured output check on [text].
  LlmRouterException? _validate(_RouteRequest request, String text) {
    try {
      request.validate!(text);
      return null;
    } on InvalidStructuredOutputException catch (error) {
      return error;
    }
  }

  /// Returns the failure for [attempt], or null when it succeeded.
  LlmRouterException? _classify(
    ProviderConfig config,
    _Attempt attempt, {
    required bool hasMedia,
  }) {
    final failure = attempt.failure;
    if (failure == null) {
      if (attempt.text.isNotEmpty) return null;
      if (attempt.toolCalls.isNotEmpty && tools.isNotEmpty) return null;
      final filtered = attempt.finishReason == FinishReason.contentFilter;
      return RetryableLlmException(
        filtered
            ? '${config.name} returned no text (blocked by a content filter)'
            : '${config.name} returned no text',
      );
    }
    if (failure is TerminalLlmException &&
        failure.statusCode == 400 &&
        hasMedia &&
        attempt.text.isEmpty) {
      return ProviderUnavailableLlmException(
        '${failure.message} (the model may not accept these attachments)',
        statusCode: 400,
        cause: failure,
        redactedMessage: failure.redactedMessage,
      );
    }
    return failure;
  }

  BaseLlmAdapter _adapterFor(ProviderConfig config) {
    final custom = _customAdapters[config.name];
    if (custom != null) return custom;

    final key = (config.adapter ?? config.name).toLowerCase();
    final existing = _ownedAdapters[key];
    if (existing != null) return existing;

    final created = switch (key) {
      'openai' => OpenAiAdapter(),
      'anthropic' => AnthropicAdapter(),
      'gemini' => GeminiAdapter(),
      'openrouter' => OpenRouterAdapter(),
      'azure-openai' => AzureOpenAiAdapter(),
      _ => null,
    };
    if (created == null) {
      throw TerminalLlmException(
        'No adapter registered for provider "${config.name}". '
        'Set ProviderConfig.adapter to openai, anthropic, gemini, '
        'openrouter, or azure-openai, or use customAdapters.',
      );
    }
    _ownedAdapters[key] = created;
    return created;
  }

  ProviderCapabilities _capabilitiesOf(ProviderConfig config) {
    final configured = config.capabilities;
    if (configured != null) return configured;
    try {
      return _adapterFor(config).capabilities;
    } on TerminalLlmException {
      // The attempt reports the missing adapter.
      return ProviderCapabilities.all;
    }
  }

  void _recordUsage(
    _RouteRequest request,
    ProviderConfig config,
    List<ChatTurn> messages,
    _Attempt attempt,
  ) {
    if (_disposed) return;
    final output = attempt.text.toString();
    if (output.isEmpty &&
        attempt.inputTokens == null &&
        attempt.outputTokens == null) {
      return;
    }
    final inputTokens =
        attempt.inputTokens ?? _estimateTokens(_turnText(messages));
    final outputTokens = attempt.outputTokens ?? _estimateTokens(output);
    final cached = attempt.cachedInputTokens ?? 0;
    costTracker.recordUsage(
      config: config,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedInputTokens: cached,
    );
    _emit(
      UsageRecorded(
        request.id,
        providerName: config.name,
        model: config.model,
        inputTokens: inputTokens,
        cachedInputTokens: cached,
        outputTokens: outputTokens,
        costUsd: config.calculateCost(
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cachedInputTokens: cached,
        ),
        estimated: attempt.inputTokens == null || attempt.outputTokens == null,
      ),
    );
  }

  double _totalCostOrZero() => _disposed ? 0 : costTracker.totalCost;

  void _skip(
    _RouteRequest request,
    List<AttemptLog> logs,
    ProviderConfig config,
    String reason,
  ) {
    _addLog(
      request,
      logs,
      AttemptLog(
        providerName: config.name,
        model: config.model,
        timestamp: DateTime.now(),
        latencyMs: 0,
        isSuccess: false,
        error: 'Skipped: $reason',
        skipReason: reason,
      ),
    );
  }

  /// Appends [log], publishes the list, and reports it on [events].
  void _addLog(
    _RouteRequest request,
    List<AttemptLog> logs,
    AttemptLog log, [
    String? redactedError,
  ]) {
    logs.add(log);
    _publishLogs(request, logs);
    _emit(
      AttemptFinished(
        request.id,
        log: redactEventErrors && log.error != null
            ? _withError(log, redactedError ?? log.error)
            : log,
      ),
    );
  }

  /// Publishes [logs] unless the router is disposed or a newer call started.
  void _publishLogs(_RouteRequest request, List<AttemptLog> logs) {
    if (_disposed || request.id != _latestRequest) return;
    _attemptLogs.value = List<AttemptLog>.unmodifiable(logs);
  }

  void _emit(RouterEvent event) {
    if (_disposed || !_events.hasListener) return;
    _events.add(event);
  }

  AttemptLog _log(
    ProviderConfig config,
    _Attempt attempt, {
    required int retry,
    LlmRouterException? failure,
    String? error,
    int? keyIndex,
  }) {
    return AttemptLog(
      providerName: config.name,
      model: config.model,
      timestamp: DateTime.now(),
      latencyMs: attempt.latencyMs,
      isSuccess: failure == null && error == null,
      error: error ?? failure?.message,
      statusCode: failure?.statusCode,
      finishReason: attempt.finishReason,
      timeToFirstTokenMs: attempt.timeToFirstTokenMs,
      retry: retry,
      keyIndex: keyIndex,
    );
  }

  Future<CachedResponse?> _readCache(ResponseCache cache, String key) async {
    try {
      return await cache.read(key);
    } on Object {
      return null;
    }
  }

  void _writeCache(ResponseCache cache, String key, CachedResponse response) {
    try {
      final result = cache.write(key, response);
      if (result is Future<void>) _ignoreErrors(result);
    } on Object {
      // A broken cache must not fail a finished reply.
    }
  }

  String _cacheKey(List<ChatTurn> messages, GenerationSettings settings) {
    return jsonEncode(<String, Object?>{
      'settings': settings.toJson(),
      'messages': <Object?>[
        for (final turn in messages)
          <String, Object?>{
            'role': turn.role.name,
            'text': turn.text,
            'attachments': <Object?>[
              for (final attachment in turn.attachments)
                switch (attachment) {
                  FileTurnAttachment(
                    :final name,
                    :final mimeType,
                    :final bytes,
                  ) =>
                    <Object?>[name, mimeType, bytes.length, _hashBytes(bytes)],
                  LinkTurnAttachment(
                    :final name,
                    :final mimeType,
                    :final url,
                  ) =>
                    <Object?>[name, mimeType, url.toString()],
                },
            ],
          },
      ],
    });
  }

  List<ChatTurn> _historyTurns() {
    final turns = <ChatTurn>[];
    for (final message in _history) {
      if (_unsentMessages.contains(message)) continue;
      final text = message.text?.trim() ?? '';
      final attachments = _turnAttachments(message.attachments);
      if (text.isEmpty && attachments.isEmpty) continue;
      turns.add(
        ChatTurn(
          role: message.origin.isUser
              ? ChatTurnRole.user
              : ChatTurnRole.assistant,
          text: text,
          attachments: attachments,
        ),
      );
    }
    return turns;
  }
}

/// One routed call. Cancelling it stops the chain and the pending attempt.
class _RouteRequest {
  _RouteRequest({this.schema, this.validate});

  /// Schema for a `generateObject` call, or null.
  final ResponseSchema? schema;

  /// Throws [InvalidStructuredOutputException] for a reply that fails the
  /// structured output check. Null for a normal streaming call.
  final void Function(String text)? validate;

  int id = 0;
  bool isCancelled = false;
  StreamIterator<AdapterChunk>? attempt;
  final Completer<void> _cancelled = Completer<void>();

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    _cancelled.complete();
    final current = attempt;
    if (current != null) _ignoreErrors(current.cancel());
  }

  /// Waits for [delay], or less if the request is cancelled first.
  Future<void> wait(Duration delay) {
    final elapsed = Completer<void>();
    final timer = Timer(delay, elapsed.complete);
    return Future.any(<Future<void>>[
      elapsed.future,
      _cancelled.future,
    ]).whenComplete(timer.cancel);
  }
}

/// What one provider call produced.
class _Attempt {
  final StringBuffer text = StringBuffer();
  final List<ToolCall> toolCalls = <ToolCall>[];

  /// Whether any text reached the caller's stream.
  bool emitted = false;
  int? inputTokens;
  int? outputTokens;
  int? cachedInputTokens;
  FinishReason? finishReason;
  int? timeToFirstTokenMs;
  int latencyMs = 0;
  LlmRouterException? failure;
  StackTrace? trace;
}

List<ProviderConfig> _checkProviders(List<ProviderConfig> providers) {
  if (providers.isEmpty) {
    throw ArgumentError.value(providers, 'providers', 'must not be empty');
  }
  return List<ProviderConfig>.unmodifiable(providers);
}

List<RouterTool> _checkTools(List<RouterTool> tools) {
  final names = <String>{};
  for (final tool in tools) {
    if (!names.add(tool.name)) {
      throw ArgumentError.value(
        tool.name,
        'tools',
        'tool names must be unique',
      );
    }
  }
  return List<RouterTool>.unmodifiable(tools);
}

/// Parses [text] as JSON, tolerating a surrounding code fence, and passes
/// it to [decode].
T _decodeStructured<T>(String text, T Function(Object? json) decode) {
  var body = text.trim();
  final fence = RegExp(r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$').firstMatch(body);
  if (fence != null) body = fence.group(1)!;
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException catch (error) {
    throw InvalidStructuredOutputException(
      'Reply was not valid JSON: ${error.message}',
      cause: error,
      redactedMessage: 'Reply was not valid JSON',
    );
  }
  try {
    return decode(json);
  } on Object catch (error) {
    // A decoder rejects bad data with TypeError or its own exception.
    throw InvalidStructuredOutputException(
      'Reply did not match the expected shape: $error',
      cause: error,
      redactedMessage: 'Reply did not match the expected shape',
    );
  }
}

LlmRouterException _asRouterException(ProviderConfig config, Exception error) {
  if (error is LlmRouterException) return error;
  return RetryableLlmException(
    '${config.name} failed: $error',
    cause: error,
    redactedMessage: '${config.name} failed: ${error.runtimeType}',
  );
}

AttemptLog _withError(AttemptLog log, String? error) {
  return AttemptLog(
    providerName: log.providerName,
    model: log.model,
    timestamp: log.timestamp,
    latencyMs: log.latencyMs,
    isSuccess: log.isSuccess,
    error: error,
    statusCode: log.statusCode,
    finishReason: log.finishReason,
    timeToFirstTokenMs: log.timeToFirstTokenMs,
    retry: log.retry,
    skipReason: log.skipReason,
    fromCache: log.fromCache,
    keyIndex: log.keyIndex,
  );
}

List<TurnAttachment> _turnAttachments(Iterable<Attachment> attachments) {
  return <TurnAttachment>[
    for (final attachment in attachments)
      switch (attachment) {
        FileAttachment(:final name, :final mimeType, :final bytes) =>
          FileTurnAttachment(name: name, mimeType: mimeType, bytes: bytes),
        LinkAttachment(:final name, :final mimeType, :final url) =>
          LinkTurnAttachment(name: name, mimeType: mimeType, url: url),
      },
  ];
}

Set<AttachmentKind> _attachmentKinds(List<ChatTurn> messages) {
  return <AttachmentKind>{
    for (final turn in messages)
      for (final attachment in turn.attachments) attachment.kind,
  };
}

/// Whether [error] came from the transport (connect failure, dropped socket,
/// TLS failure, or timeout) rather than from an HTTP status such as 429 or
/// 503, or from malformed data.
bool _isConnectionFailure(LlmRouterException error) {
  final cause = error.cause;
  return cause is Exception && cause is! FormatException;
}

/// Whether [config] points at this device or a private network, where a
/// connection failure says nothing about internet access.
bool _isLocalProvider(ProviderConfig config) {
  final baseUrl = config.baseUrl;
  if (baseUrl == null) return false;
  final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
  if (host == 'localhost' || host.endsWith('.local')) return true;
  if (host == '::1' || host == '[::1]' || host == '10.0.2.2') return true;
  final octets = host.split('.').map(int.tryParse).toList();
  if (octets.length != 4 || octets.contains(null)) return false;
  final first = octets[0]!;
  final second = octets[1]!;
  return first == 127 ||
      first == 10 ||
      (first == 192 && second == 168) ||
      (first == 172 && second >= 16 && second <= 31);
}

void _ignoreErrors(Future<void> future) {
  unawaited(future.then<void>((_) {}, onError: (Object _) {}));
}

String _turnText(List<ChatTurn> messages) {
  return messages.map((message) => message.text).join('\n');
}

int _estimateTokens(String text) => (text.length + 3) ~/ 4;

/// A 30-bit rolling hash that stays exact on the web.
int _hashBytes(Uint8List bytes) {
  var hash = 0;
  for (final byte in bytes) {
    hash = (hash * 31 + byte) & 0x3FFFFFFF;
  }
  return hash;
}
