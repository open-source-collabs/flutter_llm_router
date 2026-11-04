# Comparison

`flutter_llm_router` does one job: make LLM chat in Flutter keep working when a provider fails, and show what it costs. This page compares it with other ways to call LLMs from Dart so you can choose. Other packages change quickly. Statements about them reflect their documentation at the time of writing, so check their current docs.

## At a glance

| | flutter_llm_router | Vendor SDK or raw HTTP | Genkit Dart | LangChain.dart | llm_sdk |
| --- | --- | --- | --- | --- | --- |
| Main goal | Reliable chat with failover and cost tracking | Access to one vendor | Google's AI app framework | General LLM framework: chains, RAG, agents | Multi-provider SDK |
| Drop-in `LlmChatView` provider | Yes | No (write an `LlmProvider` yourself) | Check their docs | Check their docs | Check their docs |
| Cross-vendor failover in streams | Yes, including stalled streams and in-band errors | No | Check their docs for fallback middleware | Check their docs | Check their docs |
| Retry, circuit breaker, budgets | Yes, opt-in | Retry in some SDKs | Retry middleware documented | Check their docs | Check their docs |
| Live cost tracking | Yes | No | Check their docs | Check their docs | Check their docs |
| Tool calling | Not yet (planned for 2.0) | Yes, per vendor | Yes | Yes | Yes |
| Structured output | Not yet (planned for 2.0) | Yes, per vendor | Yes | Yes | Yes |
| Embeddings, RAG | No | Per vendor | Yes | Yes | Check their docs |
| Runs outside Flutter | No (needs Flutter today) | Yes | Yes | Yes | Yes |

## Calling vendor SDKs or HTTP directly

Simplest, and you get every vendor feature on release day. You also own failover, retries, timeouts for stalled streams, error classification, cancellation, and cost tracking. Choose this if you use one vendor and an outage is acceptable.

## Genkit Dart

Google-backed, with flows, tools, structured output, and a developer UI. Its Dart docs describe middleware, including retry. At the time of writing, the fallback middleware we found was documented for Genkit Go, not Dart. Check the current docs. Choose Genkit if you want a full framework, especially with Firebase and Gemini.

You can combine them. Use Genkit on your server and point this router's `baseUrl` at it, or use this router in the app and Genkit for server-side flows.

## LangChain.dart

A broad framework: chains, retrieval, vector stores, agents, and many integrations. More to learn and more dependencies. Choose it if you are building RAG or agent pipelines. This package deliberately doesn't try to be a framework.

## llm_sdk

A multi-provider SDK. Its docs list tool calling, typed structured output, and local servers. Choose it if you need those features today and handle reliability yourself.

## When not to use this package

- **You need tool calling or structured output now.** These are planned for 2.0, not available in 1.x.
- **You need embeddings or RAG.** Out of scope.
- **You need it on a server or CLI without Flutter.** The package depends on Flutter and Flutter AI Toolkit today. A pure-Dart core is planned for 2.0.
- **You use one vendor and accept its downtime.** The vendor SDK is simpler.
- **You need every vendor-specific parameter.** The router covers common settings. Use `customAdapters` or the vendor SDK for the rest.
- **You need WASM builds today.** The `flutter_ai_toolkit` dependency currently prevents WASM compatibility.

## Where this package fits

Use it when users see your chat and an outage, rate limit, revoked key, or retired model must not break it. Also use it when you need to show or cap spend and see which provider answered. It covers the failure classes that matter in streaming chat: HTTP statuses, stalled streams, error events inside a 200 response, empty and filtered replies, offline devices, cancellation, and dispose during a stream.
