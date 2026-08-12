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

## Budgeted execution and deliberate suspension

Use an execution budget when one logical workflow must be spread across short
runtime opportunities. A budget is applied to one invocation and resets on
every resume. It does not replace the workflow configuration's cumulative
`maximumSteps` safety limit.

```swift
let clock = ContinuousClock()
let budget = WorkflowExecutionBudget(
    maximumNodeExecutions: 2,
    deadline: clock.now.advanced(by: .seconds(20))
)

let result = try await workflow.run(initialState, budget: budget)

switch result {
case let .completed(run):
    use(run.state)

case let .suspended(continuation):
    try await checkpointStore.save(continuation.checkpoint)
}
```

Continue later with a fresh budget:

```swift
let result = try await workflow.resume(
    from: savedCheckpoint,
    budget: WorkflowExecutionBudget(maximumNodeExecutions: 1)
)
```

`maximumNodeExecutions` counts every node attempt, including retries and branch
nodes. A non-positive value is rejected. The monotonic deadline is checked only
between nodes. SwiftOrc never interrupts a node that has already started; if a
deadline passes during a model call, tool call, or other node, that node finishes
before the workflow suspends at the next safe boundary. Cancellation remains the
mechanism for responding to an operating-system expiration callback.

A suspension is successful control flow, not a failure. It returns a
`WorkflowContinuation` containing a durable checkpoint, the reason for yielding,
and the number of node executions used by that invocation. If an `onCheckpoint`
handler is supplied, it receives the suspension checkpoint before the method
returns.

The ordinary `run` and `resume` overloads remain unbudgeted and continue to
return `WorkflowRun` directly. `WorkflowExecutionBudget.unlimited` provides the
same node-budget behavior through the budgeted result API, while the workflow's
cumulative configuration limits still apply.

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

Budgeted suspension also produces a checkpoint without requiring an
`onCheckpoint` handler. Persist the checkpoint carried by the returned
`WorkflowContinuation` before the current runtime opportunity ends.

The JSON store rejects files larger than 8 MiB by default and refuses symbolic
links. Pass a different positive `maximumBytes` only when the application's
state genuinely requires it. Built-in checkpoint and directory artifact stores
write plaintext files. Keep them in an application-owned protected container,
exclude sensitive transient data from backups, or supply a custom encrypted
store when the threat model requires encryption at rest.
