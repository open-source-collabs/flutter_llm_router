import 'package:flutter/foundation.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';

/// ViewModel managing router state, direct provider credentials, and simulated failovers.
class ChatRouterViewModel extends ChangeNotifier {
  ChatRouterViewModel({
    String initialOpenAiKey = const String.fromEnvironment('OPENAI_API_KEY'),
    String initialGeminiKey = const String.fromEnvironment('GEMINI_API_KEY'),
    String initialAnthropicKey =
        const String.fromEnvironment('ANTHROPIC_API_KEY'),
  })  : _openAiKey = initialOpenAiKey,
        _geminiKey = initialGeminiKey,
        _anthropicKey = initialAnthropicKey {
    _initAdaptersAndRouter();
  }

  String _openAiKey;
  String _geminiKey;
  String _anthropicKey;

  String get openAiKey => _openAiKey;
  String get geminiKey => _geminiKey;
  String get anthropicKey => _anthropicKey;

  bool _failOpenAi = false;
  bool _failGemini = false;

  bool get failOpenAi => _failOpenAi;
  bool get failGemini => _failGemini;

  late final CostTracker _costTracker;
  late final _SimulatedFailableAdapter _openAiAdapter;
  late final _SimulatedFailableAdapter _geminiAdapter;
  late final _SimulatedFailableAdapter _anthropicAdapter;
  late final RouterLlmProvider _router;

  CostTracker get costTracker => _costTracker;
  RouterLlmProvider get router => _router;
  List<AttemptLog> get lastAttemptLogs => _router.lastAttemptLogs;

  void _initAdaptersAndRouter() {
    _costTracker = CostTracker();

    _openAiAdapter = _SimulatedFailableAdapter(
      delegate: OpenAiAdapter(),
      apiKeyProvider: () => _openAiKey,
      shouldFail: () => _failOpenAi,
    );
    _geminiAdapter = _SimulatedFailableAdapter(
      delegate: GeminiAdapter(),
      apiKeyProvider: () => _geminiKey,
      shouldFail: () => _failGemini,
    );
    _anthropicAdapter = _SimulatedFailableAdapter(
      delegate: AnthropicAdapter(),
      apiKeyProvider: () => _anthropicKey,
      shouldFail: () => false,
    );

    _router = RouterLlmProvider(
      costTracker: _costTracker,
      providers: const [
        ProviderConfig(
          name: 'openai',
          apiKey: '',
          model: 'gpt-4o-mini',
          pricePerInputToken: 0.00000015,
          pricePerOutputToken: 0.0000006,
        ),
        ProviderConfig(
          name: 'gemini',
          apiKey: '',
          model: 'gemini-2.0-flash',
          pricePerInputToken: 0.0000001,
          pricePerOutputToken: 0.0000004,
        ),
        ProviderConfig(
          name: 'anthropic',
          apiKey: '',
          model: 'claude-3-5-haiku-20241022',
          pricePerInputToken: 0.0000008,
          pricePerOutputToken: 0.000004,
        ),
      ],
      customAdapters: <String, BaseLlmAdapter>{
        'openai': _openAiAdapter,
        'gemini': _geminiAdapter,
        'anthropic': _anthropicAdapter,
      },
    );
  }

  void setFailOpenAi(bool value) {
    if (_failOpenAi == value) return;
    _failOpenAi = value;
    notifyListeners();
  }

  void setFailGemini(bool value) {
    if (_failGemini == value) return;
    _failGemini = value;
    notifyListeners();
  }

  void updateKeys({
    required String openAiKey,
    required String geminiKey,
    required String anthropicKey,
  }) {
    _openAiKey = openAiKey.trim();
    _geminiKey = geminiKey.trim();
    _anthropicKey = anthropicKey.trim();
    notifyListeners();
  }

  @override
  void dispose() {
    _router.dispose();
    _openAiAdapter.close();
    _geminiAdapter.close();
    _anthropicAdapter.close();
    _costTracker.dispose();
    super.dispose();
  }
}

/// Adapter wrapper that injects API keys dynamically and allows testing HTTP 429 failover.
class _SimulatedFailableAdapter extends BaseLlmAdapter {
  _SimulatedFailableAdapter({
    required this.delegate,
    required this.apiKeyProvider,
    required this.shouldFail,
  });

  final BaseLlmAdapter delegate;
  final String Function() apiKeyProvider;
  final bool Function() shouldFail;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    if (shouldFail()) {
      return Stream<AdapterChunk>.error(
        RetryableLlmException(
          'Simulated HTTP 429 for ${config.name} (${config.model})',
          statusCode: 429,
        ),
      );
    }
    return delegate.streamCompletion(
      config: config.copyWith(apiKey: apiKeyProvider()),
      messages: messages,
    );
  }

  @override
  void close() {
    delegate.close();
    super.close();
  }
}
