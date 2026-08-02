# Testing workflows without providers

`SwiftOrcTesting` is an optional test-support product. It contains no
network transport, does not depend on Apple Intelligence, and is not required
by the runtime products.

Add it only to a test target:

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "SwiftOrc",
        "SwiftOrcTesting",
    ]
)
```

## Script model behavior

`ScriptedLanguageModel` consumes responses and failures in order while recording
the requests it receives:

```swift
import SwiftOrc
import SwiftOrcTesting
import Testing

let model = ScriptedLanguageModel(
    .respond(content: #"{"answer":"first"}"#),
    .fail(message: "temporary provider failure"),
    .respond(content: #"{"answer":"fallback"}"#)
)

let response = try await model.generate(
    LanguageModelRequest(prompt: "Create an answer")
)

let snapshot = await model.snapshot()
#expect(snapshot.requests.count == 1)
#expect(!snapshot.allStepsConsumed)
```

A step can delay before responding or failing. This permits real workflow
timeout and cancellation policies to be tested:

```swift
let slow = ScriptedLanguageModel(
    .respond(content: "late", after: .seconds(30))
)
```

The model records prompts only in memory and only exposes them through an
explicit request or snapshot. Exhaustion errors report the request number, not
the prompt or response content.

## Probe execution

`WorkflowProbe` supplies event and checkpoint handlers backed by actor-isolated
storage:

```swift
let probe = WorkflowProbe<AppState>()

let run = try await workflow.run(
    AppState(),
    onEvent: probe.eventHandler,
    onCheckpoint: probe.checkpointHandler
)

let observations = await probe.snapshot()
#expect(observations.startCount(for: "generate") == 2)
#expect(observations.selectedRoutes(for: "quality") == ["accepted"])
```

The snapshot also exposes raw events and checkpoints for application-specific
assertions. Convenience queries never inspect workflow state, prompts, tool
arguments, or model output.

## What belongs in a test

Use scripted tests to verify orchestration rather than model intelligence:

- branch and fallback order;
- retry and timeout behavior;
- capability and routing policies;
- malformed structured responses;
- tool approval and denial paths;
- checkpoint creation and resume behavior;
- guarantees that a remote route was never called;
- streamed deltas, completion metadata, and pre-delta fallback boundaries.

Evaluate the quality of a real model separately on supported hardware. A
scripted provider makes runtime behavior repeatable; it cannot predict how a
future Apple system model will answer a prompt.
