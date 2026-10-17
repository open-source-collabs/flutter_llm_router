import 'dart:js_interop';

@JS('fetch')
external JSPromise<JSAny?> _fetch(JSString url, _RequestInit init);

extension type _RequestInit._(JSObject _) implements JSObject {
  external factory _RequestInit({
    JSString method,
    JSString mode,
    JSString cache,
  });
}

/// Fetches [url] in `no-cors` mode and completes with `true` on any response.
///
/// A `no-cors` request resolves with an opaque response whenever the host
/// answers, so cross-origin probes work without CORS headers. The browser
/// rejects the promise only when the host is unreachable, and that rejection
/// propagates as an error for the caller to map to offline.
Future<bool> probeReachable(Uri url) async {
  await _fetch(
    url.toString().toJS,
    _RequestInit(
      method: 'HEAD'.toJS,
      mode: 'no-cors'.toJS,
      cache: 'no-store'.toJS,
    ),
  ).toDart;
  return true;
}
