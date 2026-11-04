import 'package:flutter/material.dart';

import '../models/attempt_log.dart';
import '../router_llm_provider.dart';
import '../routing/provider_health.dart';

/// A live debug panel for a [RouterLlmProvider].
///
/// Shows total spend and tokens, each provider's circuit state and average
/// time to first token, and the attempts of the latest request: provider,
/// latency, status, retries, skips, cache hits, and errors. It rebuilds as
/// the router works, so it can sit beside `LlmChatView` during development
/// or in a bottom sheet.
///
/// The panel sizes itself to its content; wrap it in a scroll view when the
/// space is bounded. Remove it before disposing [router].
class RouterInspector extends StatelessWidget {
  /// Creates an inspector for [router].
  const RouterInspector({super.key, required this.router});

  /// The router to show.
  final RouterLlmProvider router;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        router.attemptLogs,
        router.costTracker.totalCostNotifier,
        router.providerHealth,
      ]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final tracker = router.costTracker;
        final health = router.providerHealth.value;
        final logs = router.lastAttemptLogs;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '\$${tracker.totalCost.toStringAsFixed(6)} spent · '
                '${tracker.totalInputTokens} in · '
                '${tracker.totalOutputTokens} out',
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (health.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final entry in health.values) _HealthChip(entry),
                  ],
                ),
              ),
            if (logs.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No requests yet.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              for (final log in logs) _AttemptTile(log),
          ],
        );
      },
    );
  }
}

class _HealthChip extends StatelessWidget {
  const _HealthChip(this.health);

  final ProviderHealth health;

  @override
  Widget build(BuildContext context) {
    final color = switch (health.state) {
      CircuitState.closed => Colors.green,
      CircuitState.halfOpen => Colors.amber,
      CircuitState.open => Colors.red,
    };
    final latency = health.averageTimeToFirstTokenMs;
    return Tooltip(
      message:
          '${health.state.name}: ${health.successes} ok, '
          '${health.failures} failed',
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.circle, size: 10, color: color),
        label: Text(
          latency == null
              ? health.providerId
              : '${health.providerId} · ${latency.round()} ms',
        ),
      ),
    );
  }
}

class _AttemptTile extends StatelessWidget {
  const _AttemptTile(this.log);

  final AttemptLog log;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = log.fromCache
        ? (Icons.bolt, scheme.tertiary)
        : log.isSkipped
        ? (Icons.skip_next, scheme.outline)
        : log.isSuccess
        ? (Icons.check_circle, Colors.green)
        : (Icons.error, scheme.error);
    final details = <String>[
      if (log.fromCache) 'cache' else '${log.latencyMs} ms',
      if (log.timeToFirstTokenMs != null) 'TTFT ${log.timeToFirstTokenMs} ms',
      if (log.statusCode != null) 'HTTP ${log.statusCode}',
      if (log.retry > 0) 'retry ${log.retry}',
      if (log.finishReason != null) log.finishReason!.name,
    ];
    final error = log.skipReason ?? log.error;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text('${log.providerName} · ${log.model}'),
      subtitle: Text(
        <String>[details.join(' · '), ?error].join('\n'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
