/// Multi-provider failover, token cost tracking, and attempt logging for
/// Flutter AI Toolkit.
///
/// Apps depend on this library and pass `RouterLlmProvider` to
/// `LlmChatView`. `ProviderConfig`, `AttemptLog`, and `CostTracker` are the
/// public contracts for pricing, observability, and live spend.
/// `LlmRouterException` and its subclasses classify retryable and terminal
/// provider failures. `RouterLlmProvider` fails over across that chain.
library;

export 'src/exceptions/router_exceptions.dart';
export 'src/models/attempt_log.dart';
export 'src/models/provider_config.dart';
export 'src/router_llm_provider.dart';
export 'src/tracking/cost_tracker.dart';
