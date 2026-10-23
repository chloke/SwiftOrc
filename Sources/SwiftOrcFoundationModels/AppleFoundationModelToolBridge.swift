import Foundation
import FoundationModels
import SwiftOrc

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct SelectedAppleBridgedTool {
    let definition: AppleBridgedToolDefinition
    let authorization: LanguageModelToolAuthorization?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct AppleBridgedToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: GenerationSchema

    init(definition: LanguageModelToolDefinition) throws {
        name = definition.name
        description = definition.description
        parameters = try AppleToolSchemaConverter.convert(definition)
    }

    func makeTool(
        recorder: AppleToolExecutionRecorder,
        executor: LanguageModelToolExecutor,
        authorization: LanguageModelToolAuthorization? = nil,
        denialBehavior: LanguageModelToolDenialBehavior = .failWorkflow,
        sideEffects: LanguageModelToolSideEffectTracker? = nil
    ) -> AppleBridgedTool {
        AppleBridgedTool(
            name: name,
            description: description,
            parameters: parameters,
            executor: executor,
            authorization: authorization,
            denialBehavior: denialBehavior,
            recorder: recorder,
            sideEffects: sideEffects
        )
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct AppleBridgedTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let executor: LanguageModelToolExecutor
    let authorization: LanguageModelToolAuthorization?
    let denialBehavior: LanguageModelToolDenialBehavior
    let recorder: AppleToolExecutionRecorder
    /// Captured when the request starts, because Apple's tool loop may not
    /// call tools from a task that inherits the router's task-local value.
    let sideEffects: LanguageModelToolSideEffectTracker?

    func call(arguments: GeneratedContent) async throws -> String {
        let callID = UUID().uuidString
        let callNumber = try await recorder.started(tool: name)
        do {
            let output = try await LanguageModelToolSideEffectTracker.$current
                .withValue(sideEffects) {
                    try await executor.execute(
                        LanguageModelToolCall(
                            id: callID,
                            name: name,
                            arguments: arguments.jsonString
                        ),
                        context: LanguageModelToolExecutionContext(
                            round: 0,
                            callNumber: callNumber,
                            provider: AppleFoundationModel.providerIdentifier
                        ),
                        authorization: authorization
                    )
                }
            await recorder.completed(callNumber: callNumber, tool: name)
            return output
        } catch let error as LanguageModelToolPolicyError
            where error.isAuthorizationDenial
            && denialBehavior == .returnToModel
        {
            await recorder.failed(callNumber: callNumber, tool: name)
            return LanguageModelToolDenialBehavior.redactedModelResponse
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await recorder.failed(callNumber: callNumber, tool: name)
            throw error
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
actor AppleToolExecutionRecorder {
    private(set) var executions: [LanguageModelToolExecutionRecord] = []
    private var nextCallNumber = 1
    private let maximumCalls: Int
    private let onEvent: LanguageModelToolEventHandler?

    init(
        onEvent: LanguageModelToolEventHandler?,
        maximumCalls: Int = .max
    ) {
        self.onEvent = onEvent
        self.maximumCalls = maximumCalls
    }

    /// Apple's tool loop has no call limit of its own, so the recorder
    /// refuses calls beyond the configured maximum.
    func started(tool: String) async throws -> Int {
        guard nextCallNumber <= maximumCalls else {
            throw ToolCallingLanguageModelError.maximumToolCallsExceeded(
                maximumCalls
            )
        }
        let callNumber = nextCallNumber
        nextCallNumber += 1
        await onEvent?(
            .callStarted(round: 0, callNumber: callNumber, tool: tool)
        )
        return callNumber
    }

    func completed(callNumber: Int, tool: String) async {
        executions.append(
            LanguageModelToolExecutionRecord(
                round: 0,
                callNumber: callNumber,
                tool: tool,
                provider: AppleFoundationModel.providerIdentifier
            )
        )
        await onEvent?(
            .callCompleted(round: 0, callNumber: callNumber, tool: tool)
        )
    }

    func failed(callNumber: Int, tool: String) async {
        await onEvent?(
            .callFailed(round: 0, callNumber: callNumber, tool: tool)
        )
    }
}
