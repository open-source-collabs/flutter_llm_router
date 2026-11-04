# Reliability benchmark

This page reports what failover buys you under a reproducible, simulated failure load. It is a check that the router handles every failure class correctly, not a measurement of any vendor's real uptime.

## Setup

[`test/chaos/chaos_benchmark_test.dart`](../test/chaos/chaos_benchmark_test.dart) sends 2,000 requests through each of three setups. Every simulated provider fails 20% of its calls, independently of the others. A failing call picks one of eight failure classes at random, with equal odds:

| Failure class | What the provider does |
|---|---|
| Rate limited | HTTP 429 |
| Server error | HTTP 503 |
| Bad key | HTTP 401 (provider-scoped) |
| Timeout | No response in time |
| Connection drop | The connection fails before any text |
| In-band error | An error event inside a 200 stream |
| Empty reply | The stream ends with no text |
| Drop after text | Some text arrives, then the connection drops |

The random seed is fixed at 42, so every run gives the same numbers. To reproduce them:

```sh
flutter test test/chaos --reporter expanded
```

## Results

| Setup | Succeeded | Failed after partial text | Failed | Unclassified errors | Hung |
|---|---|---|---|---|---|
| 1 provider | 79.8% | 2.1% | 18.1% | 0 | 0 |
| 3 providers, failover | 96.4% | 2.8% | 0.8% | 0 | 0 |
| 3 providers, failover + 1 retry | 97.2% | 2.8% | 0.1% | 0 | 0 |

## What the numbers mean

- **Failover covers every class it should.** The three-provider chain recovers from seven of the eight classes whenever another provider is healthy. With independent 20% failures, almost all of the remaining failures are the eighth class.
- **"Failed after partial text" is unrecoverable by design.** Once text has been shown, switching providers would restart or duplicate the reply. The router stops and raises the error, and the partial reply is still billed. Roughly 1 in 40 failing calls fall in this class in this simulation (one class in eight, at 20%).
- **No failure escaped.** Every failed request ended with an `LlmRouterException` subclass. None threw a raw transport error or a `TypeError`, and none hung. The test fails if either count is above zero.
- **Retries help a little here.** Retries matter more for correlated failures, such as one provider rate limiting several requests in a row. This simulation doesn't model that, because its failures are independent.

## Limits

- Real outages are correlated: a vendor that is down is down for every request for a while. Failover still helps, and `CircuitBreakerPolicy` keeps a dead provider from costing a round trip on every request. Correlated outages aren't simulated here.
- Latency and cost aren't measured. Each failover adds the failed attempt's latency, and attempts that streamed text or reported usage are billed.
- The nightly contract tests (`.github/workflows/contract.yml`) cover real vendor behaviour separately.
