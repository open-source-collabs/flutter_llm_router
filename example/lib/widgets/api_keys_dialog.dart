import 'package:flutter/material.dart';
import '../view_model/chat_router_view_model.dart';

/// Modal dialog for inspecting and updating provider API credentials.
class ApiKeysDialog extends StatefulWidget {
  const ApiKeysDialog({super.key, required this.viewModel});

  final ChatRouterViewModel viewModel;

  static Future<void> show(
      BuildContext context, ChatRouterViewModel viewModel) {
    return showDialog<void>(
      context: context,
      builder: (context) => ApiKeysDialog(viewModel: viewModel),
    );
  }

  @override
  State<ApiKeysDialog> createState() => _ApiKeysDialogState();
}

class _ApiKeysDialogState extends State<ApiKeysDialog> {
  late final TextEditingController _openAiController;
  late final TextEditingController _geminiController;
  late final TextEditingController _anthropicController;

  @override
  void initState() {
    super.initState();
    _openAiController = TextEditingController(text: widget.viewModel.openAiKey);
    _geminiController = TextEditingController(text: widget.viewModel.geminiKey);
    _anthropicController =
        TextEditingController(text: widget.viewModel.anthropicKey);
  }

  @override
  void dispose() {
    _openAiController.dispose();
    _geminiController.dispose();
    _anthropicController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Direct Provider API Keys'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _openAiController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'OpenAI API Key (sk-...)',
                helperText: 'Direct to api.openai.com',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _geminiController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Google Gemini API Key (AIza...)',
                helperText: 'Direct to generativelanguage.googleapis.com',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _anthropicController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Anthropic API Key (sk-ant-...)',
                helperText: 'Direct to api.anthropic.com',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            widget.viewModel.updateKeys(
              openAiKey: _openAiController.text,
              geminiKey: _geminiController.text,
              anthropicKey: _anthropicController.text,
            );
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
