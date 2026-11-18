import Foundation

/// One successfully completed local tool invocation.
public struct LanguageModelToolExecutionRecord: Sendable, Equatable, Codable {
    public let round: Int
    /// A local, monotonically increasing diagnostic number. This is never the
    /// provider's potentially sensitive or untrusted tool-call identifier.
    public let callNumber: Int
    public let tool: String
    public let provider: String?

    public init(
        round: Int,
        callNumber: Int,
        tool: String,
        provider: String?
    ) {
        self.round = round
        self.callNumber = callNumber
        self.tool = tool
        self.provider = provider
    }
}

/// A redacted summary of a completed model/tool loop.
public struct LanguageModelToolExecutionReport: Sendable, Equatable, Codable {
    public let modelCalls: Int
    public let toolRounds: Int
    public let executions: [LanguageModelToolExecutionRecord]
    public let providerManaged: Bool

    public init(
        modelCalls: Int,
        toolRounds: Int,
        executions: [LanguageModelToolExecutionRecord],
        providerManaged: Bool = false
    ) {
        self.modelCalls = modelCalls
        self.toolRounds = toolRounds
        self.executions = executions
        self.providerManaged = providerManaged
    }
}

/// Safety limits for one model/tool interaction.
public struct ToolCallingLanguageModelConfiguration: Sendable, Equatable {
    public var maximumToolRounds: Int
    public var maximumToolCalls: Int
    public var maximumConcurrentToolCalls: Int
    public var maximumToolArgumentBytes: Int
    public var maximumToolOutputBytes: Int
    public var resetToolChoiceAfterFirstRound: Bool
    /// Whether approvals wait in memory or suspend the workflow. Defaults to
    /// ``LanguageModelToolApprovalMode/immediate``.
    public var approvalMode: LanguageModelToolApprovalMode

    public init(
        maximumToolRounds: Int = 8,
        maximumToolCalls: Int = 32,
        maximumConcurrentToolCalls: Int = 1,
        maximumToolArgumentBytes: Int = 1 * 1_024 * 1_024,
        maximumToolOutputBytes: Int = 1 * 1_024 * 1_024,
        resetToolChoiceAfterFirstRound: Bool = true,
        approvalMode: LanguageModelToolApprovalMode = .immediate
    ) {
        self.maximumToolRounds = maximumToolRounds
        self.maximumToolCalls = maximumToolCalls
        self.maximumConcurrentToolCalls = maximumConcurrentToolCalls
        self.maximumToolArgumentBytes = maximumToolArgumentBytes
        self.maximumToolOutputBytes = maximumToolOutputBytes
        self.resetToolChoiceAfterFirstRound = resetToolChoiceAfterFirstRound
        self.approvalMode = approvalMode
    }
}

@nonexhaustive
public enum ToolCallingLanguageModelConfigurationError: Error, Sendable,
    Equatable
{
    case invalidMaximumToolRounds
    case invalidMaximumToolCalls
    case invalidMaximumConcurrentToolCalls
    case invalidMaximumToolArgumentBytes
    case invalidMaximumToolOutputBytes
}

@nonexhaustive
public enum ToolCallingLanguageModelError: Error, Sendable, Equatable {
    case unregisteredDefinition(String)
    case duplicateToolDefinition(String)
    case toolNotAllowed
    case noToolsAllowed
    case unknownTool
    case duplicateCallID
    case toolArgumentsTooLarge(maximum: Int)
    case toolOutputTooLarge(maximum: Int)
    case maximumToolRoundsExceeded(Int)
    case maximumToolCallsExceeded(Int)
    /// A conversation's pending tool turn does not belong to this request:
    /// its prompt changed, or it calls tools this model does not have.
    case pendingTurnMismatch
    case executionFailed(
        callNumber: Int,
        tool: String,
        failure: WorkflowFailure
    )
}

/// Redacted live diagnostics for tool execution.
@nonexhaustive
public enum LanguageModelToolEvent: Sendable, Equatable {
    case roundStarted(round: Int, calls: Int)
    case callStarted(round: Int, callNumber: Int, tool: String)
    case approvalRequested(round: Int, callNumber: Int, tool: String)
    case approvalResolved(
        round: Int,
        callNumber: Int,
        tool: String,
        approved: Bool
    )
    case retryScheduled(
        round: Int,
        callNumber: Int,
        tool: String,
        nextAttempt: Int
    )
    case callCompleted(round: Int, callNumber: Int, tool: String)
    case callFailed(
        round: Int,
        callNumber: Int,
        tool: String
    )
}

public typealias LanguageModelToolEventHandler =
    @Sendable (
        LanguageModelToolEvent
    ) async -> Void

/// Wraps any provider or router in a bounded tool-calling loop.
public struct ToolCallingLanguageModel: WorkflowLanguageModel {
    private let model: any WorkflowLanguageModel
    private let executor: LanguageModelToolExecutor
    private let configuration: ToolCallingLanguageModelConfiguration
    private let onEvent: LanguageModelToolEventHandler?

    public init<Model: WorkflowLanguageModel>(
        model: Model,
        tools: [any LanguageModelTool],
        configuration: ToolCallingLanguageModelConfiguration = .init(),
        approvalHandler: LanguageModelToolApprovalHandler? = nil,
        onEvent: LanguageModelToolEventHandler? = nil
    ) throws {
        try self.init(
            model: model,
            registrations: tools.map {
                LanguageModelToolRegistration(tool: $0)
            },
            configuration: configuration,
            approvalHandler: approvalHandler,
            onEvent: onEvent
        )
    }

    public init<Model: WorkflowLanguageModel>(
        model: Model,
        registrations: [LanguageModelToolRegistration],
        configuration: ToolCallingLanguageModelConfiguration = .init(),
        approvalHandler: LanguageModelToolApprovalHandler? = nil,
        onEvent: LanguageModelToolEventHandler? = nil
    ) throws {
        guard configuration.maximumToolRounds >= 1 else {
            throw ToolCallingLanguageModelConfigurationError
                .invalidMaximumToolRounds
        }
        guard configuration.maximumToolCalls >= 1 else {
            throw ToolCallingLanguageModelConfigurationError
                .invalidMaximumToolCalls
        }
        guard configuration.maximumConcurrentToolCalls >= 1 else {
            throw ToolCallingLanguageModelConfigurationError
                .invalidMaximumConcurrentToolCalls
        }
        guard configuration.maximumToolArgumentBytes >= 1 else {
            throw ToolCallingLanguageModelConfigurationError
                .invalidMaximumToolArgumentBytes
        }
        guard configuration.maximumToolOutputBytes >= 1 else {
            throw ToolCallingLanguageModelConfigurationError
                .invalidMaximumToolOutputBytes
        }

        self.model = model
        executor = try LanguageModelToolExecutor(
            registrations: registrations,
            maximumConcurrentCalls: configuration.maximumConcurrentToolCalls,
            maximumArgumentBytes: configuration.maximumToolArgumentBytes,
            maximumOutputBytes: configuration.maximumToolOutputBytes,
            approvalHandler: approvalHandler,
            onEvent: onEvent
        )
        self.configuration = configuration
        self.onEvent = onEvent
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        var request = request
        if request.tools.isEmpty {
            request.tools = executor.definitions
        } else {
            var names: Set<String> = []
            for definition in request.tools
            where !executor.contains(
                definition.name
            ) {
                throw ToolCallingLanguageModelError.unregisteredDefinition(
                    definition.name
                )
            }
            for definition in request.tools {
                guard names.insert(definition.name).inserted else {
                    throw
                        ToolCallingLanguageModelError
                        .duplicateToolDefinition(definition.name)
                }
            }
        }
        if let accessPolicy = request.toolAccessPolicy {
            request.tools = request.tools.filter { definition in
                executor.authorization(
                    for: definition.name,
                    under: accessPolicy
                ) != .denied
            }
        }
        var allowedToolNames = Set(request.tools.map(\.name))
        if case let .tool(name) = request.toolChoice,
            !allowedToolNames.contains(name)
        {
            throw ToolCallingLanguageModelError.toolNotAllowed
        }
        if request.tools.isEmpty {
            switch request.toolChoice {
            case .some(.required):
                throw ToolCallingLanguageModelError.noToolsAllowed
            case .some(.tool):
                // Named choices are rejected by the check above.
                break
            case .some(.automatic):
                request.toolChoice = LanguageModelToolChoice.disabled
            case .some(.disabled):
                break
            case nil:
                request.toolChoice = LanguageModelToolChoice.disabled
            }
        }

        let callerMessageCount = request.messages.count
        var loop = ToolLoopState()
        // Only a durable model inside a conversation node may suspend.
        let canSuspend =
            configuration.approvalMode.isDurable
            && LanguageModelToolTurnScope.current != nil

        if canSuspend,
            let pending = LanguageModelToolTurnScope.current?.claimResumption()
        {
            guard pending.prompt == request.prompt,
                pending.pendingCalls.allSatisfy({ executor.contains($0.name) })
            else {
                throw ToolCallingLanguageModelError.pendingTurnMismatch
            }
            loop = ToolLoopState(resuming: pending)
            request.messages.append(contentsOf: pending.exchange)
            removeDeniedTools(
                Set(pending.deniedToolNames),
                from: &request,
                allowedToolNames: &allowedToolNames
            )
            if loop.toolRounds > 0 { resetToolChoice(&request) }

            if !pending.pendingCalls.isEmpty {
                guard !pending.isAwaitingApproval else {
                    throw LanguageModelToolTurnSuspended(pendingTurn: pending)
                }
                // Calls without a decision are denied.
                var decisions: [String: LanguageModelToolApprovalDecision] = [:]
                for id in pending.callIDsRequiringApproval {
                    decisions[id] = pending.decisions[id] ?? .denied
                }
                let ranSideEffects = try await runRound(
                    pending.pendingCalls,
                    decisions: decisions,
                    provider: pending.provider,
                    request: &request,
                    allowedToolNames: &allowedToolNames,
                    loop: &loop
                )
                if ranSideEffects,
                    configuration.approvalMode.checkpointsAfterToolRounds
                {
                    throw LanguageModelToolTurnSuspended(
                        pendingTurn: loop.pendingTurn(
                            prompt: request.prompt,
                            exchange: Array(request.messages.dropFirst(callerMessageCount))
                        )
                    )
                }
            }
        }

        while true {
            try Task.checkCancellation()
            loop.modelCalls += 1
            var response = try await model.generate(request)

            guard !response.toolCalls.isEmpty else {
                let providerReport = response.toolExecutionReport
                response.toolExecutionReport = LanguageModelToolExecutionReport(
                    modelCalls: loop.modelCalls,
                    toolRounds: loop.toolRounds + (providerReport?.toolRounds ?? 0),
                    executions: loop.executions + (providerReport?.executions ?? []),
                    providerManaged: providerReport?.providerManaged ?? false
                )
                response.transcript =
                    Array(request.messages.dropFirst(callerMessageCount))
                    + [
                        .assistant(
                            content: response.content.isEmpty ? nil : response.content,
                            toolCalls: []
                        )
                    ]
                return response
            }

            guard loop.toolRounds < configuration.maximumToolRounds else {
                throw ToolCallingLanguageModelError.maximumToolRoundsExceeded(
                    configuration.maximumToolRounds
                )
            }
            guard
                loop.executionCount + response.toolCalls.count
                    <= configuration.maximumToolCalls
            else {
                throw ToolCallingLanguageModelError.maximumToolCallsExceeded(
                    configuration.maximumToolCalls
                )
            }

            loop.toolRounds += 1
            await onEvent?(
                .roundStarted(
                    round: loop.toolRounds,
                    calls: response.toolCalls.count
                )
            )
            request.messages.append(
                .assistant(
                    content: response.content.isEmpty ? nil : response.content,
                    toolCalls: response.toolCalls
                )
            )

            for call in response.toolCalls {
                guard loop.seenCallIDs.insert(call.id).inserted else {
                    throw ToolCallingLanguageModelError.duplicateCallID
                }
                guard allowedToolNames.contains(call.name) else {
                    throw ToolCallingLanguageModelError.toolNotAllowed
                }
            }

            if canSuspend {
                // Nothing in the round runs until the application decides.
                let accessPolicy = request.toolAccessPolicy
                let needingApproval = response.toolCalls.enumerated().filter { _, call in
                    executor.requiresApproval(
                        call,
                        authorization: accessPolicy.flatMap {
                            executor.authorization(for: call.name, under: $0)
                        }
                    )
                }
                if !needingApproval.isEmpty {
                    for (index, call) in needingApproval {
                        await onEvent?(
                            .approvalRequested(
                                round: loop.toolRounds,
                                callNumber: loop.executionCount + index + 1,
                                tool: call.name
                            )
                        )
                    }
                    throw LanguageModelToolTurnSuspended(
                        pendingTurn: loop.pendingTurn(
                            prompt: request.prompt,
                            exchange: Array(request.messages.dropFirst(callerMessageCount)),
                            pendingCalls: response.toolCalls,
                            callIDsRequiringApproval: needingApproval.map(\.element.id),
                            approvalRequestID: UUID(),
                            provider: response.provider
                        )
                    )
                }
            }

            let ranSideEffects = try await runRound(
                response.toolCalls,
                decisions: [:],
                provider: response.provider,
                request: &request,
                allowedToolNames: &allowedToolNames,
                loop: &loop
            )
            if canSuspend, ranSideEffects,
                configuration.approvalMode.checkpointsAfterToolRounds
            {
                throw LanguageModelToolTurnSuspended(
                    pendingTurn: loop.pendingTurn(
                        prompt: request.prompt,
                        exchange: Array(request.messages.dropFirst(callerMessageCount))
                    )
                )
            }
        }
    }

    /// Runs one round of calls and appends their results. Returns whether a
    /// tool that may have side effects ran.
    private func runRound(
        _ calls: [LanguageModelToolCall],
        decisions: [String: LanguageModelToolApprovalDecision],
        provider: String?,
        request: inout LanguageModelRequest,
        allowedToolNames: inout Set<String>,
        loop: inout ToolLoopState
    ) async throws -> Bool {
        let completedCalls = try await executeCalls(
            calls,
            round: loop.toolRounds,
            startingCallNumber: loop.executionCount + 1,
            provider: provider,
            inParallel: request.parallelToolCalls == true,
            accessPolicy: request.toolAccessPolicy,
            decisions: decisions
        )
        loop.executionCount += completedCalls.count
        for completed in completedCalls {
            if let record = completed.record {
                loop.executions.append(record)
            }
            request.messages.append(
                .tool(
                    callID: completed.call.id,
                    content: completed.output
                )
            )
        }
        let deniedToolNames = Set(
            completedCalls.compactMap { completed in
                completed.authorizationDenied ? completed.call.name : nil
            }
        )
        loop.deniedToolNames.append(
            contentsOf: deniedToolNames.subtracting(loop.deniedToolNames).sorted()
        )
        removeDeniedTools(
            deniedToolNames,
            from: &request,
            allowedToolNames: &allowedToolNames
        )
        resetToolChoice(&request)
        return completedCalls.contains {
            $0.record != nil && executor.mayHaveSideEffects($0.call.name)
        }
    }

    private func removeDeniedTools(
        _ deniedToolNames: Set<String>,
        from request: inout LanguageModelRequest,
        allowedToolNames: inout Set<String>
    ) {
        guard !deniedToolNames.isEmpty else { return }
        request.tools.removeAll {
            deniedToolNames.contains($0.name)
        }
        allowedToolNames.subtract(deniedToolNames)
        if request.tools.isEmpty {
            request.toolChoice = LanguageModelToolChoice.disabled
        }
    }

    private func resetToolChoice(_ request: inout LanguageModelRequest) {
        if configuration.resetToolChoiceAfterFirstRound,
            request.toolChoice != nil
        {
            request.toolChoice =
                request.tools.isEmpty
                ? LanguageModelToolChoice.disabled
                : LanguageModelToolChoice.automatic
        }
    }

    private func executeCalls(
        _ calls: [LanguageModelToolCall],
        round: Int,
        startingCallNumber: Int,
        provider: String?,
        inParallel: Bool,
        accessPolicy: LanguageModelToolAccessPolicy?,
        decisions: [String: LanguageModelToolApprovalDecision]
    ) async throws -> [CompletedLanguageModelToolCall] {
        if !inParallel || calls.count < 2 {
            var completed: [CompletedLanguageModelToolCall] = []
            for (index, call) in calls.enumerated() {
                completed.append(
                    try await executeCall(
                        call,
                        index: index,
                        round: round,
                        callNumber: startingCallNumber + index,
                        provider: provider,
                        accessPolicy: accessPolicy,
                        decision: decisions[call.id]
                    )
                )
            }
            return completed
        }

        return try await withThrowingTaskGroup(
            of: CompletedLanguageModelToolCall.self
        ) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    try await executeCall(
                        call,
                        index: index,
                        round: round,
                        callNumber: startingCallNumber + index,
                        provider: provider,
                        accessPolicy: accessPolicy,
                        decision: decisions[call.id]
                    )
                }
            }

            var completed: [CompletedLanguageModelToolCall] = []
            for try await result in group {
                completed.append(result)
            }
            return completed.sorted { $0.index < $1.index }
        }
    }

    private func executeCall(
        _ call: LanguageModelToolCall,
        index: Int,
        round: Int,
        callNumber: Int,
        provider: String?,
        accessPolicy: LanguageModelToolAccessPolicy?,
        decision: LanguageModelToolApprovalDecision?
    ) async throws -> CompletedLanguageModelToolCall {
        await onEvent?(
            .callStarted(round: round, callNumber: callNumber, tool: call.name)
        )

        do {
            // A tool that runs its own conversation must not pick up or
            // suspend this turn.
            let output = try await LanguageModelToolTurnScope.$current.withValue(nil) {
                try await executor.execute(
                    call,
                    context: LanguageModelToolExecutionContext(
                        round: round,
                        callNumber: callNumber,
                        provider: provider
                    ),
                    authorization: accessPolicy.flatMap {
                        executor.authorization(for: call.name, under: $0)
                    },
                    decision: decision
                )
            }
            await onEvent?(
                .callCompleted(
                    round: round,
                    callNumber: callNumber,
                    tool: call.name
                )
            )
            return CompletedLanguageModelToolCall(
                index: index,
                call: call,
                output: output,
                record: LanguageModelToolExecutionRecord(
                    round: round,
                    callNumber: callNumber,
                    tool: call.name,
                    provider: provider
                ),
                authorizationDenied: false
            )
        } catch let error as LanguageModelToolPolicyError
            where error.isAuthorizationDenial
            && accessPolicy?.denialBehavior == .returnToModel
        {
            await onEvent?(
                .callFailed(
                    round: round,
                    callNumber: callNumber,
                    tool: call.name
                )
            )
            return CompletedLanguageModelToolCall(
                index: index,
                call: call,
                output: LanguageModelToolDenialBehavior.redactedModelResponse,
                record: nil,
                authorizationDenied: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await onEvent?(
                .callFailed(
                    round: round,
                    callNumber: callNumber,
                    tool: call.name
                )
            )
            throw ToolCallingLanguageModelError.executionFailed(
                callNumber: callNumber,
                tool: call.name,
                failure: WorkflowFailure(error: error)
            )
        }
    }
}

private struct CompletedLanguageModelToolCall: Sendable {
    let index: Int
    let call: LanguageModelToolCall
    let output: String
    let record: LanguageModelToolExecutionRecord?
    let authorizationDenied: Bool
}

/// Counters and history of one model/tool loop, saved in a pending turn when
/// the loop suspends.
private struct ToolLoopState {
    var modelCalls = 0
    var toolRounds = 0
    var executionCount = 0
    var executions: [LanguageModelToolExecutionRecord] = []
    var seenCallIDs: Set<String> = []
    var deniedToolNames: [String] = []

    init() {}

    init(resuming pending: LanguageModelPendingToolTurn) {
        modelCalls = pending.modelCalls
        toolRounds = pending.toolRounds
        executionCount = pending.executionCount
        executions = pending.executions
        deniedToolNames = pending.deniedToolNames
        for case let .assistant(_, toolCalls) in pending.exchange {
            seenCallIDs.formUnion(toolCalls.map(\.id))
        }
    }

    func pendingTurn(
        prompt: String,
        exchange: [LanguageModelMessage],
        pendingCalls: [LanguageModelToolCall] = [],
        callIDsRequiringApproval: [String] = [],
        approvalRequestID: UUID? = nil,
        provider: String? = nil
    ) -> LanguageModelPendingToolTurn {
        LanguageModelPendingToolTurn(
            prompt: prompt,
            exchange: exchange,
            pendingCalls: pendingCalls,
            callIDsRequiringApproval: callIDsRequiringApproval,
            approvalRequestID: approvalRequestID,
            provider: provider,
            modelCalls: modelCalls,
            toolRounds: toolRounds,
            executionCount: executionCount,
            executions: executions,
            deniedToolNames: deniedToolNames
        )
    }
}
