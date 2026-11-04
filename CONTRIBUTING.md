# Contributing

Thanks for helping improve `flutter_llm_router`. Open an issue before starting a large change, so we can agree on the approach first.

## Setup

You need Flutter 3.32.0 or later.

```sh
git clone https://github.com/open-source-collabs/flutter_llm_router.git
cd flutter_llm_router
flutter pub get
```

## Before you open a pull request

```sh
dart format .
flutter analyze
flutter test
```

CI runs these checks, tests on the minimum supported Flutter version, and builds the example app.

## Guidelines

- Add tests for every behaviour change. Tests must not call real provider APIs. Use `MockClient` from `package:http/testing.dart`.
- Keep `lib/` free of `dart:io` imports outside `probe_native.dart`, so the package still compiles for web.
- Document every public API member.
- Never log API keys or put them in exceptions.
- Add user-visible changes to `CHANGELOG.md`.

## Adding a provider

Extend `BaseLlmAdapter` and implement `streamCompletion`. Use `postSse` and `decodeSseObject` so the provider gets the shared status mapping and SSE handling. Emit `AdapterText` for text and `AdapterUsage` for token counts. See `lib/src/adapters/anthropic_adapter.dart` for an example.

## Releases

Maintainers release by updating `version` and `CHANGELOG.md`, then pushing a tag such as `v1.2.0`. The tag must match the version in `pubspec.yaml`. CI then publishes to pub.dev.
