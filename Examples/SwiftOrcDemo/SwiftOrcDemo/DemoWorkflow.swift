import Foundation
import SwiftOrc
import SwiftOrcFoundationModels

struct DemoWorkflowState: Sendable, Codable {
    let request: String
    var draft: String?
    var wordCount: Int?
    var answer: String?
}

struct DemoGeneratedAnswer: LanguageModelStructuredOutput {
    let answer: String

    static let languageModelSchema = LanguageModelJSONSchema(
        name: "swiftorc_demo_answer",
        description: "The answer produced by the demonstration workflow.",
        schema: .objectSchema(
            properties: [
                "answer": .object([
                    "type": .string("string"),
                    "description": .string(
                        "A concise, self-contained answer for the user."
                    ),
                ])
            ],
            required: ["answer"]
        )
    )
}

enum DemoCalculatorOperation: String, Codable, Sendable {
    case add
    case subtract
    case multiply
    case divide
}

struct DemoCalculatorArguments: Codable, Sendable {
    let operation: DemoCalculatorOperation
    let left: Double
    let right: Double
}

struct DemoCalculatorResult: Codable, Sendable {
    let value: Double
}

enum DemoCalculatorError: Error, Sendable {
    case divisionByZero
}

enum DemoCalculatorTool {
    static func registration() -> LanguageModelToolRegistration {
        LanguageModelToolRegistration(
            tool: make(),
            policy: LanguageModelToolExecutionPolicy(
                timeout: .seconds(2)
            ),
            metadata: LanguageModelToolMetadata(
                categories: [.math],
                risk: .minimal,
                effects: [.localComputation]
            )
        )
    }

    static func make()
        -> ClosureLanguageModelTool<DemoCalculatorArguments, DemoCalculatorResult>
    {
        ClosureLanguageModelTool(
            definition: LanguageModelToolDefinition(
                name: "calculate",
                description: "Performs one arithmetic operation on two numbers.",
                parameters: .objectSchema(
                    properties: [
                        "operation": .object([
                            "type": .string("string"),
                            "description": .string("The arithmetic operation."),
                            "enum": .array([
                                .string("add"),
                                .string("subtract"),
                                .string("multiply"),
                                .string("divide"),
                            ]),
                        ]),
                        "left": .object([
                            "type": .string("number"),
                            "description": .string("The left operand."),
                        ]),
                        "right": .object([
                            "type": .string("number"),
                            "description": .string("The right operand."),
                        ]),
                    ],
                    required: ["operation", "left", "right"]
                )
            ),
            call: { arguments in
                let value: Double
                switch arguments.operation {
                case .add:
                    value = arguments.left + arguments.right
                case .subtract:
                    value = arguments.left - arguments.right
                case .multiply:
                    value = arguments.left * arguments.right
                case .divide:
                    guard arguments.right != 0 else {
                        throw DemoCalculatorError.divisionByZero
                    }
                    value = arguments.left / arguments.right
                }
                return DemoCalculatorResult(value: value)
            }
        )
    }
}

enum DemoWorkflowFactory {
    static func make(
        model: AppleFoundationModel,
        approvalHandler: @escaping LanguageModelToolApprovalHandler
    ) throws -> Workflow<DemoWorkflowState> {
        let answerProcessing = try makeAnswerProcessingComponent()
        let answerEntry = answerProcessing.entryNode
        let inspect = try makeInspectionNode(continuingTo: answerEntry)
        let fallbackModel = StaticLanguageModel(
            content:
                #"{"answer":"Apple's on-device model is currently unavailable, so the demonstration provider handled this request. The workflow still exercised provider routing, structured generation, validation, parallel inspection, branching, and checkpointing."}"#
        )
        let routedModel = try LanguageModelRouter(
            routes: [
                LanguageModelRoute(
                    provider: AppleFoundationModel.providerIdentifier,
                    kind: .onDevice,
                    capabilities: [
                        .textInput,
                        .structuredOutput,
                        .toolCalling,
                    ],
                    model: model
                ),
                LanguageModelRoute(
                    provider: "demo-deterministic-fallback",
                    kind: .staticFallback,
                    model: fallbackModel
                ),
            ]
        )
        let toolEnabledModel = try ToolCallingLanguageModel(
            model: routedModel,
            registrations: [DemoCalculatorTool.registration()],
            configuration: ToolCallingLanguageModelConfiguration(
                maximumToolRounds: 4,
                maximumToolCalls: 8,
                maximumConcurrentToolCalls: 1
            ),
            approvalHandler: approvalHandler
        )

        let generate = StructuredLanguageModelNode<
            DemoWorkflowState,
            DemoGeneratedAnswer
        >(
            id: "generate",
            model: toolEnabledModel,
            request: { state, context in
                let retryGuidance =
                    context.attempt > 1
                    ? "\nYour previous response was empty or too short. Return a substantive answer."
                    : ""

                return LanguageModelRequest(
                    prompt: state.request + retryGuidance,
                    instructions: """
                        Answer the user's request accurately. Use plain language and keep the
                        response below 250 words. Populate the structured answer field.
                        """,
                    options: LanguageModelGenerationOptions(
                        sampling: .randomProbabilityThreshold(0.9),
                        temperature: 0.3,
                        maximumResponseTokens: 350
                    ),
                    routingPolicy: .remoteThenOnDeviceAndStatic,
                    toolAccessPolicy: LanguageModelToolAccessPolicy(
                        rules: [
                            LanguageModelToolAccessRule(
                                categories: [.math],
                                maximumRisk: .low,
                                effects: [.localComputation],
                                authorization: .automatic
                            )
                        ]
                    )
                )
            },
            reduce: { output, _, state, _ in
                var state = state
                state.draft = output.answer
                return .next(state, "inspect")
            }
        )

        let usefulAnswer = WorkflowValidator<DemoWorkflowState> { state, _ in
            guard
                let draft = state.draft?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !draft.isEmpty
            else {
                return .invalid(reason: "The model returned an empty answer.")
            }
            guard draft.count >= 20 else {
                return .invalid(reason: "The model answer was too short.")
            }
            return .valid
        }

        let reliableGenerate = AnyWorkflowNode(generate)
            .validated(by: usefulAnswer, onFailure: .retry)
            .timeout(after: .seconds(30))
            .recover(to: "fallback")

        let fallback = AnyWorkflowNode<DemoWorkflowState>(id: "fallback") {
            state,
            _ in
            var state = state
            state.answer = """
                The on-device model couldn't complete this request. Check the execution
                trace for the availability, timeout, or generation error.
                """
            return .finish(state)
        }

        return try Workflow(
            definitionID: "swiftorc-demo-v2",
            initialNode: "generate",
            configuration: WorkflowConfiguration(
                maximumSteps: 6,
                maximumRetriesPerNode: 2
            )
        ) {
            reliableGenerate
            inspect
            answerProcessing
            fallback
        }
    }

    private static func makeInspectionNode(
        continuingTo target: NodeID
    ) throws -> ParallelNode<DemoWorkflowState> {
        try ParallelNode(
            id: "inspect",
            branches: [
                ParallelBranch("normalize") { state, _ in
                    var state = state
                    state.draft = state.draft?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    return state
                },
                ParallelBranch("measure") { state, _ in
                    var state = state
                    state.wordCount =
                        state.draft?
                        .split(whereSeparator: \.isWhitespace)
                        .count
                    return state
                },
            ],
            continuation: .next(target)
        ) { initialState, results, _ in
            var state = initialState
            state.draft = results[branch: "normalize"]?.draft
            state.wordCount = results[branch: "measure"]?.wordCount
            return state
        }
    }

    private static func makeAnswerProcessingComponent() throws
        -> WorkflowComponent<DemoWorkflowState>
    {
        let qualityCheck = BranchNode<DemoWorkflowState>(
            id: "quality-check",
            routes: [
                BranchRoute("substantive-answer", to: "finalize") { state, _ in
                    state.draft?.count ?? 0 >= 80
                }
            ],
            defaultTarget: "review",
            defaultRouteName: "brief-answer"
        )

        let finalize = AnyWorkflowNode<DemoWorkflowState>(id: "finalize") {
            state,
            _ in
            var state = state
            state.answer = state.draft?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return .finish(state)
        }

        let review = AnyWorkflowNode<DemoWorkflowState>(id: "review") {
            state,
            _ in
            var state = state
            state.answer = state.draft?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return .finish(state)
        }

        return try WorkflowComponent(entryNode: "quality-check") {
            qualityCheck
            finalize
            review
        }
        .namespaced("answer")
    }
}

// MARK: - Model-version compatibility example

enum DemoModelVersionSelection: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case model26
    case model27
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            "Automatic (current OS)"
        case .model26:
            "26.4–26.x profile"
        case .model27:
            "27.x profile"
        case .unsupported:
            "Unsupported model"
        }
    }

    var resolvedGeneration: DemoAppleModelGeneration {
        switch self {
        case .automatic:
            .currentOS
        case .model26:
            .model26
        case .model27:
            .model27
        case .unsupported:
            .unsupported
        }
    }
}

enum DemoAppleModelGeneration: String, Codable, Sendable {
    case model26
    case model27
    case unsupported

    static var currentOS: Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return switch (version.majorVersion, version.minorVersion) {
        case (27, _):
            .model27
        case (26, 4...):
            .model26
        default:
            .unsupported
        }
    }

    var title: String {
        switch self {
        case .model26:
            "26.4–26.x"
        case .model27:
            "27.x"
        case .unsupported:
            "Unsupported"
        }
    }
}

enum DemoRemoteBehavior: String, CaseIterable, Identifiable, Sendable {
    case succeeds
    case fails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .succeeds:
            "Succeeds"
        case .fails:
            "Fails, then static fallback"
        }
    }
}

struct ModelVersionDemoConfiguration: Sendable {
    let generation: DemoAppleModelGeneration
    let localModelAvailable: Bool
    let usesLiveAppleModel: Bool
    let allowsRemoteFallback: Bool
    let remoteBehavior: DemoRemoteBehavior
}

struct ModelVersionDemoState: Sendable, Codable {
    let request: String
    let generation: DemoAppleModelGeneration
    let localModelAvailable: Bool
    var selectedImplementation: String?
    var answer: String?
}

private enum ModelVersionDemoError: Error, Sendable {
    case simulatedRemoteUnavailable
}

enum ModelVersionDemoFactory {
    static func make<Model: WorkflowLanguageModel>(
        localModel: Model,
        configuration: ModelVersionDemoConfiguration
    ) throws -> Workflow<ModelVersionDemoState> {
        let localProvider =
            configuration.usesLiveAppleModel
            ? AppleFoundationModel.providerIdentifier
            : "simulated-apple-on-device"
        let localRouter = try LanguageModelRouter(
            routes: [
                LanguageModelRoute(
                    provider: localProvider,
                    kind: .onDevice,
                    capabilities: [.textInput],
                    model: localModel
                )
            ]
        )

        let selectVersion = BranchNode<ModelVersionDemoState>(
            id: "select-model-version",
            routes: [
                BranchRoute("model-27", to: "task-v27") { state, _ in
                    state.generation == .model27 && state.localModelAvailable
                },
                BranchRoute("model-26", to: "task-v26") { state, _ in
                    state.generation == .model26 && state.localModelAvailable
                },
            ],
            defaultTarget: "fallback",
            defaultRouteName: "local-model-not-validated-or-unavailable"
        )

        let model27 = makeLocalTask(
            id: "task-v27",
            profileName: "27.x task implementation",
            instructions: """
                This prompt was evaluated for the Apple foundation model bundled with
                version 27 operating systems. Answer clearly in no more than 120 words.
                """,
            model: localRouter
        )
        .recover(to: "fallback")

        let model26 = makeLocalTask(
            id: "task-v26",
            profileName: "26.4–26.x task implementation",
            instructions: """
                This is the conservative prompt evaluated for the Apple foundation model
                bundled with version 26.4 and later 26.x operating systems. Return one
                short, direct paragraph and avoid adding information not in the request.
                """,
            model: localRouter
        )
        .recover(to: "fallback")

        let remoteBehavior = configuration.remoteBehavior
        let mockRemote = ClosureLanguageModel { request in
            guard remoteBehavior == .succeeds else {
                throw ModelVersionDemoError.simulatedRemoteUnavailable
            }
            return LanguageModelResponse(
                content: """
                    Simulated remote result for: \(request.prompt)

                    No network request was made. A closure-backed model produced this
                    deterministic demonstration response.
                    """,
                provider: "closure-backed-demo-model"
            )
        }
        let staticFallback = StaticLanguageModel(
            content: """
                A safe static result was used because no validated local task was
                available and no permitted simulated provider completed the request.
                """,
            provider: "bundled-demo-copy"
        )
        let fallbackRouter = try LanguageModelRouter(
            routes: [
                LanguageModelRoute(
                    provider: "mock-remote",
                    kind: .remote,
                    capabilities: [.textInput],
                    model: mockRemote
                ),
                LanguageModelRoute(
                    provider: "safe-static-copy",
                    kind: .staticFallback,
                    model: staticFallback
                ),
            ]
        )
        let fallbackPolicy =
            configuration.allowsRemoteFallback
            ? LanguageModelRoutingPolicy(
                allowedKinds: [.remote, .staticFallback]
            )
            : .staticFallbackOnly
        let fallback = LanguageModelNode<ModelVersionDemoState>(
            id: "fallback",
            model: fallbackRouter,
            request: { state, _ in
                LanguageModelRequest(
                    prompt: state.request,
                    routingPolicy: fallbackPolicy
                )
            },
            reduce: { response, state, _ in
                var state = state
                state.selectedImplementation =
                    response.provider
                    ?? "fallback provider"
                state.answer = response.content
                return .finish(state)
            }
        )

        return try Workflow(
            definitionID: "model-version-compatibility-demo-v1",
            initialNode: "select-model-version",
            configuration: WorkflowConfiguration(maximumSteps: 4)
        ) {
            selectVersion
            model27
            model26
            fallback
        }
    }

    static func simulatedLocalModel() -> ClosureLanguageModel {
        ClosureLanguageModel { request in
            let profile =
                request.instructions?.contains("version 27") == true
                ? "27.x"
                : "26.4–26.x"
            return LanguageModelResponse(
                content: """
                    Simulated on-device result using the \(profile) prompt profile.

                    Request: \(request.prompt)
                    """,
                provider: "closure-backed-local-model"
            )
        }
    }

    private static func makeLocalTask<Model: WorkflowLanguageModel>(
        id: NodeID,
        profileName: String,
        instructions: String,
        model: Model
    ) -> AnyWorkflowNode<ModelVersionDemoState> {
        AnyWorkflowNode(
            LanguageModelNode<ModelVersionDemoState>(
                id: id,
                model: model,
                request: { state, _ in
                    LanguageModelRequest(
                        prompt: state.request,
                        instructions: instructions,
                        routingPolicy: .onDeviceOnly
                    )
                },
                reduce: { response, state, _ in
                    var state = state
                    state.selectedImplementation = profileName
                    state.answer = response.content
                    return .finish(state)
                }
            )
        )
    }
}
