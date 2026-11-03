/// Multi-provider failover, token cost tracking, and attempt logging for
/// Flutter AI Toolkit.
///
/// Apps depend on this library and pass `RouterLlmProvider` to
/// `LlmChatView`. `ProviderConfig`, `AttemptLog`, and `CostTracker` are the
/// public contracts for pricing, observability, and live spend.
/// `LlmRouterException` and its subclasses classify retryable and terminal
/// provider failures. `RouterLlmProvider` fails over across that chain.
/// `RetryPolicy`, `CircuitBreakerPolicy`, `RoutingStrategy`, `BudgetPolicy`,
/// `KeyPoolPolicy`, and `ResponseCache` tune it, `RouterEvent` reports what it
/// does, and `RouterInspector` shows it live.
library;

export 'src/adapters/anthropic_adapter.dart';
export 'src/adapters/azure_openai_adapter.dart';
export 'src/adapters/base_adapter.dart';
export 'src/adapters/gemini_adapter.dart';
export 'src/adapters/openai_adapter.dart';
export 'src/adapters/openrouter_adapter.dart';
export 'src/connectivity/connectivity_checker.dart';
export 'src/exceptions/router_exceptions.dart';
export 'src/models/adapter_chunk.dart';
export 'src/models/attempt_log.dart';
export 'src/models/chat_turn.dart';
export 'src/models/finish_reason.dart';
export 'src/models/generation_settings.dart';
export 'src/models/provider_capabilities.dart';
export 'src/models/provider_config.dart';
export 'src/models/response_schema.dart';
export 'src/models/tool.dart';
export 'src/models/turn_attachment.dart';
export 'src/router_llm_provider.dart';
export 'src/routing/budget_policy.dart';
export 'src/routing/key_pool.dart' show KeyPoolPolicy, KeyRotation;
export 'src/routing/provider_health.dart'
    show CircuitBreakerPolicy, CircuitState, ProviderHealth;
export 'src/routing/response_cache.dart';
export 'src/routing/retry_policy.dart';
export 'src/routing/router_event.dart';
export 'src/routing/routing_strategy.dart';
export 'src/tracking/cost_tracker.dart';
export 'src/widgets/router_inspector.dart';
