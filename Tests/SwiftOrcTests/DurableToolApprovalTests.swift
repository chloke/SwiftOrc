import Foundation
import Testing

@testable import SwiftOrc

/// Returns scripted responses in order and records every request.
private actor ApprovalScriptedModel: WorkflowLanguageModel {
    private var responses: [LanguageModelResponse]
    private(set) var requests: [LanguageModelRequest] = []

    init(_ responses: [LanguageModelResponse]) {
        self.responses = responses
    }

    func generate(_ request: LanguageModelRequest) async throws -> LanguageModelResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.unknown) }
        return responses.removeFirst()
    }
}

/// Records the arguments of every tool invocation.
private actor ToolInvocationLog {
    private(set) var arguments: [String] = []
    func record(_ value: String) { arguments.append(value) }
}

private struct RecordingTool: LanguageModelTool {
    let definition: LanguageModelToolDefinition
    let log: ToolInvocationLog

    init(name: String, log: ToolInvocationLog) {
        definition = LanguageModelToolDefinition(
            name: name,
            description: "Test tool",
            parameters: .object(["type": .string("object")])
        )
        self.log = log
    }

    func call(arguments: String) async throws -> String {
        await log.record(arguments)
        return #"{"ok":true}"#
    }
}

private struct AgentState: Sendable, Codable, Equatable {
    var chat = LanguageModelConversation()
    var prompt = "Send the report to Sam"
    var replies: [String] = []
}

private func toolCall(_ id: String, _ name: String = "send", _ arguments: String = #"{"to":"sam"}"#)
    -> LanguageModelResponse
{
    LanguageModelResponse(
        content: "",
        toolCalls: [LanguageModelToolCall(id: id, name: name, arguments: arguments)]
    )
}

private let returnDenials = LanguageModelToolAccessPolicy(
    rules: [LanguageModelToolAccessRule(authorization: .automatic)],
    denialBehavior: .returnToModel
)

private func durableModel(
    _ model: ApprovalScriptedModel,
    log: ToolInvocationLog,
    approval: LanguageModelToolApprovalRequirement = .always,
    metadata: LanguageModelToolMetadata = .unclassified,
    mode: LanguageModelToolApprovalMode = .durable,
    maximumToolCalls: Int = 32,
    approvalHandler: LanguageModelToolApprovalHandler? = nil,
    extraTools: [LanguageModelToolRegistration] = []
) throws -> ToolCallingLanguageModel {
    try ToolCallingLanguageModel(
        model: model,
        registrations: [
            LanguageModelToolRegistration(
                tool: RecordingTool(name: "send", log: log),
                policy: LanguageModelToolExecutionPolicy(approval: approval),
                metadata: metadata
            )
        ] + extraTools,
        configuration: ToolCallingLanguageModelConfiguration(
            maximumToolCalls: maximumToolCalls,
            approvalMode: mode
        ),
        approvalHandler: approvalHandler
    )
}

private func agentWorkflow(
    _ model: ToolCallingLanguageModel,
    accessPolicy: LanguageModelToolAccessPolicy? = nil
) throws -> Workflow<AgentState> {
    try Workflow(
        definitionID: "agent",
        initialNode: "chat",
        nodes: [
            AnyWorkflowNode(
                LanguageModelNode(
                    id: "chat",
                    model: model,
                    conversation: \AgentState.chat,
                    request: { state, _ in
                        LanguageModelRequest(
                            prompt: state.prompt,
                            toolAccessPolicy: accessPolicy
                        )
                    },
                    reduce: { response, state, _ in
                        var state = state
                        state.replies.append(response.content)
                        return .finish(state)
                    }
                )
            )
        ]
    )
}

private func suspended(
    _ result: WorkflowExecutionResult<AgentState>
) throws -> WorkflowContinuation<AgentState> {
    guard case let .suspended(continuation) = result else {
        Issue.record("Expected the workflow to suspend")
        throw CancellationError()
    }
    return continuation
}

private func completed(
    _ result: WorkflowExecutionResult<AgentState>
) throws -> WorkflowRun<AgentState> {
    guard case let .completed(run) = result else {
        Issue.record("Expected the workflow to complete")
        throw CancellationError()
    }
    return run
}

@Test
func durableApprovalSuspendsBeforeAnyToolRunsAndSurvivesEncoding() async throws {
    let log = ToolInvocationLog()
    let script = ApprovalScriptedModel([
        toolCall("call-1"), LanguageModelResponse(content: "Sent."),
    ])
    let workflow = try agentWorkflow(try durableModel(script, log: log))

    let continuation = try suspended(
        try await workflow.run(AgentState(), budget: .unlimited)
    )
    #expect(await log.arguments.isEmpty)
    let pending = try #require(continuation.checkpoint.state.chat.pendingTurn)
    #expect(pending.isAwaitingApproval)
    #expect(pending.approvalRequests.map(\.call.id) == ["call-1"])
    let request = try #require(continuation.checkpoint.pendingInput)
    #expect(request.kind == .toolApproval)
    #expect(request.id == pending.approvalRequestID)
    #expect(request.metadata["tools"] == "send")
    #expect(continuation.checkpoint.nextNode == "chat")

    // The app is closed: the checkpoint goes through JSON and back.
    let restored = try JSONDecoder().decode(
        WorkflowCheckpoint<AgentState>.self,
        from: JSONEncoder().encode(continuation.checkpoint)
    )
    let run = try completed(
        try await workflow.resume(
            from: restored,
            answering: request.id,
            budget: .unlimited
        ) { state in
            state.chat.pendingTurn?.approve("call-1")
        }
    )

    #expect(await log.arguments == [#"{"to":"sam"}"#])
    #expect(run.state.replies == ["Sent."])
    #expect(run.state.chat.pendingTurn == nil)
    let turn = try #require(run.state.chat.turns.first)
    #expect(turn.prompt == "Send the report to Sam")
    #expect(turn.reply == "Sent.")
    #expect(turn.transcript.count == 3)
    let requests = await script.requests
    #expect(requests.count == 2)
    #expect(requests.last?.messages.count == 2)
}

@Test
func deniedAndUndecidedCallsNeverRun() async throws {
    for answer: JSONValue? in [.bool(false), nil] {
        let log = ToolInvocationLog()
        let script = ApprovalScriptedModel([
            toolCall("call-1"), LanguageModelResponse(content: "I could not send it."),
        ])
        let workflow = try agentWorkflow(
            try durableModel(script, log: log),
            accessPolicy: returnDenials
        )
        let continuation = try suspended(
            try await workflow.run(AgentState(), budget: .unlimited)
        )
        let request = try #require(continuation.checkpoint.pendingInput)

        let run = try completed(
            try await workflow.resume(
                from: continuation.checkpoint,
                answering: request.id,
                with: answer,
                budget: .unlimited
            )
        )
        #expect(await log.arguments.isEmpty)
        #expect(run.state.replies == ["I could not send it."])
        let requests = await script.requests
        #expect(
            requests.last?.messages.last
                == .tool(
                    callID: "call-1",
                    content: LanguageModelToolDenialBehavior.redactedModelResponse
                )
        )
    }
}

@Test
func deniedCallsFailTheWorkflowByDefault() async throws {
    let log = ToolInvocationLog()
    let script = ApprovalScriptedModel([toolCall("call-1")])
    let workflow = try agentWorkflow(try durableModel(script, log: log))
    let continuation = try suspended(
        try await workflow.run(AgentState(), budget: .unlimited)
    )
    let request = try #require(continuation.checkpoint.pendingInput)

    await #expect(throws: WorkflowExecutionError.self) {
        _ = try await workflow.resume(
            from: continuation.checkpoint,
            answering: request.id,
            with: .object(["call-1": .string("denied")]),
            budget: .unlimited
        )
    }
    #expect(await log.arguments.isEmpty)
}

@Test
func approvedRoundIsCheckpointedSoACrashDoesNotRepeatIt() async throws {
    let log = ToolInvocationLog()
    let script = ApprovalScriptedModel([toolCall("call-1")])
    let model = try durableModel(script, log: log)
    let workflow = try agentWorkflow(model)
    let continuation = try suspended(
        try await workflow.run(AgentState(), budget: .unlimited)
    )
    let request = try #require(continuation.checkpoint.pendingInput)

    // The model call after the tool round fails, like a crash would.
    let checkpoints = WorkflowCheckpointRecorder<WorkflowCheckpoint<AgentState>>()
    _ = try? await workflow.resume(
        from: continuation.checkpoint,
        answering: request.id,
        with: .bool(true),
        budget: .unlimited,
        onCheckpoint: { await checkpoints.record($0) }
    )
    #expect(await log.arguments.count == 1)
    let afterRound = try #require(
        await checkpoints.values.last {
            $0.state.chat.pendingTurn?.pendingCalls.isEmpty == true
        }
    )
    #expect(afterRound.pendingInput == nil)
    #expect(afterRound.nextNode == "chat")

    // Relaunch from the checkpoint saved after the round.
    let relaunched = ApprovalScriptedModel([LanguageModelResponse(content: "Sent.")])
    let run = try completed(
        try await agentWorkflow(try durableModel(relaunched, log: log))
            .resume(from: afterRound, budget: .unlimited)
    )
    #expect(await log.arguments.count == 1)
    #expect(run.state.replies == ["Sent."])
    let resumedRequest = try #require(await relaunched.requests.first)
    #expect(resumedRequest.messages.last == .tool(callID: "call-1", content: #"{"ok":true}"#))
    #expect(run.state.chat.turns.first?.transcript.count == 3)
}

@Test
func readOnlyRoundsAndDisabledCheckpointsDoNotAddSteps() async throws {
    let readOnly = LanguageModelToolMetadata(effects: [.readOnly])
    for (metadata, mode) in [
        (readOnly, LanguageModelToolApprovalMode.durable),
        (.unclassified, .durable(checkpointsAfterToolRounds: false)),
    ] {
        let log = ToolInvocationLog()
        let script = ApprovalScriptedModel([
            toolCall("call-1"), LanguageModelResponse(content: "Done."),
        ])
        let workflow = try agentWorkflow(
            try durableModel(script, log: log, approval: .never, metadata: metadata, mode: mode)
        )
        let run = try completed(try await workflow.run(AgentState(), budget: .unlimited))
        #expect(await log.arguments.count == 1)
        #expect(run.steps == 1)
    }
}

/// Runs one segment of a durable turn the way a conversation node does.
private func segment(
    _ model: ToolCallingLanguageModel,
    prompt: String = "Send the report to Sam",
    resuming pending: LanguageModelPendingToolTurn?
) async throws -> LanguageModelPendingToolTurn? {
    do {
        _ = try await LanguageModelToolTurnScope.$current.withValue(
            LanguageModelToolTurnScope(resuming: pending)
        ) {
            try await model.generate(LanguageModelRequest(prompt: prompt))
        }
        return nil
    } catch let suspended as LanguageModelToolTurnSuspended {
        return suspended.pendingTurn
    }
}

@Test
func limitsCarryAcrossSuspensions() async throws {
    let log = ToolInvocationLog()
    let script = ApprovalScriptedModel([toolCall("call-1"), toolCall("call-2")])
    let model = try durableModel(script, log: log, maximumToolCalls: 1)

    var pending = try #require(try await segment(model, resuming: nil))
    pending.approveAll()
    pending.approvalRequestID = nil
    // The approved round runs, then the turn pauses for a checkpoint.
    let afterRound = try #require(try await segment(model, resuming: pending))
    #expect(afterRound.pendingCalls.isEmpty)
    #expect(afterRound.executionCount == 1)

    await #expect(throws: ToolCallingLanguageModelError.maximumToolCallsExceeded(1)) {
        _ = try await segment(model, resuming: afterRound)
    }
    #expect(await log.arguments.count == 1)
}

@Test
func pendingTurnsFromAnotherRequestOrModelAreRejected() async throws {
    let log = ToolInvocationLog()
    let model = try durableModel(ApprovalScriptedModel([toolCall("call-1")]), log: log)
    var pending = try #require(try await segment(model, resuming: nil))
    pending.approveAll()
    pending.approvalRequestID = nil

    await #expect(throws: ToolCallingLanguageModelError.pendingTurnMismatch) {
        _ = try await segment(model, prompt: "Something else", resuming: pending)
    }
    let otherTools = try ToolCallingLanguageModel(
        model: ApprovalScriptedModel([]),
        tools: [RecordingTool(name: "other", log: log)],
        configuration: ToolCallingLanguageModelConfiguration(approvalMode: .durable)
    )
    await #expect(throws: ToolCallingLanguageModelError.pendingTurnMismatch) {
        _ = try await segment(otherTools, resuming: pending)
    }
    #expect(await log.arguments.isEmpty)
}

@Test
func reportCountsToolsFromEarlierSegments() async throws {
    let log = ToolInvocationLog()
    let script = ApprovalScriptedModel([
        toolCall("call-1"), LanguageModelResponse(content: "Sent."),
    ])
    let report = WorkflowCheckpointRecorder<LanguageModelToolExecutionReport>()
    let workflow = try Workflow<AgentState>(
        initialNode: "chat",
        nodes: [
            AnyWorkflowNode(
                LanguageModelNode(
                    id: "chat",
                    model: try durableModel(script, log: log),
                    conversation: \AgentState.chat,
                    request: { state, _ in LanguageModelRequest(prompt: state.prompt) },
                    reduce: { response, state, _ in
                        if let toolReport = response.toolExecutionReport {
                            await report.record(toolReport)
                        }
                        return .finish(state)
                    }
                )
            )
        ]
    )
    let continuation = try suspended(try await workflow.run(AgentState(), budget: .unlimited))
    _ = try await workflow.resume(
        from: continuation.checkpoint,
        answering: try #require(continuation.checkpoint.pendingInput).id,
        with: .bool(true),
        budget: .unlimited
    )
    let final = try #require(await report.values.last)
    #expect(final.modelCalls == 2)
    #expect(final.toolRounds == 1)
    #expect(final.executions.map(\.tool) == ["send"])
}

@Test
func changedPromptOrAbandonedTurnIsHandledExplicitly() async throws {
    let log = ToolInvocationLog()
    let script = ApprovalScriptedModel([toolCall("call-1")])
    let workflow = try agentWorkflow(try durableModel(script, log: log))
    let continuation = try suspended(
        try await workflow.run(AgentState(), budget: .unlimited)
    )
    let request = try #require(continuation.checkpoint.pendingInput)

    await #expect(throws: WorkflowExecutionError.self) {
        _ = try await workflow.resume(
            from: continuation.checkpoint,
            answering: request.id,
            with: .bool(true),
            budget: .unlimited
        ) { state in
            state.prompt = "Something else"
        }
    }
    #expect(await log.arguments.isEmpty)

    // Abandoning the turn starts the prompt over.
    let fresh = ApprovalScriptedModel([LanguageModelResponse(content: "Okay.")])
    let run = try completed(
        try await agentWorkflow(try durableModel(fresh, log: log)).resume(
            from: continuation.checkpoint,
            answering: request.id,
            budget: .unlimited
        ) { state in
            state.prompt = "Something else"
            state.chat.pendingTurn = nil
        }
    )
    #expect(run.state.replies == ["Okay."])
    #expect(await log.arguments.isEmpty)
}

@Test
func durableModelFallsBackToItsHandlerOutsideConversationNodes() async throws {
    let log = ToolInvocationLog()
    let asked = ToolInvocationLog()
    let script = ApprovalScriptedModel([
        toolCall("call-1"), LanguageModelResponse(content: "Sent."),
    ])
    let model = try durableModel(
        script,
        log: log,
        approvalHandler: { request in
            await asked.record(request.call.id)
            return .approved
        }
    )

    let response = try await model.generate(LanguageModelRequest(prompt: "Send it"))
    #expect(response.content == "Sent.")
    #expect(await asked.arguments == ["call-1"])
    #expect(await log.arguments.count == 1)

    // A conversational wrapper also uses the handler instead of suspending.
    let wrapperScript = ApprovalScriptedModel([
        toolCall("call-2"), LanguageModelResponse(content: "Sent again."),
    ])
    let wrapper = ConversationalLanguageModel(
        model: try durableModel(
            wrapperScript,
            log: log,
            approvalHandler: { _ in .approved }
        )
    )
    let wrapped = try await wrapper.generate(LanguageModelRequest(prompt: "Again"))
    #expect(wrapped.content == "Sent again.")
    #expect(await wrapper.conversation.pendingTurn == nil)
}

@Test
func toolsWithoutApprovalInTheSameRoundWaitForTheDecision() async throws {
    let log = ToolInvocationLog()
    let script = ApprovalScriptedModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(id: "a", name: "lookup", arguments: "{}"),
                LanguageModelToolCall(id: "b", name: "send", arguments: #"{"to":"sam"}"#),
            ]
        ),
        LanguageModelResponse(content: "Done."),
    ])
    let model = try durableModel(
        script,
        log: log,
        extraTools: [
            LanguageModelToolRegistration(tool: RecordingTool(name: "lookup", log: log))
        ]
    )
    let workflow = try agentWorkflow(model)
    let continuation = try suspended(try await workflow.run(AgentState(), budget: .unlimited))
    #expect(await log.arguments.isEmpty)
    let pending = try #require(continuation.checkpoint.state.chat.pendingTurn)
    #expect(pending.callIDsRequiringApproval == ["b"])
    #expect(pending.pendingCalls.map(\.id) == ["a", "b"])

    let run = try completed(
        try await workflow.resume(
            from: continuation.checkpoint,
            answering: try #require(continuation.checkpoint.pendingInput).id,
            with: .object(["b": .bool(true)]),
            budget: .unlimited
        )
    )
    #expect(await log.arguments == ["{}", #"{"to":"sam"}"#])
    #expect(run.state.replies == ["Done."])
}

@Test
func routersRethrowPausedTurnsWithoutFallingBack() async throws {
    let log = ToolInvocationLog()
    let first = ApprovalScriptedModel([toolCall("call-1")])
    let second = ApprovalScriptedModel([LanguageModelResponse(content: "wrong")])
    let router = try LanguageModelRouter(
        routes: [
            LanguageModelRoute(provider: "first", model: try durableModel(first, log: log)),
            LanguageModelRoute(provider: "second", model: second),
        ]
    )
    let workflow = try Workflow<AgentState>(
        initialNode: "chat",
        nodes: [
            AnyWorkflowNode(
                LanguageModelNode(
                    id: "chat",
                    model: router,
                    conversation: \AgentState.chat,
                    request: { state, _ in LanguageModelRequest(prompt: state.prompt) },
                    reduce: { _, state, _ in .finish(state) }
                )
            )
        ]
    )
    _ = try suspended(try await workflow.run(AgentState(), budget: .unlimited))
    #expect(await second.requests.isEmpty)
}

@Test
func pendingTurnAnswersAndApprovalHelpers() throws {
    var pending = LanguageModelPendingToolTurn(
        prompt: "p",
        exchange: [],
        pendingCalls: [
            LanguageModelToolCall(id: "a", name: "x", arguments: "{}"),
            LanguageModelToolCall(id: "b", name: "y", arguments: "{}"),
        ],
        callIDsRequiringApproval: ["a", "b"],
        approvalRequestID: UUID(),
        provider: nil,
        modelCalls: 1,
        toolRounds: 1,
        executionCount: 0,
        executions: [],
        deniedToolNames: []
    )
    pending.approve("unknown")
    #expect(pending.decisions.isEmpty)
    pending.applyAnswer(.object(["a": .string("approved"), "b": .bool(false)]))
    #expect(pending.decision(for: "a") == .approved)
    #expect(pending.decision(for: "b") == .denied)
    pending.applyAnswer(.string("ignored"))
    #expect(pending.decision(for: "a") == .approved)
    pending.applyAnswer(.bool(true))
    #expect(pending.decision(for: "b") == .approved)
    pending.denyAll()
    #expect(pending.decisions.values.allSatisfy { $0 == .denied })

    var conversation = LanguageModelConversation()
    conversation.pendingTurn = pending
    let decoded = try JSONDecoder().decode(
        LanguageModelConversation.self,
        from: JSONEncoder().encode(conversation)
    )
    #expect(decoded == conversation)
    conversation.removeAll()
    #expect(conversation.pendingTurn == nil)

    // Conversations saved before pending turns existed still decode.
    let legacy = try JSONDecoder().decode(
        LanguageModelConversation.self,
        from: Data(#"{"turns":[]}"#.utf8)
    )
    #expect(legacy.pendingTurn == nil)
}

/// Collects values passed to an async callback.
private actor WorkflowCheckpointRecorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func record(_ value: Value) { values.append(value) }
}
