import 'package:http/http.dart' as http;

/// Sends a `HEAD` request to [url] and completes with `true` on any response.
///
/// Connection failures propagate as errors for the caller to map to offline.
Future<bool> probeReachable(Uri url) async {
  final client = http.Client();
  try {
    await client.head(url);
    return true;
  } finally {
    client.close();
  }
}
