# Changelog

Notable changes to SwiftOrc are documented here. The project follows
semantic versioning; until 1.0, minor releases may include source-breaking API
refinements when they are clearly documented.

## 0.1.0 - Unreleased

### Added

- Strongly typed workflow nodes, transitions, branching, validation, recovery,
  bounded parallel execution, retries, cooperative timeouts, tracing, artifacts,
  and checkpoints.
- Provider-neutral language-model requests and responses, typed structured
  output, capability-aware routing, ordered provider fallback, typed usage and
  finish reasons, and incremental streaming.
- Tool definitions, execution policies, category and safety-level access rules,
  optional user approval coordination, and provider tool-call support.
- Apple Foundation Models integration for stateless requests, tool calling,
  native streaming, prewarming, and explicitly stateful conversations.
- An OpenAI-compatible Chat Completions adapter with injectable HTTP transport,
  privacy-safe provider errors, tool calling, usage metadata, and SSE streaming.
- Deterministic scripted models and workflow probes in the optional
  `SwiftOrcTesting` product.
- Read-only declared-graph introspection for developer tooling and diagnostics.

### Design defaults

- Advanced features remain opt-in; the minimal workflow needs only state and a
  node.
- Unknown application errors are sanitized before entering persistent workflow
  state or traces.
- Router fallback is allowed during streaming only before visible text has been
  emitted, preventing output from different providers from being mixed.
- Model capability metadata is supplied by the application; adapters do not
  automatically discover or remotely refresh it.

### Known limitations

- Timeouts and cancellation are cooperative and cannot forcibly stop code that
  ignores Swift task cancellation.
- Checkpoints resume at workflow-node boundaries; arbitrary mid-node execution
  is not durably resumed.
- Apple Foundation Models are selected by the operating system. The package
  cannot pin historical Apple model versions.
- Structured Apple streaming is intentionally unavailable because cumulative
  structured snapshots may rewrite prior content and cannot safely be exposed
  as append-only text deltas.
- The package does not include autonomous planning, RAG, vector storage, prompt
  optimization, provider credential UI, or domain-specific services.
