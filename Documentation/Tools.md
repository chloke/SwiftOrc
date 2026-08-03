# Model tools

Tools are optional. Applications that do not register tools do not need any of
the APIs in this guide.

## Define a typed tool

```swift
struct AddArguments: Codable, Sendable {
    let left: Int
    let right: Int
}

struct AddResult: Codable, Sendable {
    let sum: Int
}

let add = ClosureLanguageModelTool<AddArguments, AddResult>(
    definition: LanguageModelToolDefinition(
        name: "add",
        description: "Adds two integers.",
        parameters: .objectSchema(
            properties: [
                "left": .object(["type": .string("integer")]),
                "right": .object(["type": .string("integer")]),
            ],
            required: ["left", "right"]
        )
    ),
    call: { AddResult(sum: $0.left + $0.right) }
)

let toolModel = try ToolCallingLanguageModel(model: router, tools: [add])
```

The wrapper runs a bounded provider-neutral tool loop. Arguments are decoded and
results encoded with `Codable`. Tool outputs return to the model in original
call order even when execution is concurrent.
Tool arguments and outputs are each limited to 1 MiB by default. Override
`maximumToolArgumentBytes` or `maximumToolOutputBytes` in
`ToolCallingLanguageModelConfiguration` only for tools that require more.

## Classify access per request

Registration metadata describes what a tool can do:

```swift
let registration = LanguageModelToolRegistration(
    tool: add,
    metadata: LanguageModelToolMetadata(
        categories: [.math],
        risk: .minimal,
        effects: [.localComputation]
    )
)
```

The request decides which matching tools can be used:

```swift
LanguageModelRequest(
    prompt: userInput,
    toolAccessPolicy: LanguageModelToolAccessPolicy(
        rules: [
            LanguageModelToolAccessRule(
                categories: [.math],
                maximumRisk: .low,
                effects: [.localComputation],
                authorization: .automatic
            ),
        ],
        defaultAuthorization: .denied
    )
)
```

The first complete rule match wins. Registration-level approval is a minimum
that request policy cannot weaken.

## Execution policy and approval

Timeouts, retries, and approval are registration options:

```swift
let protected = LanguageModelToolRegistration(
    tool: add,
    policy: LanguageModelToolExecutionPolicy(
        approval: .always,
        timeout: .seconds(2),
        retry: LanguageModelToolRetryPolicy(maximumAttempts: 3)
    )
)

let approvals = LanguageModelToolApprovalCoordinator()
let model = try ToolCallingLanguageModel(
    model: router,
    registrations: [protected],
    approvalHandler: approvals.approvalHandler
)
```

Observe `approvals.updates()` in application state and resolve requests with
`approve(_:)` or `deny(_:)`. Pending approvals contain raw untrusted arguments;
do not copy them into telemetry or ordinary traces.
The framework waits until the application resolves or cancels an approval, so
approval UI should always provide a denial path and clean up pending requests
when its owning task or screen is dismissed.

Expected low-risk implementation details should normally be automatically
authorized by the app's request policy. Manual confirmation is for actions a
user reasonably expects to approve, not routine calculations or weather reads.

## Apple Foundation Models

Pass the same registrations to the Apple adapter when using its native tool
loop:

```swift
let apple = try AppleFoundationModel(
    workflowToolRegistrations: [protected],
    approvalHandler: approvals.approvalHandler
)
```

The adapter converts supported provider-neutral schemas into Apple's generation
schemas and enforces the same execution and access policies. Existing native
`FoundationModels.Tool` implementations can instead use
`AppleFoundationModel(nativeTools:)`. Native tools honor `toolChoice: .none`
and request-scoped tool-name selection. Because native tools execute outside
SwiftOrc's tool executor, they cannot enforce `toolAccessPolicy` or SwiftOrc
approval handlers; a request that enables native tools while supplying an
access policy fails explicitly. Use `workflowToolRegistrations:` whenever
request-scoped authorization or user approval is required.
