# flutter_llm_router example

Chat demo for the router. Every hop uses the built-in `openrouter` adapter (`https://openrouter.ai/api/v1`), so one key can exercise the failover chain:

1. `openai/gpt-4o-mini`
2. `google/gemini-2.5-flash`
3. `anthropic/claude-haiku-4.5`

Enter the OpenRouter key from the key icon. Leave both switches off to stay on the first model. Turn on **Simulate primary outage (HTTP 429)** to land on Gemini. Turn on **Also fail Gemini** as well to land on Anthropic. The app bar shows conversation spend. The receipt icon lists attempt latency, provider name, and error status.

Direct OpenAI, Gemini, and Anthropic credentials stay on the package adapters. This example does not call those vendor APIs.

## Running the Example

### Windows Desktop
```sh
flutter run -d windows
```
> Note: Building the Windows desktop runner requires Visual Studio with the "Desktop development with C++" workload.

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

### Connected Mobile Device or Emulator
```sh
flutter run
```
