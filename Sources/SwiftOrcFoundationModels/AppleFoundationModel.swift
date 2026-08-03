import Foundation
import FoundationModels
import SwiftOrc

/// The current availability of Apple's on-device system language model.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public enum AppleFoundationModelAvailability: Sendable, Equatable {
    case available
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown
    }
}

/// Errors produced before a request can be sent to Apple's model.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public enum AppleFoundationModelError: Error, Sendable, Equatable {
    case unavailable(AppleFoundationModelAvailability.Reason)
    case invalidResponseSchema(name: String, path: String, reason: String)
    case unsupportedInput(kind: String)
}

/// A JSON Schema feature that cannot be represented by Apple's dynamic
/// generation schemas.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public enum AppleFoundationModelToolBridgeError: Error, Sendable, Equatable {
    case invalidSchema(tool: String, path: String, reason: String)
    case invalidMaximumConcurrentToolCalls
    case requestedToolNotRegistered(String)
    case requestedToolNotAllowed(String)
    case noToolsAllowed
}

/// A provider adapter for Apple's on-device Foundation Models framework.
///
/// Each request creates an independent session. This prevents one workflow
/// node's transcript from leaking into another node or concurrent execution.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public struct AppleFoundationModel: StreamingWorkflowLanguageModel {
    public static let providerIdentifier = "apple-foundation-models"

    private let model: SystemLanguageModel
    private let defaultInstructions: String?
    private let nativeTools: [any Tool]
    private let workflowTools: [AppleBridgedToolDefinition]
    private let toolExecutor: LanguageModelToolExecutor?
    private let onToolEvent: LanguageModelToolEventHandler?

    public init(
        model: SystemLanguageModel = .default,
        instructions: String? = nil
    ) {
        self.model = model
        defaultInstructions = instructions
        nativeTools = []
        workflowTools = []
        toolExecutor = nil
        onToolEvent = nil
    }

    /// Creates an adapter using tools implemented directly against Apple's
    /// `FoundationModels.Tool` protocol.
    public init(
        model: SystemLanguageModel = .default,
        nativeTools: [any Tool],
        instructions: String? = nil
    ) {
        self.model = model
        defaultInstructions = instructions
        self.nativeTools = nativeTools
        workflowTools = []
        toolExecutor = nil
        onToolEvent = nil
    }

    /// Bridges provider-neutral workflow tools into Apple's native tool loop.
    public init(
        model: SystemLanguageModel = .default,
        workflowTools tools: [any LanguageModelTool],
        instructions: String? = nil,
        onToolEvent: LanguageModelToolEventHandler? = nil
    ) throws {
        try self.init(
            model: model,
            workflowToolRegistrations: tools.map {
                LanguageModelToolRegistration(tool: $0)
            },
            instructions: instructions,
            onToolEvent: onToolEvent
        )
    }

    /// Bridges policy-aware workflow tool registrations into Apple's native
    /// tool loop.
    public init(
        model: SystemLanguageModel = .default,
        workflowToolRegistrations registrations: [LanguageModelToolRegistration],
        maximumConcurrentToolCalls: Int = 1,
        instructions: String? = nil,
        approvalHandler: LanguageModelToolApprovalHandler? = nil,
        onToolEvent: LanguageModelToolEventHandler? = nil
    ) throws {
        guard maximumConcurrentToolCalls >= 1 else {
            throw AppleFoundationModelToolBridgeError
                .invalidMaximumConcurrentToolCalls
        }
        let executor = try LanguageModelToolExecutor(
            registrations: registrations,
            maximumConcurrentCalls: maximumConcurrentToolCalls,
            approvalHandler: approvalHandler,
            onEvent: onToolEvent
        )
        self.model = model
        defaultInstructions = instructions
        nativeTools = []
        workflowTools = try registrations.map { registration in
            try AppleBridgedToolDefinition(
                definition: registration.definition
            )
        }
        toolExecutor = executor
        self.onToolEvent = onToolEvent
    }

    public var availability: AppleFoundationModelAvailability {
        switch model.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            return .unavailable(Self.map(reason))
        }
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        guard request.messages.isEmpty else {
            // A stateless Apple session cannot faithfully recreate assistant
            // and tool turns. Refuse explicitly so a router can choose a
            // conversation-capable provider instead of silently dropping them.
            throw AppleFoundationModelError.unsupportedInput(
                kind: LanguageModelCapability.conversationHistory.rawValue
            )
        }

        switch availability {
        case .available:
            break
        case let .unavailable(reason):
            throw AppleFoundationModelError.unavailable(reason)
        }

        let selectedNativeTools = try selectedNativeTools(for: request)
        let recorder = AppleToolExecutionRecorder(onEvent: onToolEvent)
        let bridgedTools: [AppleBridgedTool]
        if let toolExecutor {
            bridgedTools = try selectedWorkflowTools(for: request).map {
                $0.definition.makeTool(
                    recorder: recorder,
                    executor: toolExecutor,
                    authorization: $0.authorization,
                    denialBehavior: request.toolAccessPolicy?.denialBehavior
                        ?? .failWorkflow
                )
            }
        } else {
            bridgedTools = []
        }
        let sessionTools: [any Tool] = selectedNativeTools + bridgedTools
        let session = LanguageModelSession(
            model: model,
            tools: sessionTools,
            instructions: combinedInstructions(with: request.instructions)
        )
        let responseContent: String
        let prompt = try Self.prompt(from: request)
        switch request.responseFormat {
        case let .jsonSchema(responseSchema):
            let schema = try AppleToolSchemaConverter.convertResponse(
                responseSchema
            )
            let response = try await session.respond(
                to: prompt,
                schema: schema,
                includeSchemaInPrompt: responseSchema.includeSchemaInPrompt,
                options: Self.options(from: request.options)
            )
            responseContent = response.content.jsonString
        case nil:
            let response = try await session.respond(
                to: prompt,
                options: Self.options(from: request.options)
            )
            responseContent = response.content
        }

        let executions = await recorder.executions
        let report =
            bridgedTools.isEmpty
            ? nil
            : LanguageModelToolExecutionReport(
                modelCalls: 1,
                toolRounds: 0,
                executions: executions,
                providerManaged: true
            )

        return LanguageModelResponse(
            content: responseContent,
            provider: Self.providerIdentifier,
            toolExecutionReport: report
        )
    }

    public func stream(
        _ request: LanguageModelRequest
    ) -> AsyncThrowingStream<LanguageModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard request.messages.isEmpty else {
                        throw AppleFoundationModelError.unsupportedInput(
                            kind: LanguageModelCapability.conversationHistory.rawValue
                        )
                    }
                    guard request.responseFormat == nil else {
                        throw AppleFoundationModelError.unsupportedInput(
                            kind: "streaming-structured-output"
                        )
                    }
                    guard case .available = availability else {
                        if case let .unavailable(reason) = availability {
                            throw AppleFoundationModelError.unavailable(reason)
                        }
                        return
                    }

                    let selectedNativeTools = try selectedNativeTools(for: request)
                    let recorder = AppleToolExecutionRecorder(onEvent: onToolEvent)
                    let bridgedTools: [AppleBridgedTool]
                    if let toolExecutor {
                        bridgedTools = try selectedWorkflowTools(for: request).map {
                            $0.definition.makeTool(
                                recorder: recorder,
                                executor: toolExecutor,
                                authorization: $0.authorization,
                                denialBehavior: request.toolAccessPolicy?.denialBehavior
                                    ?? .failWorkflow
                            )
                        }
                    } else {
                        bridgedTools = []
                    }
                    let session = LanguageModelSession(
                        model: model,
                        tools: selectedNativeTools + bridgedTools,
                        instructions: combinedInstructions(with: request.instructions)
                    )
                    let prompt = try Self.prompt(from: request)
                    var previous = ""

                    for try await snapshot in session.streamResponse(
                        to: prompt,
                        options: Self.options(from: request.options)
                    ) {
                        let current = snapshot.content
                        let delta = try Self.delta(current, after: previous)
                        if !delta.isEmpty {
                            continuation.yield(.textDelta(delta))
                        }
                        previous = current
                    }

                    let executions = await recorder.executions
                    continuation.yield(
                        .completed(
                            LanguageModelResponse(
                                content: previous,
                                provider: Self.providerIdentifier,
                                toolExecutionReport: bridgedTools.isEmpty
                                    ? nil
                                    : LanguageModelToolExecutionReport(
                                        modelCalls: 1,
                                        toolRounds: 0,
                                        executions: executions,
                                        providerManaged: true
                                    )
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func delta(
        _ current: String,
        after previous: String
    ) throws -> String {
        guard current.hasPrefix(previous) else {
            throw LanguageModelStreamingError.nonMonotonicSnapshot
        }
        return String(current.dropFirst(previous.count))
    }

    static func prompt(from request: LanguageModelRequest) throws
        -> String
    {
        var sections = [request.prompt]
        for part in request.input {
            switch part {
            case let .text(text):
                sections.append(text)
            case .image:
                // The current Foundation Models SDK accepts text prompts only.
                // An explicit error lets a router advance to a vision-capable
                // provider instead of silently discarding the image.
                throw AppleFoundationModelError.unsupportedInput(kind: "image")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    private func selectedWorkflowTools(
        for request: LanguageModelRequest
    ) throws -> [SelectedAppleBridgedTool] {
        guard !workflowTools.isEmpty else { return [] }
        if request.toolChoice == LanguageModelToolChoice.none { return [] }

        let registered = Dictionary(
            uniqueKeysWithValues: workflowTools.map { ($0.name, $0) }
        )
        let requestedNames: Set<String>
        if request.tools.isEmpty {
            requestedNames = Set(registered.keys)
        } else {
            requestedNames = Set(request.tools.map(\.name))
            for name in requestedNames where registered[name] == nil {
                throw
                    AppleFoundationModelToolBridgeError
                    .requestedToolNotRegistered(name)
            }
        }

        if case let .tool(name) = request.toolChoice {
            guard requestedNames.contains(name), let tool = registered[name] else {
                throw
                    AppleFoundationModelToolBridgeError
                    .requestedToolNotRegistered(name)
            }
            let authorization = request.toolAccessPolicy.flatMap {
                toolExecutor?.authorization(for: name, under: $0)
            }
            guard authorization != .denied else {
                throw
                    AppleFoundationModelToolBridgeError
                    .requestedToolNotAllowed(name)
            }
            return [
                SelectedAppleBridgedTool(
                    definition: tool,
                    authorization: authorization
                )
            ]
        }

        let selected = workflowTools.compactMap {
            tool
                -> SelectedAppleBridgedTool? in
            guard requestedNames.contains(tool.name) else { return nil }
            let authorization = request.toolAccessPolicy.flatMap {
                toolExecutor?.authorization(for: tool.name, under: $0)
            }
            guard authorization != .denied else { return nil }
            return SelectedAppleBridgedTool(
                definition: tool,
                authorization: authorization
            )
        }
        if request.toolChoice == .required, selected.isEmpty {
            throw AppleFoundationModelToolBridgeError.noToolsAllowed
        }
        return selected
    }

    func selectedNativeTools(
        for request: LanguageModelRequest
    ) throws -> [any Tool] {
        guard !nativeTools.isEmpty else { return [] }
        if request.toolChoice == LanguageModelToolChoice.none { return [] }

        // Native Foundation Models tools execute outside SwiftOrc's tool
        // executor, so request-scoped authorization and approval cannot be
        // enforced for them. Refuse the request instead of silently bypassing
        // its policy. Policy-aware applications should use bridged workflow
        // tool registrations.
        if request.toolAccessPolicy != nil {
            throw AppleFoundationModelError.unsupportedInput(
                kind: "native-tool-access-policy"
            )
        }

        let registeredNames = Set(nativeTools.map(\.name))
        let requestedNames: Set<String>
        if request.tools.isEmpty {
            requestedNames = registeredNames
        } else {
            requestedNames = Set(request.tools.map(\.name))
            for name in requestedNames where !registeredNames.contains(name) {
                throw
                    AppleFoundationModelToolBridgeError
                    .requestedToolNotRegistered(name)
            }
        }

        if case let .tool(name) = request.toolChoice {
            guard requestedNames.contains(name), registeredNames.contains(name)
            else {
                throw
                    AppleFoundationModelToolBridgeError
                    .requestedToolNotRegistered(name)
            }
            return nativeTools.filter { $0.name == name }
        }

        let selected = nativeTools.filter { requestedNames.contains($0.name) }
        if request.toolChoice == .required, selected.isEmpty {
            throw AppleFoundationModelToolBridgeError.noToolsAllowed
        }
        return selected
    }

    private func combinedInstructions(with requestInstructions: String?) -> String? {
        let sections: [String] = [defaultInstructions, requestInstructions]
            .compactMap { (instructions: String?) -> String? in
                guard let instructions else { return nil }
                let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private static func options(
        from options: LanguageModelGenerationOptions
    ) -> GenerationOptions {
        GenerationOptions(
            sampling: sampling(from: options.sampling),
            temperature: options.temperature,
            maximumResponseTokens: options.maximumResponseTokens
        )
    }

    private static func sampling(
        from sampling: LanguageModelSampling?
    ) -> GenerationOptions.SamplingMode? {
        switch sampling {
        case nil:
            return nil
        case .greedy:
            return .greedy
        case let .randomTopK(k, seed):
            return .random(top: k, seed: seed)
        case let .randomProbabilityThreshold(threshold, seed):
            return .random(probabilityThreshold: threshold, seed: seed)
        }
    }

    private static func map(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> AppleFoundationModelAvailability.Reason {
        switch reason {
        case .deviceNotEligible:
            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            return .appleIntelligenceNotEnabled
        case .modelNotReady:
            return .modelNotReady
        @unknown default:
            return .unknown
        }
    }
}
