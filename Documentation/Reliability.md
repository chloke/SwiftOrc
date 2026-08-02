# Reliability and workflow control

The basic execution model is intentionally small:

```text
typed state -> node -> NodeResult -> next node or finish
```

## Validation, retry, and recovery

Attach behavior only where it is needed:

```swift
let reliable = AnyWorkflowNode(generate)
    .retrying(
        WorkflowNodeRetryPolicy(
            maximumAttempts: 3,
            delay: .milliseconds(250)
        )
    )
    .validated(by: validator)
    .recover(to: "fallback")
    .timeout(after: .seconds(20))
```

Validation retries use the workflow's `maximumRetriesPerNode` limit. Choose a
different validation failure behavior only when invalid output should route or
fail immediately.

`retrying` converts eligible thrown errors into the runtime's ordinary retry
transition, so attempts and reasons remain visible in workflow events and
checkpoints. Its attempt count includes the first execution. The workflow's
`maximumRetriesPerNode` remains the hard upper bound.

Timeout cancellation is cooperative. When a timeout wins, the wrapped task is
cancelled, but Swift structured concurrency must still wait for code that
ignores cancellation. Network adapters should therefore also use transport
deadlines; a node timeout is not a way to detach stuck work.

Unhandled errors become `WorkflowExecutionError` values with the failing node,
step count, redacted failure, and event history. A successful run reports either
`.completed` or `.recovered`.

## Branching and parallel work

Use `BranchNode` for named deterministic routes and `ParallelNode` for bounded,
independent work. Parallel results are merged in declaration order, so workflow
state does not depend on task completion timing.

`ParallelNode` runs at most four branches concurrently by default. Set
`maximumConcurrentBranches` when an app needs a different bounded limit. A
non-positive limit is rejected when the graph is built.

Side effects should remain in explicit nodes and should be idempotent whenever
the workflow may resume from a checkpoint.

## Events

Pass `onEvent` only when the application needs tracing:

```swift
let run = try await workflow.run(initialState, onEvent: { event in
    await trace.record(event)
})
```

Framework diagnostics omit prompts, tool arguments, tool outputs, credentials,
HTTP bodies, and artifact bytes. Approval requests are a deliberate exception
because the UI needs arguments to make an informed decision.

All ordinary error descriptions are serialized as `"The operation failed."`
plus their type name, including framework errors that may contain model-provided
associated values. Throw an explicit `WorkflowFailure` when an application has
reviewed a message and intentionally considers it safe for traces and durable
checkpoints. Remote-provider error bodies are omitted by default;
`includesProviderErrorMessages` is an explicit diagnostic opt-in.

## Graph inspection

`workflow.declaredGraph` returns a Codable description containing the workflow
identifier, initial node, safety configuration, and every statically declared
edge. It is suitable for developer diagnostics and graph visualizers. Dynamic
destinations cannot appear until execution and are intentionally not guessed.

## Checkpoints

Checkpointing is opt-in:

```swift
let store = JSONFileWorkflowCheckpointStore<AppState>(fileURL: checkpointURL)

let run = try await workflow.run(initialState, onCheckpoint: { checkpoint in
    try await store.save(checkpoint)
})
```

Resume by loading the snapshot and supplying the same external services, such
as a directory artifact store:

```swift
if let checkpoint = try await store.load() {
    let run = try await workflow.resume(
        from: checkpoint,
        artifactStore: artifactStore
    )
}
```

Checkpoints occur at safe boundaries between nodes. If the process terminates
while a node is executing, that node can execute again after resume.

The JSON store rejects files larger than 8 MiB by default and refuses symbolic
links. Pass a different positive `maximumBytes` only when the application's
state genuinely requires it. Built-in checkpoint and directory artifact stores
write plaintext files. Keep them in an application-owned protected container,
exclude sensitive transient data from backups, or supply a custom encrypted
store when the threat model requires encryption at rest.
