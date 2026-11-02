# Documentation

Guides for the `flutter_llm_router` package published on [pub.dev](https://pub.dev/packages/flutter_llm_router).

| Guide | Contents |
| --- | --- |
| [01-quickstart.md](01-quickstart.md) | Installation, router setup, `LlmChatView`, disposal |
| [02-configuration.md](02-configuration.md) | `ProviderConfig`, timeout, `baseUrl`, failover rules |
| [03-cost-tracking.md](03-cost-tracking.md) | `CostTracker`, `ValueNotifier` binding, token estimate, cached tokens, per-provider breakdown |
| [04-attachments-and-settings.md](04-attachments-and-settings.md) | Attachments per vendor, `ProviderCapabilities`, `GenerationSettings`, finish reasons, presets |
| [05-reliability-policies.md](05-reliability-policies.md) | `RetryPolicy`, circuit breaker, routing strategies, budgets, response cache |
| [06-observability.md](06-observability.md) | Attempt logs, `events`, redaction, telemetry wiring, `RouterInspector` |
| [07-production-checklist.md](07-production-checklist.md) | What to check before shipping |
| [08-backend-proxy.md](08-backend-proxy.md) | Keeping keys off the device, proxy sketches |
| [09-comparison.md](09-comparison.md) | How this compares with other options, and when not to use it |
| [10-tools-and-structured-output.md](10-tools-and-structured-output.md) | `RouterTool`, the tool loop, `generateObject`, vendor details |
| [11-reliability-benchmark.md](11-reliability-benchmark.md) | Seeded chaos run: success rates by setup, and what they mean |

Design notes live in [design/](design/), and draft articles in [articles/](articles/).

The example app in `example/` is the realtime check against OpenAI and Gemini.

