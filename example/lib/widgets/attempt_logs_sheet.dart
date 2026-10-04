import 'package:flutter/material.dart';
import 'package:flutter_llm_router/flutter_llm_router.dart';

/// Modal bottom sheet displaying round-trip attempt latency, provider, and error status.
class AttemptLogsSheet extends StatelessWidget {
  const AttemptLogsSheet({super.key, required this.logs});

  final List<AttemptLog> logs;

  static void show(BuildContext context, List<AttemptLog> logs) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => AttemptLogsSheet(logs: logs),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Attempt Diagnostics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (logs.isEmpty)
              const Text(
                  'No attempts recorded yet. Send a prompt to test failover.')
            else
              for (final log in logs) _AttemptTile(log: log),
          ],
        ),
      ),
    );
  }
}

class _AttemptTile extends StatelessWidget {
  const _AttemptTile({required this.log});

  final AttemptLog log;

  @override
  Widget build(BuildContext context) {
    final status = log.isSuccess ? 'Success' : _failureStatus(log);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        log.isSuccess ? Icons.check_circle_outline : Icons.error_outline,
        color: log.isSuccess ? Colors.green : Colors.red,
      ),
      title: Text(log.model),
      subtitle: Text(
          '${log.providerName.toUpperCase()} · ${log.latencyMs} ms · $status'),
    );
  }

  String _failureStatus(AttemptLog log) {
    final code = log.statusCode;
    final error = log.error;
    if (code != null && error != null && error.isNotEmpty) {
      return 'HTTP $code ($error)';
    }
    if (error != null && error.isNotEmpty) return error;
    if (code != null) return 'HTTP $code';
    return 'Failed';
  }
}
