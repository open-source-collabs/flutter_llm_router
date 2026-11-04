# Security Policy

## Supported versions

Security fixes go into the latest release on pub.dev.

## Reporting a vulnerability

Please do not open a public issue. [Report it privately through GitHub](https://github.com/open-source-collabs/flutter_llm_router/security/advisories/new), with the affected version and steps to reproduce.

We aim to acknowledge reports within 7 days and will keep you updated until the issue is resolved.

## API keys

Keys shipped in a client app can be extracted, including keys passed through `--dart-define`. This is how client apps work, not a vulnerability in this package. For production apps that use your own keys, run a backend proxy. See [Protecting API Keys](README.md#protecting-api-keys).

Reports are in scope if this package exposes a key in some other way, such as writing it to `AttemptLog`, an exception, or a request to the wrong host.
