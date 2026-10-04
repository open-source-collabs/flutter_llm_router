import 'package:flutter/material.dart';
import 'package:flutter_ai_toolkit/flutter_ai_toolkit.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';
import 'package:flutter_llm_router/src/adapters/base_adapter.dart';
import 'package:flutter_llm_router/src/adapters/openrouter_adapter.dart';
import 'package:flutter_llm_router/src/models/adapter_chunk.dart';
import 'package:flutter_llm_router/src/models/chat_turn.dart';

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
  final TextEditingController _openRouterKey = TextEditingController();
  final CostTracker _costTracker = CostTracker();

  late final _OpenRouterHops _hops;
  late final RouterLlmProvider _router;

  bool _failOpenAi = false;
  bool _failGemini = false;

  @override
  void initState() {
    super.initState();
    _hops = _OpenRouterHops(
      delegate: OpenRouterAdapter(),
      apiKey: _openRouterKey,
      failOpenAi: () => _failOpenAi,
      failGemini: () => _failGemini,
    );
    _router = RouterLlmProvider(
      providers: const [
        ProviderConfig(
          name: 'openrouter',
          apiKey: '',
          model: 'openai/gpt-4o-mini',
          pricePerInputToken: 0.00000015,
          pricePerOutputToken: 0.0000006,
        ),
        ProviderConfig(
          name: 'openrouter',
          apiKey: '',
          model: 'google/gemini-2.5-flash',
          pricePerInputToken: 0.0000003,
          pricePerOutputToken: 0.0000025,
        ),
        ProviderConfig(
          name: 'openrouter',
          apiKey: '',
          model: 'anthropic/claude-haiku-4.5',
          pricePerInputToken: 0.000001,
          pricePerOutputToken: 0.000005,
        ),
      ],
      costTracker: _costTracker,
      customAdapters: <String, BaseLlmAdapter>{
        'openrouter': _hops,
      },
    );
  }

  @override
  void dispose() {
    _router.dispose();
    _hops.close();
    _costTracker.dispose();
    _openRouterKey.dispose();
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
                      child: Text('Simulate primary outage (HTTP 429)'),
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
                      child: Text('Also fail Gemini'),
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
        welcomeMessage:
            'Provider name is openrouter. Models: openai/gpt-4o-mini, then '
            'google/gemini-2.5-flash, then anthropic/claude-haiku-4.5. '
            'Turn on the 429 switch to land on Gemini. Turn on both switches '
            'to land on Anthropic.',
        suggestions: const ['Hello', 'Count to three'],
      ),
    );
  }

  void _editKeys() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('OpenRouter API key'),
          content: TextField(
            controller: _openRouterKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'OpenRouter API key',
              helperText:
                  'Sent as Bearer auth to openrouter.ai for every hop',
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

class _OpenRouterHops extends BaseLlmAdapter {
  _OpenRouterHops({
    required this.delegate,
    required this.apiKey,
    required this.failOpenAi,
    required this.failGemini,
  });

  final OpenRouterAdapter delegate;
  final TextEditingController apiKey;
  final bool Function() failOpenAi;
  final bool Function() failGemini;

  @override
  Stream<AdapterChunk> streamCompletion({
    required ProviderConfig config,
    required List<ChatTurn> messages,
  }) {
    final model = config.model;
    if ((failOpenAi() && model.startsWith('openai/')) ||
        (failGemini() && model.startsWith('google/'))) {
      return Stream<AdapterChunk>.error(
        RetryableLlmException(
          'Simulated HTTP 429 for $model',
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
