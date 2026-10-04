import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';

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
  bool _failGemini = false;

  @override
  void initState() {
    super.initState();
    _openAiAdapter = _FailableAdapter(
      delegate: OpenAiAdapter(),
      apiKey: _openAiKey,
      shouldFail: () => _failOpenAi,
    );
    _geminiAdapter = _FailableAdapter(
      delegate: GeminiAdapter(),
      apiKey: _geminiKey,
      shouldFail: () => _failGemini,
    );
    _anthropicAdapter = _FailableAdapter(
      delegate: AnthropicAdapter(),
      apiKey: _anthropicKey,
      shouldFail: () => false,
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
            tooltip: 'Attempt logs',
            onPressed: _showAttemptLogs,
            icon: const Icon(Icons.receipt_long),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
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
                      child: Text('Also simulate Gemini outage'),
                    ),
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
        welcomeMessage: 'Separate Direct Providers:\n'
            '1. OpenAI (gpt-4o-mini)\n'
            '2. Google Gemini (gemini-2.0-flash)\n'
            '3. Anthropic (claude-3-5-haiku)\n\n'
            'Tap the key icon at top right to enter your API keys. '
            'Use the outage switches above to test live failover!',
        suggestions: const ['Hello', 'Count to three'],
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

  void _showAttemptLogs() {
    final logs = _router.lastAttemptLogs;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Attempt logs',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (logs.isEmpty)
                  const Text('No attempts yet. Send a message to record one.')
                else
                  for (final log in logs) _AttemptTile(log: log),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AttemptTile extends StatelessWidget {
  const _AttemptTile({required this.log});

  final AttemptLog log;

  @override
  Widget build(BuildContext context) {
    final status = log.isSuccess ? 'success' : _failureStatus(log);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        log.isSuccess ? Icons.check_circle_outline : Icons.error_outline,
      ),
      title: Text(log.model),
      subtitle: Text('${log.providerName} · ${log.latencyMs} ms · $status'),
    );
  }
}

String _failureStatus(AttemptLog log) {
  final code = log.statusCode;
  final error = log.error;
  if (code != null && error != null && error.isNotEmpty) {
    return 'HTTP $code · $error';
  }
  if (error != null && error.isNotEmpty) return error;
  if (code != null) return 'HTTP $code';
  return 'failed';
}

class _FailableAdapter extends BaseLlmAdapter {
  _FailableAdapter({
    required this.delegate,
    required this.apiKey,
    required this.shouldFail,
  });

  final BaseLlmAdapter delegate;
  final TextEditingController apiKey;
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
      config: config.copyWith(apiKey: apiKey.text.trim()),
      messages: messages,
    );
  }

  @override
  void close() {
    delegate.close();
    super.close();
  }
}
