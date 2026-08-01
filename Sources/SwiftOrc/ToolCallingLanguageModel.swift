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

    public init(
        maximumToolRounds: Int = 8,
        maximumToolCalls: Int = 32,
        maximumConcurrentToolCalls: Int = 1,
        maximumToolArgumentBytes: Int = 1 * 1_024 * 1_024,
        maximumToolOutputBytes: Int = 1 * 1_024 * 1_024,
        resetToolChoiceAfterFirstRound: Bool = true
    ) {
        self.maximumToolRounds = maximumToolRounds
        self.maximumToolCalls = maximumToolCalls
        self.maximumConcurrentToolCalls = maximumConcurrentToolCalls
        self.maximumToolArgumentBytes = maximumToolArgumentBytes
        self.maximumToolOutputBytes = maximumToolOutputBytes
        self.resetToolChoiceAfterFirstRound = resetToolChoiceAfterFirstRound
    }
}

public enum ToolCallingLanguageModelConfigurationError: Error, Sendable,
    Equatable
{
    case invalidMaximumToolRounds
    case invalidMaximumToolCalls
    case invalidMaximumConcurrentToolCalls
    case invalidMaximumToolArgumentBytes
    case invalidMaximumToolOutputBytes
}

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
    case executionFailed(
        callNumber: Int,
        tool: String,
        failure: WorkflowFailure
    )
}

/// Redacted live diagnostics for tool execution.
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
                request.toolChoice = LanguageModelToolChoice.none
            case .some(.none):
                break
            case nil:
                request.toolChoice = LanguageModelToolChoice.none
            }
        }

        var modelCalls = 0
        var toolRounds = 0
        var executionCount = 0
        var executions: [LanguageModelToolExecutionRecord] = []
        var seenCallIDs: Set<String> = []

        while true {
            try Task.checkCancellation()
            modelCalls += 1
            var response = try await model.generate(request)

            guard !response.toolCalls.isEmpty else {
                let providerReport = response.toolExecutionReport
                response.toolExecutionReport = LanguageModelToolExecutionReport(
                    modelCalls: modelCalls,
                    toolRounds: toolRounds + (providerReport?.toolRounds ?? 0),
                    executions: executions + (providerReport?.executions ?? []),
                    providerManaged: providerReport?.providerManaged ?? false
                )
                return response
            }

            guard toolRounds < configuration.maximumToolRounds else {
                throw ToolCallingLanguageModelError.maximumToolRoundsExceeded(
                    configuration.maximumToolRounds
                )
            }
            guard
                executionCount + response.toolCalls.count
                    <= configuration.maximumToolCalls
            else {
                throw ToolCallingLanguageModelError.maximumToolCallsExceeded(
                    configuration.maximumToolCalls
                )
            }

            toolRounds += 1
            await onEvent?(
                .roundStarted(
                    round: toolRounds,
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
                guard seenCallIDs.insert(call.id).inserted else {
                    throw ToolCallingLanguageModelError.duplicateCallID
                }
                guard allowedToolNames.contains(call.name) else {
                    throw ToolCallingLanguageModelError.toolNotAllowed
                }
            }

            let completedCalls = try await executeCalls(
                response.toolCalls,
                round: toolRounds,
                startingCallNumber: executionCount + 1,
                provider: response.provider,
                inParallel: request.parallelToolCalls == true,
                accessPolicy: request.toolAccessPolicy
            )
            executionCount += completedCalls.count
            for completed in completedCalls {
                if let record = completed.record {
                    executions.append(record)
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
            if !deniedToolNames.isEmpty {
                request.tools.removeAll {
                    deniedToolNames.contains($0.name)
                }
                allowedToolNames.subtract(deniedToolNames)
                if request.tools.isEmpty {
                    request.toolChoice = LanguageModelToolChoice.none
                }
            }
            if configuration.resetToolChoiceAfterFirstRound,
                request.toolChoice != nil
            {
                request.toolChoice =
                    request.tools.isEmpty
                    ? LanguageModelToolChoice.none
                    : LanguageModelToolChoice.automatic
            }
        }
    }

    private func executeCalls(
        _ calls: [LanguageModelToolCall],
        round: Int,
        startingCallNumber: Int,
        provider: String?,
        inParallel: Bool,
        accessPolicy: LanguageModelToolAccessPolicy?
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
                        accessPolicy: accessPolicy
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
                        accessPolicy: accessPolicy
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
        accessPolicy: LanguageModelToolAccessPolicy?
    ) async throws -> CompletedLanguageModelToolCall {
        await onEvent?(
            .callStarted(round: round, callNumber: callNumber, tool: call.name)
        )

        do {
            let output = try await executor.execute(
                call,
                context: LanguageModelToolExecutionContext(
                    round: round,
                    callNumber: callNumber,
                    provider: provider
                ),
                authorization: accessPolicy.flatMap {
                    executor.authorization(for: call.name, under: $0)
                }
            )
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
