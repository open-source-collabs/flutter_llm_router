# Backend proxy

## Why

Anything shipped in a client app can be read by the person holding the device. That includes API keys in source, keys passed through `--dart-define`, and keys in obfuscated or web builds. Tools that unpack an APK or read a web bundle find them in minutes. A leaked key lets anyone spend on your account until you revoke it.

Direct keys are fine for local development and for apps where each user enters their own key. For an app that uses your keys, put a small server between the app and the vendors. The server:

- holds the real vendor keys,
- checks who is calling, using your app's sign-in,
- enforces per-user rate and spend limits,
- forwards the request and streams the response back.

## Pointing the router at a proxy

Set `baseUrl` to the proxy and send the user's session token in `headers`. A header with a built-in name, such as `authorization` or `x-api-key`, replaces the built-in one, so the app never sends a vendor key:

```dart
RouterLlmProvider(
  providers: [
    ProviderConfig(
      name: 'openai',
      apiKey: '', // The proxy adds the real key.
      model: 'gpt-4o-mini',
      pricePerInputToken: 0.00000015,
      pricePerOutputToken: 0.0000006,
      baseUrl: 'https://api.example.com/llm/openai/v1',
      headers: {'authorization': 'Bearer $sessionToken'},
    ),
    ProviderConfig(
      name: 'anthropic',
      apiKey: '',
      model: 'claude-3-5-haiku-latest',
      pricePerInputToken: 0.0000008,
      pricePerOutputToken: 0.000004,
      baseUrl: 'https://api.example.com/llm/anthropic/v1',
      headers: {'authorization': 'Bearer $sessionToken'},
    ),
  ],
);
```

The adapters still send each vendor's JSON shape and append the vendor path (`chat/completions`, `messages`, or `models/{model}:streamGenerateContent?alt=sse`). The proxy only has to swap credentials and forward the request.

Failover still works through a proxy, as long as the proxy passes through the vendor's HTTP status and streams the body unchanged. A proxy that turns every error into a 500 hides bad keys and quota errors, and they get retried instead of skipped.

## Sketch: Cloudflare Worker

This is a sketch, not a hardened server. Add real authentication, per-user limits, logging, and error handling before using it.

```js
// Routes /llm/openai/* to OpenAI and /llm/anthropic/* to Anthropic.
export default {
  async fetch(request, env) {
    const user = await verifySession(request.headers.get('authorization'), env);
    if (!user) return new Response('Unauthorized', { status: 401 });

    const url = new URL(request.url);
    const headers = new Headers(request.headers);
    headers.delete('authorization');
    let upstream;

    if (url.pathname.startsWith('/llm/openai/')) {
      upstream = 'https://api.openai.com/' + url.pathname.slice('/llm/openai/'.length);
      headers.set('authorization', `Bearer ${env.OPENAI_KEY}`);
    } else if (url.pathname.startsWith('/llm/anthropic/')) {
      upstream = 'https://api.anthropic.com/' + url.pathname.slice('/llm/anthropic/'.length);
      headers.set('x-api-key', env.ANTHROPIC_KEY);
    } else {
      return new Response('Not found', { status: 404 });
    }

    // Stream the body through unchanged so SSE and status codes reach the app.
    return fetch(upstream + url.search, {
      method: request.method,
      headers,
      body: request.body,
    });
  },
};

async function verifySession(authorization, env) {
  // Check the token against your auth provider and apply per-user limits.
  return null;
}
```

For web builds, the proxy must also answer CORS preflight requests from your app's origin.

## Sketch: Dart with shelf

The same idea in Dart. This sketch also needs `package:shelf`, `package:shelf_router`, and `package:http`.

```dart
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

final _client = http.Client();

Future<Response> proxyOpenAi(Request request, String path) async {
  if (!await isSignedIn(request.headers['authorization'])) {
    return Response(401);
  }
  final upstream = http.StreamedRequest(
    request.method,
    Uri.https('api.openai.com', path, request.url.queryParameters),
  )
    ..headers['content-type'] = 'application/json'
    ..headers['authorization'] = 'Bearer ${const String.fromEnvironment('OPENAI_KEY')}';
  request.read().listen(
    upstream.sink.add,
    onDone: upstream.sink.close,
    onError: upstream.sink.addError,
  );
  final response = await _client.send(upstream);
  // Pass status and stream through unchanged.
  return Response(
    response.statusCode,
    body: response.stream,
    headers: {'content-type': response.headers['content-type'] ?? 'text/event-stream'},
    context: {'shelf.io.buffer_output': false},
  );
}

Future<bool> isSignedIn(String? authorization) async => false; // Replace.
```

`shelf.io.buffer_output: false` makes `shelf_io` flush each chunk, so tokens stream instead of arriving at the end.

## Firebase and Supabase

The same pattern works as a Firebase Cloud Function (HTTP, 2nd gen, with streaming responses) or a Supabase Edge Function. Verify the Firebase ID token or Supabase JWT from the `authorization` header, then forward as above. Check each platform's docs for streaming-response support and timeout limits before relying on long replies.
