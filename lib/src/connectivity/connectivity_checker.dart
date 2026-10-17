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
  /// Implementations must not throw. Report any failure as `false`.
  Future<bool> hasInternet();
}

/// [ConnectivityChecker] that sends a lightweight request to [probeUrl].
///
/// Any HTTP response, whatever its status, counts as online. A connection
/// error, or no response within [timeout], counts as offline.
///
/// On native platforms the probe is a `HEAD` request. On web it is a
/// `no-cors` `fetch`, so the browser's CORS policy does not make a reachable
/// host look unreachable.
class HttpConnectivityChecker implements ConnectivityChecker {
  /// Creates a checker that probes [probeUrl], defaulting to
  /// [defaultProbeUrl].
  ///
  /// Pass a different [probeUrl] where Google is blocked. When [client] is
  /// provided, the probe is a `HEAD` request through it on every platform,
  /// and the caller keeps ownership of the client.
  HttpConnectivityChecker({
    Uri? probeUrl,
    this.timeout = const Duration(seconds: 3),
    http.Client? client,
  })  : probeUrl = probeUrl ?? defaultProbeUrl,
        _client = client;

  /// Google's empty `204 No Content` endpoint, used when no [probeUrl] is
  /// given.
  static final Uri defaultProbeUrl =
      Uri.parse('https://www.google.com/generate_204');

  /// URL the probe requests.
  final Uri probeUrl;

  /// How long the probe waits for a response before reporting offline.
  final Duration timeout;

  final http.Client? _client;

  @override
  Future<bool> hasInternet() async {
    final client = _client;
    try {
      final probe = client == null
          ? probeReachable(probeUrl)
          : client.head(probeUrl).then((_) => true);
      return await probe.timeout(timeout);
    } on Object {
      // The contract is to never throw: timeouts, socket errors, and browser
      // fetch rejections all mean the probe host could not be reached.
      return false;
    }
  }
}
