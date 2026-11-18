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

A tool timeout is enforced even when the tool ignores cancellation: the call
fails with `LanguageModelToolPolicyError.timedOut` at the deadline and the tool
receives cooperative cancellation. Work that keeps running regardless continues
in the background and its result is discarded. It holds its concurrency permit
until it actually stops, so `maximumConcurrentToolCalls` is never exceeded.
Make tools that can time out idempotent, because the abandoned work may still
complete its effect after the timeout is reported.

Observe `approvals.updates()` in application state and resolve requests with
`approve(_:)` or `deny(_:)`. Pending approvals contain raw untrusted arguments;
do not copy them into telemetry or ordinary traces.
The framework waits until the application resolves or cancels an approval, so
approval UI should always provide a denial path and clean up pending requests
when its owning task or screen is dismissed.

### Approvals that survive closing the app

An approval handler waits in memory, so a pending approval is lost if the app
is closed. With durable approvals the workflow suspends instead, and the
answer can arrive after a relaunch:

```swift
let model = try ToolCallingLanguageModel(
    model: router,
    registrations: [protected],
    configuration: ToolCallingLanguageModelConfiguration(approvalMode: .durable)
)

let chat = LanguageModelNode(
    id: "chat",
    model: model,
    conversation: \.chat,
    request: { state, _ in LanguageModelRequest(prompt: state.message) },
    reduce: { response, state, _ in .finish(state) }
)
```

When the model calls a tool that needs approval, the node saves the turn in
`state.chat.pendingTurn` and suspends with a `WorkflowInputKind.toolApproval`
request (see [Waiting for user input](Reliability.md#waiting-for-user-input)).
Show `pendingTurn.approvalRequests` to the user, then resume:

```swift
let result = try await workflow.resume(
    from: checkpoint,
    answering: request.id
) { state in
    state.chat.pendingTurn?.approve(callID)   // or deny, approveAll, denyAll
}
```

A generic answer works too: `with: .bool(true)` approves every call, `false`
denies every call, and `.object([callID: .bool(true)])` decides one at a time.

- No call in the round runs until the application answers, including calls
  that do not need approval. Calls left without a decision are denied, and
  denials follow the access policy's `denialBehavior`.
- The calls that run are exactly the stored ones the user saw: the model cannot
  change their arguments in between.
- After each round that ran a tool that may have side effects, the node saves
  a checkpoint before calling the model again, so a crash later in the turn
  does not run that round twice. Each such round counts as one workflow step
  toward `maximumSteps`. Turn it off with
  `.durable(checkpointsAfterToolRounds: false)`; read-only tools never add a
  checkpoint.
- Tool round and call limits count across the suspension.
- Resuming with a different prompt fails with
  `ToolCallingLanguageModelError.pendingTurnMismatch`. Set
  `state.chat.pendingTurn = nil` to abandon the turn instead.

Durable approvals need a `LanguageModelNode` or `StructuredLanguageModelNode`
with `conversation:`. Elsewhere, for example in `ConversationalLanguageModel`
or a node without a conversation, the model asks its `approvalHandler` instead;
without a handler, calls that need approval are denied. Put a router inside
the tool-calling model rather than routing between tool-calling models, so a
resumed turn continues with the same tools. Apple's bridged tool loop always
uses its approval handler.

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
schemas and enforces the same execution and access policies. Apple's tool loop
has no call limit of its own, so the adapter's `maximumToolCalls` (32 by
default, matching `ToolCallingLanguageModelConfiguration`) bounds the tool
calls for one request; further calls fail with
`ToolCallingLanguageModelError.maximumToolCallsExceeded`. The limit applies per
request, not per conversation or app session. Agents that legitimately need
more calls in one request can raise it, or pass `.max` to remove the bound;
in that case cancel the request task or set a node timeout to stop runaway
loops. Existing native
`FoundationModels.Tool` implementations can instead use
`AppleFoundationModel(nativeTools:)`. Native tools honor `toolChoice: .disabled`
and request-scoped tool-name selection. Because native tools execute outside
SwiftOrc's tool executor, they cannot enforce `toolAccessPolicy` or SwiftOrc
approval handlers; a request that enables native tools while supplying an
access policy fails explicitly. Use `workflowToolRegistrations:` whenever
request-scoped authorization or user approval is required.
