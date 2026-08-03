import Foundation
import FoundationModels
import SwiftOrc
import Testing

@testable import SwiftOrcFoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private struct AddArguments: Codable, Sendable {
    let left: Int
    let right: Int
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private struct AddResult: Codable, Sendable, Equatable {
    let sum: Int
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private func addTool() -> ClosureLanguageModelTool<AddArguments, AddResult> {
    ClosureLanguageModelTool(
        definition: LanguageModelToolDefinition(
            name: "add",
            description: "Adds two integers.",
            parameters: .objectSchema(
                properties: [
                    "left": .object([
                        "type": .string("integer"),
                        "description": .string("The first integer."),
                    ]),
                    "right": .object([
                        "type": .string("integer"),
                        "description": .string("The second integer."),
                    ]),
                ],
                required: ["left", "right"]
            )
        ),
        call: { arguments in
            AddResult(sum: arguments.left + arguments.right)
        }
    )
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private func nativeAddTool() throws -> AppleBridgedTool {
    let registration = LanguageModelToolRegistration(tool: addTool())
    let definition = try AppleBridgedToolDefinition(
        definition: registration.definition
    )
    let recorder = AppleToolExecutionRecorder(onEvent: nil)
    let executor = try LanguageModelToolExecutor(registrations: [registration])
    return definition.makeTool(recorder: recorder, executor: executor)
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func acceptsProviderNeutralToolsWithSupportedSchemas() throws {
    _ = try AppleFoundationModel(workflowTools: [addTool()])
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func nativeToolsAreDisabledByExplicitNoneChoice() throws {
    let model = AppleFoundationModel(nativeTools: [try nativeAddTool()])
    let selected = try model.selectedNativeTools(
        for: LanguageModelRequest(
            prompt: "Do not use tools.",
            toolChoice: LanguageModelToolChoice.none,
            toolAccessPolicy: LanguageModelToolAccessPolicy(rules: [])
        )
    )

    #expect(selected.isEmpty)
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func nativeToolsHonorRequestScopedSelection() throws {
    let model = AppleFoundationModel(nativeTools: [try nativeAddTool()])
    let selected = try model.selectedNativeTools(
        for: LanguageModelRequest(
            prompt: "Add two numbers.",
            tools: [addTool().definition],
            toolChoice: .tool("add")
        )
    )

    #expect(selected.map(\.name) == ["add"])
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func nativeToolsRejectUnsupportedAccessPolicies() throws {
    let model = AppleFoundationModel(nativeTools: [try nativeAddTool()])

    do {
        _ = try model.selectedNativeTools(
            for: LanguageModelRequest(
                prompt: "Add two numbers.",
                toolAccessPolicy: LanguageModelToolAccessPolicy(rules: [])
            )
        )
        Issue.record("Expected native tool access policy to be rejected")
    } catch let error as AppleFoundationModelError {
        #expect(
            error == .unsupportedInput(kind: "native-tool-access-policy")
        )
    }
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func rejectsInvalidAppleToolConcurrencyBeforeBuildingExecutor() throws {
    do {
        _ = try AppleFoundationModel(
            workflowToolRegistrations: [
                LanguageModelToolRegistration(tool: addTool())
            ],
            maximumConcurrentToolCalls: 0
        )
        Issue.record("Expected invalid concurrency to fail")
    } catch let error as AppleFoundationModelToolBridgeError {
        #expect(error == .invalidMaximumConcurrentToolCalls)
    }
}

@Test
@available(iOS 26.4, macOS 26.4, visionOS 26.4, *)
func acceptsNullableToolPropertiesOnSupportedSystems() throws {
    struct Arguments: Codable, Sendable { let note: String? }
    struct Result: Codable, Sendable { let accepted: Bool }

    let tool = ClosureLanguageModelTool<Arguments, Result>(
        definition: LanguageModelToolDefinition(
            name: "accept_note",
            description: "Accepts an optional note.",
            parameters: .objectSchema(
                properties: [
                    "note": .object([
                        "type": .array([.string("string"), .string("null")])
                    ])
                ],
                required: ["note"]
            )
        ),
        call: { _ in Result(accepted: true) }
    )

    _ = try AppleFoundationModel(workflowTools: [tool])
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func rejectsSchemasAppleCannotRepresent() throws {
    struct Arguments: Codable, Sendable { let value: String }
    struct Result: Codable, Sendable { let value: String }

    let tool = ClosureLanguageModelTool<Arguments, Result>(
        definition: LanguageModelToolDefinition(
            name: "unsupported",
            description: "Uses an unsupported schema.",
            parameters: .objectSchema(
                properties: [
                    "value": .object(["type": .string("null")])
                ],
                required: ["value"]
            )
        ),
        call: { Result(value: $0.value) }
    )

    do {
        _ = try AppleFoundationModel(workflowTools: [tool])
        Issue.record("Expected an unsupported schema to fail")
    } catch let error as AppleFoundationModelToolBridgeError {
        guard case let .invalidSchema(tool, path, reason) = error else {
            Issue.record("Expected an invalid-schema error")
            return
        }
        #expect(tool == "unsupported")
        #expect(path == "$.value")
        #expect(reason.contains("Unsupported JSON Schema type"))
    }
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func bridgedToolDecodesArgumentsAndRecordsExecution() async throws {
    let registration = LanguageModelToolRegistration(tool: addTool())
    let definition = try AppleBridgedToolDefinition(
        definition: registration.definition
    )
    let recorder = AppleToolExecutionRecorder(onEvent: nil)
    let executor = try LanguageModelToolExecutor(
        registrations: [registration]
    )
    let tool = definition.makeTool(
        recorder: recorder,
        executor: executor
    )
    let arguments = try GeneratedContent(
        json: #"{"left":20,"right":22}"#
    )

    let output = try await tool.call(arguments: arguments)
    let result = try JSONDecoder().decode(
        AddResult.self,
        from: Data(output.utf8)
    )

    #expect(result == AddResult(sum: 42))
    let executions = await recorder.executions
    #expect(executions.count == 1)
    #expect(executions[0].tool == "add")
    #expect(executions[0].provider == AppleFoundationModel.providerIdentifier)
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func bridgedToolsEnforceSharedApprovalPolicies() async throws {
    let registration = LanguageModelToolRegistration(
        tool: addTool(),
        policy: LanguageModelToolExecutionPolicy(approval: .always)
    )
    let definition = try AppleBridgedToolDefinition(
        definition: registration.definition
    )
    let recorder = AppleToolExecutionRecorder(onEvent: nil)
    let executor = try LanguageModelToolExecutor(
        registrations: [registration],
        approvalHandler: { _ in .denied }
    )
    let tool = definition.makeTool(
        recorder: recorder,
        executor: executor
    )
    let arguments = try GeneratedContent(
        json: #"{"left":20,"right":22}"#
    )

    do {
        _ = try await tool.call(arguments: arguments)
        Issue.record("Expected the Apple-bridged call to be denied")
    } catch let error as LanguageModelToolPolicyError {
        #expect(error == .approvalDenied(tool: "add"))
    }
    #expect(await recorder.executions.isEmpty)
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func bridgedToolsCanReturnAuthorizationDenialForReplanning() async throws {
    let registration = LanguageModelToolRegistration(
        tool: addTool(),
        metadata: LanguageModelToolMetadata(
            categories: [.math],
            risk: .minimal,
            effects: [.localComputation]
        )
    )
    let definition = try AppleBridgedToolDefinition(
        definition: registration.definition
    )
    let recorder = AppleToolExecutionRecorder(onEvent: nil)
    let executor = try LanguageModelToolExecutor(
        registrations: [registration]
    )
    let tool = definition.makeTool(
        recorder: recorder,
        executor: executor,
        authorization: .userApproval,
        denialBehavior: .returnToModel
    )
    let arguments = try GeneratedContent(
        json: #"{"left":20,"right":22}"#
    )

    let output = try await tool.call(arguments: arguments)

    #expect(output == LanguageModelToolDenialBehavior.redactedModelResponse)
    #expect(await recorder.executions.isEmpty)
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func convertsProviderNeutralResponseSchemasForAppleGeneration() throws {
    let schema = LanguageModelJSONSchema(
        name: "character_profile",
        schema: .objectSchema(
            properties: [
                "name": .object(["type": .string("string")]),
                "playful": .object(["type": .string("boolean")]),
            ],
            required: ["name", "playful"]
        )
    )

    let converted = try AppleToolSchemaConverter.convertResponse(schema)

    #expect(converted.debugDescription.contains("name"))
    #expect(converted.debugDescription.contains("playful"))
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func reportsUnsupportedAppleResponseSchemasSeparatelyFromTools() throws {
    let schema = LanguageModelJSONSchema(
        name: "unsupported_response",
        schema: .objectSchema(
            properties: [
                "value": .object(["type": .string("null")])
            ],
            required: ["value"]
        )
    )

    do {
        _ = try AppleToolSchemaConverter.convertResponse(schema)
        Issue.record("Expected the response schema to be rejected")
    } catch let error as AppleFoundationModelError {
        guard case let .invalidResponseSchema(name, path, reason) = error else {
            Issue.record("Expected a response-schema error")
            return
        }
        #expect(name == "unsupported_response")
        #expect(path == "$.value")
        #expect(reason.contains("Unsupported JSON Schema type"))
    }
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func appleAdapterAppendsProviderNeutralTextInput() throws {
    let prompt = try AppleFoundationModel.prompt(
        from: LanguageModelRequest(
            prompt: "Describe the character.",
            input: [.text("Use a playful tone.")]
        )
    )

    #expect(prompt == "Describe the character.\n\nUse a playful tone.")
}

@Test
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
func appleAdapterExplicitlyRejectsImageInput() throws {
    let request = LanguageModelRequest(
        prompt: "Describe the image.",
        input: [
            .image(
                LanguageModelImage(
                    source: .data(Data([1]), mediaType: "image/png")
                )
            )
        ]
    )

    do {
        _ = try AppleFoundationModel.prompt(from: request)
        Issue.record("Expected image input to be rejected")
    } catch let error as AppleFoundationModelError {
        #expect(error == .unsupportedInput(kind: "image"))
    }
}
