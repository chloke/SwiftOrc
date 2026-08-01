import Foundation
import Testing

@testable import SwiftOrc

private actor AccessPolicyScriptedModel: WorkflowLanguageModel {
    private var responses: [LanguageModelResponse]
    private(set) var requests: [LanguageModelRequest] = []

    init(_ responses: [LanguageModelResponse]) {
        self.responses = responses
    }

    func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}

private actor AccessPolicyRecorder {
    private(set) var values: [String] = []
    private(set) var approvals: [LanguageModelToolApprovalRequest] = []

    func record(_ value: String) {
        values.append(value)
    }

    func recordApproval(_ request: LanguageModelToolApprovalRequest) {
        approvals.append(request)
    }
}

private struct AccessPolicyAddArguments: Codable, Sendable {
    let left: Int
    let right: Int
}

private struct AccessPolicyResult: Codable, Sendable {
    let value: String
}

private func accessPolicyAddTool(
    recorder: AccessPolicyRecorder? = nil
) -> ClosureLanguageModelTool<AccessPolicyAddArguments, AccessPolicyResult> {
    ClosureLanguageModelTool(
        definition: LanguageModelToolDefinition(
            name: "add",
            description: "Adds two integers.",
            parameters: .objectSchema(
                properties: [
                    "left": .object(["type": .string("integer")]),
                    "right": .object(["type": .string("integer")]),
                ],
                required: ["left", "right"]
            )
        ),
        call: { arguments in
            await recorder?.record("\(arguments.left)+\(arguments.right)")
            return AccessPolicyResult(
                value: String(arguments.left + arguments.right)
            )
        }
    )
}

private func mathMetadata() -> LanguageModelToolMetadata {
    LanguageModelToolMetadata(
        categories: [.math],
        risk: .minimal,
        effects: [.localComputation]
    )
}

private func mathPolicy(
    authorization: LanguageModelToolAuthorization,
    denialBehavior: LanguageModelToolDenialBehavior = .failWorkflow
) -> LanguageModelToolAccessPolicy {
    LanguageModelToolAccessPolicy(
        rules: [
            LanguageModelToolAccessRule(
                categories: [.math],
                maximumRisk: .low,
                effects: [.localComputation],
                authorization: authorization
            )
        ],
        denialBehavior: denialBehavior
    )
}

@Test
func toolAccessRulesMatchMetadataInDeclarationOrder() {
    let metadata = mathMetadata()
    let policy = LanguageModelToolAccessPolicy(
        rules: [
            LanguageModelToolAccessRule(
                toolNames: ["add"],
                authorization: .denied
            ),
            LanguageModelToolAccessRule(
                categories: [.math],
                maximumRisk: .low,
                effects: [.localComputation],
                authorization: .automatic
            ),
        ],
        defaultAuthorization: .userApproval
    )

    #expect(policy.authorization(for: "add", metadata: metadata) == .denied)
    #expect(
        policy.authorization(for: "multiply", metadata: metadata)
            == .automatic
    )
    #expect(
        policy.authorization(
            for: "unclassified",
            metadata: .unclassified
        ) == .userApproval
    )
}

@Test
func requestPolicyHidesDeniedToolsBeforeModelInference() async throws {
    struct EmptyArguments: Codable, Sendable {}

    let textCalls = AccessPolicyRecorder()
    let textTool = ClosureLanguageModelTool<EmptyArguments, AccessPolicyResult>(
        definition: LanguageModelToolDefinition(
            name: "rewrite",
            description: "Rewrites text.",
            parameters: .objectSchema(properties: [:], required: [])
        ),
        call: { _ in
            await textCalls.record("called")
            return AccessPolicyResult(value: "rewritten")
        }
    )
    let model = AccessPolicyScriptedModel([
        LanguageModelResponse(content: "No tool needed.")
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [
            LanguageModelToolRegistration(
                tool: accessPolicyAddTool(),
                metadata: mathMetadata()
            ),
            LanguageModelToolRegistration(
                tool: textTool,
                metadata: LanguageModelToolMetadata(
                    categories: [.text],
                    risk: .minimal,
                    effects: [.localComputation]
                )
            ),
        ]
    )

    _ = try await toolModel.generate(
        LanguageModelRequest(
            prompt: "Work",
            toolAccessPolicy: mathPolicy(authorization: .automatic)
        )
    )

    let requests = await model.requests
    #expect(requests.count == 1)
    #expect(requests[0].tools.map(\.name) == ["add"])
    #expect(await textCalls.values.isEmpty)
}

@Test
func requestPolicyAutomaticallyAuthorizesSafeTools() async throws {
    let invocations = AccessPolicyRecorder()
    let approvals = AccessPolicyRecorder()
    let model = AccessPolicyScriptedModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "automatic-call",
                    name: "add",
                    arguments: #"{"left":20,"right":22}"#
                )
            ]
        ),
        LanguageModelResponse(content: "42"),
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [
            LanguageModelToolRegistration(
                tool: accessPolicyAddTool(recorder: invocations),
                metadata: mathMetadata()
            )
        ],
        approvalHandler: { request in
            await approvals.recordApproval(request)
            return .approved
        }
    )

    let response = try await toolModel.generate(
        LanguageModelRequest(
            prompt: "Calculate",
            toolAccessPolicy: mathPolicy(authorization: .automatic)
        )
    )

    #expect(response.content == "42")
    #expect(await invocations.values == ["20+22"])
    #expect(await approvals.approvals.isEmpty)
}

@Test
func requestPolicyCanRequireApprovalForAnAutomaticTool() async throws {
    let approvals = AccessPolicyRecorder()
    let model = AccessPolicyScriptedModel([
        LanguageModelResponse(
            content: "",
            provider: "remote",
            toolCalls: [
                LanguageModelToolCall(
                    id: "policy-approval",
                    name: "add",
                    arguments: #"{"left":1,"right":2}"#
                )
            ]
        ),
        LanguageModelResponse(content: "3"),
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [
            LanguageModelToolRegistration(
                tool: accessPolicyAddTool(),
                metadata: mathMetadata()
            )
        ],
        approvalHandler: { request in
            await approvals.recordApproval(request)
            return .approved
        }
    )

    _ = try await toolModel.generate(
        LanguageModelRequest(
            prompt: "Calculate",
            toolAccessPolicy: mathPolicy(authorization: .userApproval)
        )
    )

    #expect(await approvals.approvals.map(\.call.id) == ["policy-approval"])
}

@Test
func requestPolicyCannotBypassRegistrationApproval() async throws {
    let approvals = AccessPolicyRecorder()
    let registration = LanguageModelToolRegistration(
        tool: accessPolicyAddTool(),
        policy: LanguageModelToolExecutionPolicy(approval: .always),
        metadata: mathMetadata()
    )
    let model = AccessPolicyScriptedModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "registration-approval",
                    name: "add",
                    arguments: #"{"left":2,"right":3}"#
                )
            ]
        ),
        LanguageModelResponse(content: "5"),
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [registration],
        approvalHandler: { request in
            await approvals.recordApproval(request)
            return .approved
        }
    )

    _ = try await toolModel.generate(
        LanguageModelRequest(
            prompt: "Calculate",
            toolAccessPolicy: mathPolicy(authorization: .automatic)
        )
    )

    #expect(
        await approvals.approvals.map(\.call.id) == ["registration-approval"]
    )
}

@Test
func approvalDenialCanReturnToModelForReplanning() async throws {
    let invocations = AccessPolicyRecorder()
    let model = AccessPolicyScriptedModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "unavailable-approval",
                    name: "add",
                    arguments: #"{"left":20,"right":22}"#
                )
            ]
        ),
        LanguageModelResponse(content: "I could not run the tool."),
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [
            LanguageModelToolRegistration(
                tool: accessPolicyAddTool(recorder: invocations),
                metadata: mathMetadata()
            )
        ]
    )

    let response = try await toolModel.generate(
        LanguageModelRequest(
            prompt: "Calculate",
            toolAccessPolicy: mathPolicy(
                authorization: .userApproval,
                denialBehavior: .returnToModel
            )
        )
    )

    #expect(response.content == "I could not run the tool.")
    #expect(await invocations.values.isEmpty)
    #expect(response.toolExecutionReport?.executions.isEmpty == true)
    let requests = await model.requests
    #expect(requests[1].tools.isEmpty)
    #expect(requests[1].toolChoice == LanguageModelToolChoice.none)
    guard case let .tool(callID, output) = requests[1].messages.last else {
        Issue.record("Expected a denial result returned to the model")
        return
    }
    #expect(callID == "unavailable-approval")
    #expect(output == LanguageModelToolDenialBehavior.redactedModelResponse)
}

@Test
func requiredToolChoiceFailsWhenPolicyAllowsNoTools() async throws {
    let model = AccessPolicyScriptedModel([
        LanguageModelResponse(content: "Unused")
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [
            LanguageModelToolRegistration(
                tool: accessPolicyAddTool(),
                metadata: mathMetadata()
            )
        ]
    )

    do {
        _ = try await toolModel.generate(
            LanguageModelRequest(
                prompt: "Calculate",
                toolChoice: .required,
                toolAccessPolicy: LanguageModelToolAccessPolicy(rules: [])
            )
        )
        Issue.record("Expected the empty capability policy to reject the request")
    } catch let error as ToolCallingLanguageModelError {
        #expect(error == .noToolsAllowed)
    }
    #expect(await model.requests.isEmpty)
}
