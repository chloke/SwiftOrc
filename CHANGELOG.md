# Changelog

Notable changes to SwiftOrc are documented here.

## 0.5.0 - 2026-10-23

### Fixed

- Anthropic streams that report an `error` event, or end without
  `message_stop`, now fail with `invalidResponse` instead of returning partial
  text as a complete response.
- OpenAI-compatible streams that end without `[DONE]` or a finish reason now
  fail with `invalidResponse` instead of returning truncated output.
- `LanguageModelRouter` and its streaming variant no longer fall back to
  another route after a state-changing tool started inside the failed route,
  which previously ran the tool a second time. Tools whose metadata declares
  only read-only or computational effects still allow fallback.
- `AppleFoundationModel` workflow tool registrations now enforce a
  `maximumToolCalls` limit (default 32). Apple's tool loop previously had no
  bound on tool calls.
- Tool timeouts are enforced even when a tool ignores cancellation. Abandoned
  work keeps its concurrency permit until it stops.
- Anthropic requests keep tool definitions, with a `none` tool choice, when
  tools are disabled but the conversation contains tool history. Previously,
  denying every tool with `.returnToModel` produced a request Anthropic
  rejects.
- `URLSessionHTTPModelTransport()` shares one process-wide session instead of
  creating a delegate-backed session that was never released for every
  adapter.
- `HTTPModelRetryPolicy` retries HTTP 529 (Anthropic "overloaded") by default.

### Compatibility

- `AppleFoundationModel(workflowToolRegistrations:)` gains a defaulted
  `maximumToolCalls` parameter. A single request that previously made more
  than 32 Apple tool calls now fails; pass a higher value, or `.max` to remove
  the bound.
- Existing public enums gain no new cases.
- `LanguageModelToolChoice.none` on an Anthropic request with tools now sends
  the tools with `tool_choice: {"type": "none"}` instead of omitting them.

## 0.4.0 - 2026-08-12

### Added

- `WorkflowExecutionBudget` for limiting node executions or supplying a
  monotonic deadline to one workflow invocation.
- Budgeted `run` and `resume` overloads that return either a completed
  `WorkflowRun` or a resumable `WorkflowContinuation` at a safe node boundary.
- Structured suspension reasons and durable checkpoints that preserve retry
  attempts, recovery history, cumulative step counts, and execution identity
  across invocations.

### Compatibility

- Existing unbudgeted `run` and `resume` overloads are unchanged.
- Existing public enums gain no new cases, preserving exhaustive downstream
  switches.
- Execution deadlines are cooperative boundaries: an in-progress node is not
  interrupted and may run again only if the process terminates before its next
  checkpoint is committed.

## 0.3.0 - 2026-08-03

### Changed

- Removed the temporary 0.1 HTTP type aliases from
  `SwiftOrcOpenAICompatible`. Applications configuring remote transports now
  import the canonical `SwiftOrcHTTP` product directly.

### Fixed

- Apple-native Foundation Models tools now honor explicit tool disabling and
  request-scoped name selection. Requests no longer silently bypass a supplied
  SwiftOrc tool access policy when using native tools.

## 0.2.0 - 2026-08-02

### Added

- `SwiftOrcResponsesCompatible`, a stateless adapter for Responses-compatible
  endpoints with text and image input, structured output, client tools, usage
  metadata, retries, and SSE text streaming.
- `SwiftOrcAnthropic`, a native Anthropic Messages adapter with text and image
  input, conversation turns, structured output, client tools, usage metadata,
  retries, SSE text streaming, and request-time API-key resolution.
- `SwiftOrcHTTP`, a provider-neutral product containing the hardened transport,
  endpoint policy, request headers, retry behavior, resource limits, and
  redacted provider events shared by optional remote adapters.
- Provider configuration guidance for OpenAI, Anthropic, Gemini, Ollama,
  LM Studio, Azure, and custom gateways.

### Changed

- Remote adapters now share the same HTTPS defaults, isolated URLSession
  transport, same-origin redirect policy, bounded payload handling, retries,
  and privacy-conscious diagnostics.
- HTTP request headers can be resolved independently by every remote adapter
  while preserving request-time credential loading.
- Existing `SwiftOrcOpenAICompatible` HTTP configuration names remain available
  through compatibility aliases, so 0.1 integrations do not require import
  changes.

## 0.1.0 - 2026-08-01

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
