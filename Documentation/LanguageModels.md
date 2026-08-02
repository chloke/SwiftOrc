# Language models

Import only the adapters an application uses:

```swift
import SwiftOrc
import SwiftOrcFoundationModels
import SwiftOrcHTTP
import SwiftOrcOpenAICompatible
import SwiftOrcResponsesCompatible
import SwiftOrcAnthropic
```

## Providers and fallback

Any `WorkflowLanguageModel` can be used directly. Add a router only when the app
has more than one route:

```swift
let remote = try OpenAICompatibleLanguageModel(
    providerIdentifier: "company-primary",
    endpoint: URL(string: "https://models.example.com/v1/chat/completions")!,
    modelIdentifier: "production-model",
    headers: .bearerToken(resolve: {
        try await secrets.primaryAPIKey()
    })
)

let router = try LanguageModelRouter(routes: [
    LanguageModelRoute(
        provider: "company-primary",
        kind: .remote,
        capabilities: [
            .textInput,
            .imageInput,
            .structuredOutput,
            .toolCalling,
            .streaming,
        ],
        model: remote
    ),
    LanguageModelRoute(
        provider: AppleFoundationModel.providerIdentifier,
        kind: .onDevice,
        capabilities: [
            .textInput,
            .structuredOutput,
            .toolCalling,
        ],
        model: AppleFoundationModel()
    ),
    LanguageModelRoute(
        provider: "static-copy",
        kind: .staticFallback,
        model: StaticLanguageModel(content: "Please try again later.")
    ),
])
```

Credentials remain application-owned and should be resolved from Keychain or
another secret store only when a request is made. A long-lived provider secret
embedded in a distributed app can be extracted; use short-lived credentials or
an application-owned gateway when the credential must remain confidential.

Choose the adapter that matches the provider's actual wire protocol:

- `OpenAICompatibleLanguageModel` for Chat Completions-compatible endpoints;
- `ResponsesCompatibleLanguageModel` for the stateless Responses API shape;
- `AnthropicLanguageModel` for Anthropic's native Messages API;
- `AppleFoundationModel` for Apple's on-device model.

See [Provider compatibility](ProviderCompatibility.md) for configurations for
OpenAI, Anthropic, Gemini, Ollama, LM Studio, Azure, and custom gateways.

The OpenAI-compatible adapter accepts HTTPS by default. Local development
servers can be enabled explicitly without allowing arbitrary cleartext hosts:

```swift
let local = try OpenAICompatibleLanguageModel(
    providerIdentifier: "local",
    endpoint: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
    modelIdentifier: "local-model",
    endpointSecurityPolicy: .allowInsecureLoopback
)
```

The bundled transport uses an isolated session without shared cache, cookies,
or credential storage and follows only same-origin redirects. Injecting a
custom `URLSession` or `HTTPModelTransport` transfers those security decisions
to the application. Request, response, streaming-event, total-stream, and event
count limits are enforced through `HTTPModelResourceLimits`.

## Developer-declared capabilities

Capabilities are configuration. The framework never contacts an API or reads
provider metadata to discover them.

The router infers these requirements:

| Request feature | Capability |
| --- | --- |
| Any request | `textInput` |
| Image content | `imageInput` |
| JSON schema | `structuredOutput` |
| Enabled tools | `toolCalling` |
| Requested parallel tools | `parallelToolCalling` |
| Explicit message history | `conversationHistory` |
| A streaming router request | `streaming` |

Apps can add an exact custom requirement:

```swift
LanguageModelRequest(
    prompt: "Check this image.",
    requiredCapabilities: ["content-moderation"],
    input: [imageInput]
)
```

Incompatible declared routes are skipped before invocation. Their routing
attempt records `missingCapabilities`. Routes that omit capabilities remain
`.unspecified`, preserving normal attempt-and-fallback behavior. This is useful
for migration and deterministic fallback responses.

## Typed structured output

Define a `Decodable` output and its provider-neutral schema:

```swift
struct CharacterProfile: LanguageModelStructuredOutput {
    let name: String
    let temperament: String

    static let languageModelSchema = LanguageModelJSONSchema(
        name: "character_profile",
        schema: .objectSchema(
            properties: [
                "name": .object(["type": .string("string")]),
                "temperament": .object(["type": .string("string")]),
            ],
            required: ["name", "temperament"]
        )
    )
}
```

`StructuredLanguageModelNode<AppState, CharacterProfile>` asks the selected
provider for schema-guided output and decodes it before the state reducer runs.
Decoding errors omit the raw response. Remote adapters translate the neutral
schema into their protocol's structured-output format; Apple uses native
`GenerationSchema` guidance.

## Images and artifacts

Keep binary data outside Codable workflow state:

```swift
let store = try DirectoryWorkflowArtifactStore(
    directoryURL: applicationSupportURL.appending(path: "Artifacts")
)

let run = try await workflow.run(initialState, artifactStore: store)
```

A node stores bytes and keeps only the returned `WorkflowArtifact` descriptor:

```swift
state.image = try await context.storeArtifact(
    imageData,
    options: WorkflowArtifactWriteOptions(
        mediaType: "image/jpeg",
        source: .userProvided
    )
)
```

Resolve them only for the request that needs them:

```swift
let input = try await context.imageInput(for: state.image, detail: .high)
return LanguageModelRequest(prompt: "Inspect this image.", input: [input])
```

The remote adapters support inline data and HTTP(S) image URLs with size
validation. Remote image URLs are sent to the configured provider rather than
fetched by SwiftOrc. Validate or allowlist user-controlled URLs and prefer
HTTPS, because the provider or gateway is responsible for preventing
server-side request forgery. Apple's current Foundation Models prompt API is
text-only, so its adapter explicitly rejects image input instead of discarding
it.

## Stateless and conversational Apple sessions

`AppleFoundationModel` creates a fresh Apple session for every request. This is
the safest default for independent workflow nodes: transcripts cannot leak
between executions. It rejects explicit `LanguageModelRequest.messages`
instead of silently flattening or dropping their roles.

Use one `AppleFoundationModelConversation` actor per app-managed conversation
when Apple should retain its native transcript:

```swift
let conversation = AppleFoundationModelConversation(
    instructions: "Be concise and friendly."
)

try await conversation.prewarm(promptPrefix: "Hello")
let response = try await conversation.generate(
    LanguageModelRequest(prompt: "Remember that my favorite color is green.")
)

try await conversation.reset()
```

The actor serializes overlapping requests because Apple sessions reject
concurrent generation. `reset()` waits for in-flight work and replaces the
session, discarding its transcript. Explicit message arrays, structured output,
and tools are deliberately unavailable on this stateful adapter; use the
stateless adapter or another provider when those request features are needed.

## Streaming

Streaming is a separate opt-in protocol, so ordinary models and nodes remain
unchanged:

```swift
let node = StreamingLanguageModelNode<AppState>(
    id: "draft",
    model: router,
    request: { state, _ in
        LanguageModelRequest(prompt: state.prompt)
    },
    onDelta: { delta, _ in
        await display.append(delta)
    },
    reduce: { response, state, _ in
        var state = state
        state.answer = response.content
        return .finish(state)
    }
)
```

`AppleFoundationModel` converts cumulative text snapshots into deltas and fails
if a snapshot unexpectedly rewrites prior text. Apple structured-output
streaming is intentionally rejected because evolving JSON snapshots cannot be
represented safely as append-only text deltas.

The three remote adapters consume their protocol's server-sent events when the
transport conforms to `HTTPStreamingModelTransport`. The bundled URLSession
transport does. Streaming tool calls are not currently supported; ordinary
non-streaming tool loops remain available. Provider-internal HTTP retries are
not attempted once streaming begins.

`LanguageModelRouter` is also streaming-aware. It may advance to another route
only if the failed provider has emitted no text. After the first delta, routing
stops on failure so an application never receives text mixed from two models.

## Usage and finish reasons

A response can expose provider-neutral `usage` and `finishReason` values in
addition to its extensible metadata dictionary. Fields remain optional because
Apple and some compatible APIs do not report token accounting. Unknown finish
reasons are preserved through `LanguageModelFinishReason(rawValue:)`.
