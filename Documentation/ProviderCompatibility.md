# Provider compatibility

SwiftOrc keeps workflow behavior provider-neutral, but remote APIs do not all
use the same wire protocol. Select the smallest optional product matching the
endpoint you actually call.

All remote adapters depend on the small `SwiftOrcHTTP` product for dynamic
credential headers, the isolated URLSession transport, endpoint policy,
resource limits, retries, and redacted events. They do not depend on one
another.

| Provider or server | SwiftOrc product | Protocol | Notes |
| --- | --- | --- | --- |
| Apple Foundation Models | `SwiftOrcFoundationModels` | Apple native | On-device; iOS 26+ and macOS 26+ |
| OpenAI Responses | `SwiftOrcResponsesCompatible` | Responses | Stateless requests with `store: false` |
| OpenAI Chat Completions | `SwiftOrcOpenAICompatible` | Chat Completions | Supported for existing integrations |
| Anthropic | `SwiftOrcAnthropic` | Messages | Native Messages request and SSE shapes |
| Google Gemini | `SwiftOrcOpenAICompatible` | Gemini's OpenAI compatibility endpoint | Common Chat Completions subset |
| Ollama | `SwiftOrcOpenAICompatible` | OpenAI compatibility endpoint | Common local-development choice |
| LM Studio | `SwiftOrcOpenAICompatible` | OpenAI compatibility endpoint | Common local-development choice |
| Azure OpenAI / Foundry | `SwiftOrcOpenAICompatible` | Deployment-specific Chat Completions endpoint | Supply the full endpoint and required headers |
| Custom gateway or self-hosted server | Usually `SwiftOrcOpenAICompatible` | Server-defined | Use Responses only when the server implements that shape |

These are adapter contracts, not a promise that every model behind an endpoint
supports every feature. Declare each configured route's capabilities from the
model and provider combination you tested. SwiftOrc deliberately does not query
provider metadata at runtime.

## OpenAI Responses

Add `SwiftOrcResponsesCompatible` and keep the API key application-owned:

```swift
import SwiftOrcResponsesCompatible

let model = try ResponsesCompatibleLanguageModel(
    providerIdentifier: "openai-responses",
    endpoint: ResponsesCompatibleLanguageModel.openAIEndpoint,
    modelIdentifier: "your-model-id",
    headers: .bearerToken(resolve: {
        try await secrets.openAIKey()
    })
)
```

The adapter sends explicit input items, `instructions`, client function tools,
structured-output configuration, and `store: false`. It does not use
`previous_response_id`, hosted tools, or provider-managed conversations. This
keeps retries, routing, checkpoints, and fallback governed by application state.

## OpenAI Chat Completions

```swift
import SwiftOrcOpenAICompatible

let model = try OpenAICompatibleLanguageModel(
    providerIdentifier: "openai-chat",
    endpoint: OpenAICompatibleLanguageModel.openAIEndpoint,
    modelIdentifier: "your-model-id",
    headers: .bearerToken(resolve: {
        try await secrets.openAIKey()
    })
)
```

OpenAI recommends Responses for new OpenAI integrations, but Chat Completions
remains useful for existing applications and compatible third-party servers.

## Anthropic Messages

```swift
import SwiftOrcAnthropic

let model = try AnthropicLanguageModel(
    modelIdentifier: "your-claude-model-id",
    headers: .anthropicAPIKey(resolve: {
        try await secrets.anthropicKey()
    })
)
```

The native adapter supports text and image input, explicit conversation turns,
client function tools, structured JSON output, usage, finish reasons, retries,
and text streaming. Anthropic-hosted tools, prompt caching, extended thinking,
and provider-managed agent state are intentionally outside the neutral adapter.

## Google Gemini through OpenAI compatibility

```swift
let model = try OpenAICompatibleLanguageModel(
    providerIdentifier: "gemini",
    endpoint: URL(
        string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
    )!,
    modelIdentifier: "your-gemini-model-id",
    headers: .bearerToken(resolve: {
        try await secrets.geminiKey()
    })
)
```

A native Gemini adapter is useful only when an app needs native-only features
that cannot be represented by `LanguageModelRequest`. A provider wrapper would
otherwise add API surface without improving workflow behavior.

## Ollama

```swift
let model = try OpenAICompatibleLanguageModel(
    providerIdentifier: "ollama",
    endpoint: URL(string: "http://127.0.0.1:11434/v1/chat/completions")!,
    modelIdentifier: "your-installed-model",
    endpointSecurityPolicy: .allowInsecureLoopback
)
```

Cleartext HTTP is accepted only for loopback. On a physical iPhone,
`127.0.0.1` is the phone itself—not a Mac running Ollama. Use a deliberately
secured LAN or gateway configuration for cross-device development rather than
weakening SwiftOrc's endpoint policy.

## LM Studio

LM Studio uses the same adapter with its configured port:

```swift
let model = try OpenAICompatibleLanguageModel(
    providerIdentifier: "lm-studio",
    endpoint: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
    modelIdentifier: "your-loaded-model",
    endpointSecurityPolicy: .allowInsecureLoopback
)
```

## Azure OpenAI or Foundry

Azure endpoint paths, deployment identifiers, and API versions vary by the
resource configuration. Pass the complete endpoint supplied by Azure and
resolve its header at request time:

```swift
import SwiftOrcHTTP
import SwiftOrcOpenAICompatible

let headers = HTTPRequestHeaders {
    ["api-key": try await secrets.azureKey()]
}

let model = try OpenAICompatibleLanguageModel(
    providerIdentifier: "azure-primary",
    endpoint: azureChatCompletionsEndpoint,
    modelIdentifier: azureDeploymentOrModelIdentifier,
    headers: headers
)
```

If an Azure deployment exposes a different native or Responses-compatible
shape, select the matching adapter rather than assuming all Azure endpoints are
interchangeable.

## Custom gateways

The endpoint, model identifier, dynamic headers, extra headers, timeout, retry
policy, resource limits, and transport are configurable. This covers many
company gateways and self-hosted servers without a provider-branded wrapper.

Before declaring a route production-ready, test the exact server and model for:

- message ordering and instruction roles;
- image media types and size limits;
- JSON-schema support;
- function-tool schema and tool-choice behavior;
- streaming event compatibility;
- reported token usage and finish reasons;
- retry status codes and rate-limit headers.

Do not put long-lived provider secrets in a distributed app when they must
remain confidential. Prefer short-lived credentials or an application-owned
gateway, and resolve credentials at request time from Keychain or another
application-owned secret store.

Protocol references:

- [OpenAI Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Anthropic Messages API](https://platform.claude.com/docs/en/api/messages/create)
- [Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)
- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)
