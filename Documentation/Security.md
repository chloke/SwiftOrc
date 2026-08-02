# Security

SwiftOrc's core and Apple Foundation Models products do not initiate
arbitrary network requests. Networking is opt-in through the separate
`SwiftOrcOpenAICompatible`, `SwiftOrcResponsesCompatible`, or
`SwiftOrcAnthropic` products, or through application-supplied models
and tools.

## Secure defaults

The bundled HTTP adapter:

- requires HTTPS, except for explicitly enabled loopback development servers;
- rejects endpoint URLs containing user information or fragments;
- uses an ephemeral session without shared cookies, credentials, or cache;
- follows redirects only within the original scheme, host, and effective port;
- bounds encoded requests, complete responses, stream events, total stream
  bytes, and stream event count;
- omits provider error messages unless an application explicitly opts in;
- resolves dynamic request headers only when a request is made.

Custom transports and sessions are supported for testing and specialized
deployments. Their TLS trust, redirect, caching, cookie, credential, proxy, and
resource-limit behavior belongs to the application.

## Untrusted model output

Treat generated text, structured values, tool names, tool arguments, provider
metadata, and remote URLs as untrusted input. SwiftOrc exposes only
registered tools and enforces configured access and approval policies, but each
tool must still validate its decoded arguments and enforce authorization at the
underlying data or service boundary.

Diagnostic tool events use local call numbers rather than provider call IDs.
Ordinary error descriptions are redacted. `WorkflowFailure` is the explicit
escape hatch for an application-reviewed public message and must never contain
prompts, credentials, generated output, tool arguments, or private user data.

## Credentials and persistence

Do not embed a long-lived provider credential that must remain secret in a
distributed application. Resolve credentials from Keychain at request time and
prefer short-lived tokens or an application-owned gateway.

Built-in JSON checkpoints and directory artifacts are bounded but plaintext.
Place them in an application-owned protected container, apply the platform's
data-protection and backup policies, or implement a custom encrypted store.

## Reporting

Do not include sensitive user data in a vulnerability report. Do not disclose
an unpatched vulnerability through a public issue. Follow the private process
in the repository's [security policy](../SECURITY.md).
