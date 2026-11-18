import Foundation
import Testing

@testable import SwiftOrc

private struct OrderState: Sendable, Codable, Equatable {
    var confirmed = false
    var answer: String?
    var log: [String] = []
}

private actor InputEventRecorder {
    private(set) var events: [WorkflowEvent] = []
    func record(_ event: WorkflowEvent) { events.append(event) }
}

private let confirmRequest = WorkflowInputRequest(
    kind: .confirmation,
    prompt: "Place the order for 3 items?"
)

/// "ask" requests confirmation and resumes at "place", which requires it.
private func orderWorkflow(
    request: WorkflowInputRequest = confirmRequest
) throws -> Workflow<OrderState> {
    try Workflow(
        definitionID: "order",
        initialNode: "ask",
        nodes: [
            AnyWorkflowNode(id: "ask") { state, _ in
                var state = state
                state.log.append("ask")
                return .awaitInput(state, request: request, resumeAt: "place")
            },
            AnyWorkflowNode(id: "place") { state, context in
                var state = state
                state.log.append(state.confirmed ? "placed" : "skipped")
                if case let .string(answer) = context.inputResponse?.value {
                    state.answer = answer
                }
                return .next(state, "done")
            },
            AnyWorkflowNode(id: "done") { state, context in
                var state = state
                state.log.append(context.inputResponse == nil ? "done" : "leaked")
                return .finish(state)
            },
        ]
    )
}

private func suspendedCheckpoint(
    _ workflow: Workflow<OrderState>
) async throws -> WorkflowCheckpoint<OrderState> {
    guard
        case let .suspended(continuation) = try await workflow.run(
            OrderState(),
            budget: .unlimited
        )
    else {
        Issue.record("Expected the workflow to suspend")
        throw CancellationError()
    }
    return continuation.checkpoint
}

@Test
func awaitInputSuspendsAndResumesAtTheNamedNode() async throws {
    let workflow = try orderWorkflow()

    let result = try await workflow.run(OrderState(), budget: .unlimited)
    guard case let .suspended(continuation) = result else {
        Issue.record("Expected suspension")
        return
    }
    #expect(continuation.reason == .awaitingInput(confirmRequest))
    #expect(continuation.checkpoint.pendingInput == confirmRequest)
    #expect(continuation.checkpoint.nextNode == "place")

    let resumed = try await workflow.resume(
        from: continuation.checkpoint,
        answering: confirmRequest.id,
        with: .string("yes")
    ) { state in
        state.confirmed = true
    }

    guard case let .completed(run) = resumed else {
        Issue.record("Expected completion")
        return
    }
    // The asking node is not run again, and the answer reaches only "place".
    #expect(run.state.log == ["ask", "placed", "done"])
    #expect(run.state.answer == "yes")
}

@Test
func awaitInputWithoutResumeTargetRerunsTheSameNode() async throws {
    let request = WorkflowInputRequest(kind: .choice, choices: ["tea", "coffee"])
    let workflow = try Workflow<OrderState>(
        initialNode: "pick",
        nodes: [
            AnyWorkflowNode(id: "pick") { state, context in
                guard case let .string(choice) = context.inputResponse?.value else {
                    return .awaitInput(state, request: request)
                }
                var state = state
                state.answer = choice
                return .finish(state)
            }
        ]
    )

    let checkpoint = try await {
        guard
            case let .suspended(continuation) = try await workflow.run(
                OrderState(),
                budget: .unlimited
            )
        else { throw CancellationError() }
        return continuation.checkpoint
    }()
    #expect(checkpoint.nextNode == "pick")

    let result = try await workflow.resume(
        from: checkpoint,
        answering: request.id,
        with: .string("tea")
    )
    guard case let .completed(run) = result else {
        Issue.record("Expected completion")
        return
    }
    #expect(run.state.answer == "tea")
}

@Test
func plainRunThrowsInputRequiredInsteadOfCrashing() async throws {
    let workflow = try orderWorkflow()

    do {
        _ = try await workflow.run(OrderState())
        Issue.record("Expected WorkflowInputRequired")
    } catch let required as WorkflowInputRequired<OrderState> {
        #expect(required.request == confirmRequest)
        let result = try await workflow.resume(
            from: required.continuation.checkpoint,
            answering: confirmRequest.id
        ) { $0.confirmed = true }
        guard case .completed = result else {
            Issue.record("Expected completion")
            return
        }
    }
}

@Test
func staleExpiredAndMissingAnswersAreRejected() async throws {
    let workflow = try orderWorkflow()
    let checkpoint = try await suspendedCheckpoint(workflow)

    await #expect(
        throws: WorkflowError.inputRequestMismatch(
            expected: confirmRequest.id,
            actual: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    ) {
        _ = try await workflow.resume(
            from: checkpoint,
            answering: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )
    }
    await #expect(throws: WorkflowError.checkpointAwaitingInput(confirmRequest.id)) {
        _ = try await workflow.resume(from: checkpoint)
    }

    let expiring = WorkflowInputRequest(expiresAt: Date().addingTimeInterval(-1))
    let expired = try await suspendedCheckpoint(try orderWorkflow(request: expiring))
    await #expect(throws: WorkflowError.inputRequestExpired(expiring.id)) {
        _ = try await workflow.resume(from: expired, answering: expiring.id)
    }

    let notWaiting = WorkflowCheckpoint(
        definitionID: "order",
        executionID: UUID(),
        state: OrderState(),
        nextNode: "place",
        attempt: 1,
        steps: 1,
        events: [],
        recoveries: []
    )
    await #expect(throws: WorkflowError.checkpointNotAwaitingInput) {
        _ = try await workflow.resume(from: notWaiting, answering: confirmRequest.id)
    }
}

@Test
func inputEventsCarryNoPromptText() async throws {
    let recorder = InputEventRecorder()
    let workflow = try orderWorkflow()

    let checkpoint = try await {
        guard
            case let .suspended(continuation) = try await workflow.run(
                OrderState(),
                budget: .unlimited,
                onEvent: { await recorder.record($0) }
            )
        else { throw CancellationError() }
        return continuation.checkpoint
    }()
    // A trailing closure binds to `update` even when `onEvent` is passed.
    let resumed = try await workflow.resume(
        from: checkpoint,
        answering: confirmRequest.id,
        onEvent: { await recorder.record($0) }
    ) { state in
        state.confirmed = true
    }
    guard case let .completed(run) = resumed else {
        Issue.record("Expected completion")
        return
    }
    #expect(run.state.log.contains("placed"))

    let events = await recorder.events
    #expect(
        events.contains(
            .inputRequested(
                node: "ask",
                requestID: confirmRequest.id,
                kind: .confirmation,
                resumeAt: "place"
            )))
    #expect(events.contains(.inputReceived(node: "place", requestID: confirmRequest.id)))
    #expect(events.contains(.nodeCompleted(node: "ask", transition: .awaitInput("place"))))
    let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
    #expect(!encoded.contains("Place the order"))
}

@Test
func checkpointStoreSavesSuspensionAndOldCheckpointsStillLoad() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONFileWorkflowCheckpointStore<OrderState>(
        fileURL: directory.appendingPathComponent("checkpoint.json")
    )
    let workflow = try orderWorkflow()

    _ = try await workflow.run(
        OrderState(),
        budget: .unlimited,
        onCheckpoint: store.checkpointHandler
    )
    let saved = try #require(try await store.load())
    #expect(saved.formatVersion == 2)
    #expect(saved.pendingInput == confirmRequest)

    // A checkpoint written by 0.5 has version 1 and none of the new fields.
    let legacy = WorkflowCheckpoint(
        formatVersion: 1,
        definitionID: "order",
        executionID: UUID(),
        state: OrderState(log: ["ask"]),
        nextNode: "place",
        attempt: 1,
        steps: 1,
        events: [],
        recoveries: []
    )
    var json = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
    )
    json.removeValue(forKey: "pendingInput")
    json.removeValue(forKey: "inputResponse")
    let decoded = try JSONDecoder().decode(
        WorkflowCheckpoint<OrderState>.self,
        from: JSONSerialization.data(withJSONObject: json)
    )
    let run = try await workflow.resume(from: decoded)
    #expect(run.state.log == ["ask", "skipped", "done"])
}

@Test
func namespacedComponentsRemapResumeTargets() async throws {
    let component = try WorkflowComponent<OrderState>(
        entryNode: "ask",
        nodes: [
            AnyWorkflowNode(id: "ask") { state, _ in
                .awaitInput(state, request: confirmRequest, resumeAt: "place")
            },
            AnyWorkflowNode(id: "place") { state, _ in .finish(state) },
        ]
    ).namespaced("checkout")
    let workflow = try Workflow<OrderState>(
        initialNode: component.entryNode,
        nodes: component.nodes
    )

    guard
        case let .suspended(continuation) = try await workflow.run(
            OrderState(),
            budget: .unlimited
        )
    else {
        Issue.record("Expected suspension")
        return
    }
    #expect(continuation.checkpoint.nextNode == "checkout.place")
}

@Test
func validationDoesNotRunOnInputRequests() async throws {
    let workflow = try Workflow<OrderState>(
        initialNode: "ask",
        nodes: [
            AnyWorkflowNode(id: "ask") { state, _ in
                .awaitInput(state, request: confirmRequest)
            }
            .validated(
                by: WorkflowValidator { _, _ in .invalid(reason: "not confirmed") },
                onFailure: .fail
            )
        ]
    )

    let result = try await workflow.run(OrderState(), budget: .unlimited)
    guard case .suspended = result else {
        Issue.record("Expected suspension instead of a validation failure")
        return
    }
}
