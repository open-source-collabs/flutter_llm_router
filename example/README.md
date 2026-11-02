# flutter_llm_router example

Chat demo for the router. It uses direct provider keys and walks this failover chain:

1. OpenAI `gpt-4o-mini`
2. Google Gemini `gemini-2.0-flash`
3. Anthropic `claude-3-5-haiku-20241022`

Enter your keys from the key icon, or pass them at build time with `--dart-define=OPENAI_API_KEY=...`, `GEMINI_API_KEY`, and `ANTHROPIC_API_KEY`. Keys passed this way are embedded in the build, so use them for local development only.

Use the switches to test failover:

- **Simulate OpenAI outage (HTTP 429)** lands on Gemini.
- **Also simulate Gemini outage**, with the switch above, lands on Anthropic.
- **Simulate OpenAI network failure** probes connectivity, then fails over if the device is online. If it is offline, the app shows a "No internet connection" message.

The app bar shows conversation spend. The receipt icon lists attempt latency, provider name, and error status.

## Running the Example

### Windows Desktop
```sh
flutter run -d windows
```
> Note: Building the Windows desktop runner requires Visual Studio with the "Desktop development with C++" workload.

### macOS Desktop
```sh
flutter run -d macos
```
> Note: Building for macOS requires Xcode.

### Linux Desktop
```sh
flutter run -d linux
```
> Note: Building for Linux desktop requires standard GTK build dependencies:
> `sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev`

### Chrome / Web
```sh
flutter run -d chrome
```
> Note: Browsers may block direct calls to some provider APIs (CORS). Use a backend proxy if a provider fails only on web.

### Connected Mobile Device or Emulator
```sh
flutter run
```
