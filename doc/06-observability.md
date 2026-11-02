# Observability

The router reports what it does in three ways:

- `lastAttemptLogs` and `attemptLogs`: the attempts of the latest request, for UI.
- `events`: a stream of everything that happens, for logging, analytics, and tracing.
- `RouterInspector`: a ready-made debug panel.

## Attempt logs

Each `AttemptLog` records one provider attempt:

| Field | Meaning |
| --- | --- |
| `providerName`, `model` | Which provider and model |
| `isSuccess`, `error`, `statusCode` | Outcome |
| `latencyMs`, `timeToFirstTokenMs` | Total time and time to the first text chunk |
| `finishReason` | Why the provider stopped, for example `FinishReason.length` |
| `retry` | 0 for the first try, then 1, 2, and so on |
| `skipReason`, `isSkipped` | Set when the router skipped the provider without calling it |
| `fromCache` | Set when the reply came from the response cache |

`AttemptLog.error` keeps the full message, including any provider response text.

## Events

`router.events` is a broadcast stream. Every event of one request shares `requestId`.

| Event | When |
| --- | --- |
| `RequestStarted` | Routing begins. `providerOrder` lists provider ids in try order |
| `AttemptStarted` | A provider is about to be called |
| `AttemptFinished` | An attempt ended, was skipped, or came from the cache. Carries the `AttemptLog` |
| `RetryScheduled` | A retry will run after `delay` |
| `CircuitStateChanged` | A provider's circuit moved between `closed`, `open`, and `halfOpen` |
| `UsageRecorded` | Tokens and cost were added to the `CostTracker`. `estimated` is true when a count came from text length |
| `RequestFinished` | The request ended with `RequestOutcome.succeeded`, `cancelled`, or `failed` |

Events are delivered asynchronously. With no listener, nothing is buffered. The stream closes on `dispose`.

```dart
final subscription = router.events.listen((event) {
  switch (event) {
    case RequestFinished(:final outcome, :final latency, :final errorType):
      debugPrint('request ${event.requestId}: ${outcome.name} '
          'in ${latency.inMilliseconds} ms ${errorType ?? ''}');
    case UsageRecorded(:final providerName, :final costUsd):
      debugPrint('$providerName cost \$${costUsd.toStringAsFixed(6)}');
    default:
      break;
  }
});
// Later: await subscription.cancel();
```

## Redaction

Provider error responses can echo part of the prompt. Prompts can hold personal data, so events leave that text out by default (`redactEventErrors: true`):

- `AttemptFinished.log.error` carries `LlmRouterException.redactedMessage`, for example `HTTP 429` instead of `HTTP 429: {"error": ...}`.
- `RequestFinished.errorMessage` is the redacted message, and `errorType` is the exception's type name.

`lastAttemptLogs` and the exceptions thrown to the caller always keep the full message. Pass `redactEventErrors: false` only when your telemetry may hold prompt content.

A custom adapter's exceptions are redacted only if you pass `redactedMessage` when you create them. Otherwise `redactedMessage` falls back to `message`.

## Wiring to a tracing or error service

The package has no telemetry dependencies. Map events to your tool's API in a listener. This sketch uses placeholder functions; replace them with your SDK's calls, such as Sentry breadcrumbs or OpenTelemetry spans:

```dart
class RouterTelemetry {
  RouterTelemetry(RouterLlmProvider router) {
    _subscription = router.events.listen(_onEvent);
  }

  late final StreamSubscription<RouterEvent> _subscription;
  final Map<int, DateTime> _started = {};

  void _onEvent(RouterEvent event) {
    switch (event) {
      case RequestStarted():
        _started[event.requestId] = event.timestamp;
      case AttemptFinished(:final log) when !log.isSuccess && !log.isSkipped:
        addBreadcrumb('llm.attempt_failed', {
          'provider': log.providerName,
          'model': log.model,
          'status': log.statusCode,
          'error': log.error, // Redacted by default.
        });
      case CircuitStateChanged(:final providerId, :final to):
        addBreadcrumb('llm.circuit', {'provider': providerId, 'state': to.name});
      case RequestFinished(:final outcome, :final errorType, :final errorMessage):
        _started.remove(event.requestId);
        if (outcome == RequestOutcome.failed) {
          reportError(errorType ?? 'unknown', errorMessage);
        }
      default:
        break;
    }
  }

  Future<void> dispose() => _subscription.cancel();
}

// Placeholders: call your telemetry SDK here.
void addBreadcrumb(String category, Map<String, Object?> data) {}
void reportError(String type, String? message) {}
```

For OpenTelemetry, open a span on `RequestStarted`, add a child span or span event per `AttemptStarted` and `AttemptFinished`, and end it on `RequestFinished`, keyed by `requestId`.

## RouterInspector

`RouterInspector` shows total spend and tokens, a chip per provider with its circuit state and average time to first token, and one row per attempt of the latest request. It rebuilds as the router works.

```dart
IconButton(
  icon: const Icon(Icons.bug_report),
  onPressed: () => showModalBottomSheet<void>(
    context: context,
    builder: (_) => SingleChildScrollView(child: RouterInspector(router: router)),
  ),
)
```

The panel sizes itself to its content, so wrap it in a scroll view when space is bounded. Remove it before disposing the router. It's meant for development and internal builds, because it shows full error messages.
