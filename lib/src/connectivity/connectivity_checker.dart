import 'dart:async';

import 'package:http/http.dart' as http;

import 'probe_native.dart' if (dart.library.js_interop) 'probe_web.dart';

/// Decides whether the device can reach the internet at all.
///
/// `RouterLlmProvider` asks this after a provider fails with a connection
/// error or timeout. `false` means the device is offline, so the router stops
/// the chain with `NoInternetConnectionException`. `true` means only that
/// provider is unreachable, so the router fails over to the next one.
abstract interface class ConnectivityChecker {
  /// Completes with `true` when the internet is reachable.
  ///
  /// Implementations must not throw. Report `false` only when the device is
  /// clearly offline, because `false` stops the whole chain.
  Future<bool> hasInternet();
}

/// [ConnectivityChecker] that always reports online, which turns the
/// offline check off. The router then always fails over.
class AssumeOnlineConnectivityChecker implements ConnectivityChecker {
  /// Creates a checker that never reports offline.
  const AssumeOnlineConnectivityChecker();

  @override
  Future<bool> hasInternet() async => true;
}

/// [ConnectivityChecker] that sends a lightweight request to [probeUrl].
///
/// Any HTTP response, whatever its status, counts as online. When the probe
/// fails with a connection error and no [probeUrl] was given, a second probe
/// goes to [fallbackProbeUrl], so a network that blocks one host does not
/// look offline. The device is reported offline only when every probe fails
/// with a connection error. A probe that gets no answer within [timeout] is
/// inconclusive and counts as online, so a slow network still fails over.
///
/// On native platforms the probe is a `HEAD` request. On web it is a
/// `no-cors` `fetch`, so the browser's CORS policy does not make a reachable
/// host look unreachable.
class HttpConnectivityChecker implements ConnectivityChecker {
  /// Creates a checker that probes [probeUrl], defaulting to
  /// [defaultProbeUrl] with [fallbackProbeUrl] as a second try.
  ///
  /// Pass a different [probeUrl] where Google is blocked or must not be
  /// contacted. A custom [probeUrl] has no fallback. When [client] is
  /// provided, the probe is a `HEAD` request through it on every platform,
  /// and the caller keeps ownership of the client.
  HttpConnectivityChecker({
    Uri? probeUrl,
    this.timeout = const Duration(seconds: 3),
    http.Client? client,
  }) : probeUrl = probeUrl ?? defaultProbeUrl,
       _probeUrls = probeUrl == null
           ? <Uri>[defaultProbeUrl, fallbackProbeUrl]
           : <Uri>[probeUrl],
       _client = client;

  /// Google's empty `204 No Content` endpoint, used when no [probeUrl] is
  /// given.
  static final Uri defaultProbeUrl = Uri.parse(
    'https://www.google.com/generate_204',
  );

  /// Cloudflare's empty `204 No Content` endpoint, probed when
  /// [defaultProbeUrl] cannot be reached.
  static final Uri fallbackProbeUrl = Uri.parse(
    'https://cp.cloudflare.com/generate_204',
  );

  /// URL the probe requests first.
  final Uri probeUrl;

  /// How long each probe waits for a response before it is inconclusive.
  final Duration timeout;

  final List<Uri> _probeUrls;
  final http.Client? _client;

  @override
  Future<bool> hasInternet() async {
    for (final url in _probeUrls) {
      final client = _client;
      try {
        final probe = client == null
            ? probeReachable(url)
            : client.head(url).then((_) => true);
        if (await probe.timeout(timeout)) return true;
      } on TimeoutException {
        return true;
      } on Object {
        // The contract is to never throw: socket errors and browser fetch
        // rejections mean this host could not be reached. Try the next one.
      }
    }
    return false;
  }
}
