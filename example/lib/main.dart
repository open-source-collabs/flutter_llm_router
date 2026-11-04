import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_llm_router',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F6FEB)),
      ),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final TextEditingController _openAiKey = TextEditingController(
    text: const String.fromEnvironment('OPENAI_API_KEY'),
  );
  final TextEditingController _geminiKey = TextEditingController(
    text: const String.fromEnvironment('GEMINI_API_KEY'),
  );
  final TextEditingController _anthropicKey = TextEditingController(
    text: const String.fromEnvironment('ANTHROPIC_API_KEY'),
  );
  final CostTracker _costTracker = CostTracker();

  late final _FailableAdapter _openAiAdapter;
  late final _FailableAdapter _geminiAdapter;
  late final _FailableAdapter _anthropicAdapter;
  late final RouterLlmProvider _router;

  bool _failOpenAi = false;
  bool _dropOpenAi = false;
  bool _failGemini = false;

  @override
  void initState() {
    super.initState();
    _openAiAdapter = _FailableAdapter(
      delegate: OpenAiAdapter(),
      apiKey: _openAiKey,
      simulate:
          () =>
              _dropOpenAi
                  ? _SimulatedFailure.network
                  : _failOpenAi
                  ? _SimulatedFailure.rateLimit
                  : null,
    );
    _geminiAdapter = _FailableAdapter(
      delegate: GeminiAdapter(),
      apiKey: _geminiKey,
      simulate: () => _failGemini ? _SimulatedFailure.rateLimit : null,
    );
    _anthropicAdapter = _FailableAdapter(
      delegate: AnthropicAdapter(),
      apiKey: _anthropicKey,
      simulate: () => null,
    );

    _router = RouterLlmProvider(
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
      costTracker: _costTracker,
      settings: const GenerationSettings(
        systemPrompt: 'You are a concise, friendly assistant.',
      ),
      // Two failed requests in a row skip a provider for 20 seconds, so a
      // simulated outage stops costing a round trip on every message.
      circuitBreaker: const CircuitBreakerPolicy(
        failureThreshold: 2,
        cooldown: Duration(seconds: 20),
      ),
      customAdapters: <String, BaseLlmAdapter>{
        'openai': _openAiAdapter,
        'gemini': _geminiAdapter,
        'anthropic': _anthropicAdapter,
      },
    );
  }

  @override
  void dispose() {
    _router.dispose();
    _openAiAdapter.close();
    _geminiAdapter.close();
    _anthropicAdapter.close();
    _costTracker.dispose();
    _openAiKey.dispose();
    _geminiKey.dispose();
    _anthropicKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder<double>(
          valueListenable: _costTracker.totalCostNotifier,
          builder: (context, totalCost, _) {
            return Tooltip(
              message: 'Conversation spend in USD',
              child: Text('\$${totalCost.toStringAsFixed(8)}'),
            );
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Provider API keys',
            onPressed: _editKeys,
            icon: const Icon(Icons.key),
          ),
          IconButton(
            tooltip: 'Router inspector',
            onPressed: _showInspector,
            icon: const Icon(Icons.receipt_long),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(160),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Simulate OpenAI outage (HTTP 429)'),
                    ),
                    Switch(
                      value: _failOpenAi,
                      onChanged: (value) => setState(() => _failOpenAi = value),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Simulate OpenAI network failure'),
                    ),
                    Switch(
                      value: _dropOpenAi,
                      onChanged: (value) => setState(() => _dropOpenAi = value),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(child: Text('Also simulate Gemini outage')),
                    Switch(
                      value: _failGemini,
                      onChanged: (value) => setState(() => _failGemini = value),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: LlmChatView(
        provider: _router,
        welcomeMessage:
            'Separate Direct Providers:\n'
            '1. OpenAI (gpt-4o-mini)\n'
            '2. Google Gemini (gemini-2.0-flash)\n'
            '3. Anthropic (claude-3-5-haiku)\n\n'
            'Without keys, each provider sends a simulated demo reply. '
            'Tap the key icon at top right to enter real API keys. '
            'Use the outage switches above to test live failover, and the '
            'inspector icon to watch each attempt.',
        suggestions: const ['Hello', 'Count to three'],
        onErrorCallback: _showError,
      ),
    );
  }

  void _showError(BuildContext context, LlmException error) {
    if (error.message == NoInternetConnectionException.defaultMessage) {
      final colors = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: colors.errorContainer,
            content: Row(
              children: [
                Icon(Icons.wifi_off, color: colors.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No internet connection. Check your network and try again.',
                    style: TextStyle(color: colors.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
        );
      return;
    }
    showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            icon: const Icon(Icons.error_outline),
            title: const Text('Something went wrong'),
            content: Text(error.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  }

  void _editKeys() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Direct Provider API Keys'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _openAiKey,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'OpenAI API key (sk-...)',
                    helperText: 'Direct to api.openai.com',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _geminiKey,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Gemini API key (AIza...)',
                    helperText: 'Direct to generativelanguage.googleapis.com',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _anthropicKey,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Anthropic API key (sk-ant-...)',
                    helperText: 'Direct to api.anthropic.com',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }

  void _showInspector() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: RouterInspector(router: _router),
          ),
        );
      },
    );
  }
}

enum _SimulatedFailure { rateLimit, network }

class _FailableAdapter extends BaseLlmAdapter {
  _FailableAdapter({
    required this.delegate,
    required this.apiKey,
    required this.simulate,
  });

  final BaseLlmAdapter delegate;
  final TextEditingController apiKey;
  final _SimulatedFailure? Function() simulate;

  // Forward the wrapped vendor's attachment support, so the router skips
  // this provider for files the vendor cannot take.
  @override
  ProviderCapabilities get capabilities => delegate.capabilities;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    switch (simulate()) {
      case _SimulatedFailure.rateLimit:
        return Stream<AdapterChunk>.error(
          RetryableLlmException(
            'Simulated HTTP 429 for ${config.name} (${config.model})',
            statusCode: 429,
          ),
        );
      case _SimulatedFailure.network:
        // A connection-level failure: the router probes connectivity and,
        // when the device is online, fails over to the next provider.
        return Stream<AdapterChunk>.error(
          RetryableLlmException(
            'Simulated connection failure for ${config.name} '
            '(${config.model})',
            cause: http.ClientException('Simulated host unreachable'),
          ),
        );
      case null:
        break;
    }
    final key = apiKey.text.trim();
    if (key.isEmpty) return _demoReply(config);
    return delegate.streamCompletion(
      config: config.copyWith(apiKey: key),
      messages: messages,
    );
  }

  /// A simulated reply for providers without a key, so the hosted demo
  /// shows failover and cost tracking without real API calls.
  Stream<AdapterChunk> _demoReply(ProviderConfig config) async* {
    final words =
        'Demo reply from ${config.name} (${config.model}). Flip an outage '
                'switch and send again to watch the router fail over. Add an '
                'API key to talk to the real model.'
            .split(' ');
    for (final word in words) {
      await Future<void>.delayed(const Duration(milliseconds: 35));
      yield AdapterText('$word ');
    }
    yield const AdapterFinish(FinishReason.stop);
  }

  @override
  void close() {
    delegate.close();
    super.close();
  }
}
