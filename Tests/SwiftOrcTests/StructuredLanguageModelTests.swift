import Foundation
import Testing

@testable import SwiftOrc

private struct TestCharacterProfile: LanguageModelStructuredOutput, Equatable {
    let name: String
    let temperament: String

    static let languageModelSchema = LanguageModelJSONSchema(
        name: "character_profile",
        description: "A generated character personality.",
        schema: .objectSchema(
            properties: [
                "name": .object([
                    "type": .string("string"),
                    "description": .string("The character name."),
                ]),
                "temperament": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("playful"),
                        .string("stoic"),
                    ]),
                ]),
            ],
            required: ["name", "temperament"]
        )
    )
}

private actor StructuredRequestRecorder {
    private(set) var requests: [LanguageModelRequest] = []

    func record(_ request: LanguageModelRequest) {
        requests.append(request)
    }
}

private struct StructuredTestState: Sendable, Equatable {
    var name = ""
}

@Test
func structuredModelAddsSchemaAndDecodesTypedOutput() async throws {
    let recorder = StructuredRequestRecorder()
    let model = ClosureLanguageModel { request in
        await recorder.record(request)
        return LanguageModelResponse(
            content: #"{"name":"Pip","temperament":"playful"}"#,
            provider: "test-provider"
        )
    }
    let structured = StructuredLanguageModel<TestCharacterProfile>(model: model)

    let response = try await structured.generate(
        LanguageModelRequest(prompt: "Create a character")
    )

    #expect(
        response.output
            == TestCharacterProfile(name: "Pip", temperament: "playful")
    )
    #expect(response.response.provider == "test-provider")
    let requests = await recorder.requests
    #expect(
        requests.first?.responseFormat
            == .jsonSchema(TestCharacterProfile.languageModelSchema)
    )
}

@Test
func structuredModelDoesNotIncludeRawOutputInDecodingErrors() async throws {
    let sensitiveOutput = "private-user-content-that-is-not-json"
    let model = ClosureLanguageModel { _ in
        LanguageModelResponse(content: sensitiveOutput)
    }
    let structured = StructuredLanguageModel<TestCharacterProfile>(model: model)

    do {
        _ = try await structured.generate(
            LanguageModelRequest(prompt: "Create a character")
        )
        Issue.record("Expected invalid structured output to fail")
    } catch let error as StructuredLanguageModelError {
        guard case let .decodingFailed(outputType, failure) = error else {
            Issue.record("Expected a typed decoding failure")
            return
        }
        #expect(outputType.contains("TestCharacterProfile"))
        #expect(!failure.message.contains(sensitiveOutput))
    }
}

@Test
func structuredLanguageModelNodeReducesDecodedOutput() async throws {
    let model = ClosureLanguageModel { _ in
        LanguageModelResponse(
            content: #"{"name":"Moss","temperament":"stoic"}"#
        )
    }
    let node = StructuredLanguageModelNode<
        StructuredTestState,
        TestCharacterProfile
    >(
        id: "profile",
        model: model,
        request: { _, _ in
            LanguageModelRequest(prompt: "Create a character")
        },
        reduce: { profile, _, state, _ in
            var state = state
            state.name = profile.name
            return .finish(state)
        }
    )
    let workflow = try Workflow<StructuredTestState>(initialNode: "profile") {
        node
    }

    let result = try await workflow.run(StructuredTestState())

    #expect(result.state.name == "Moss")
    #expect(result.finalNode == "profile")
}

@Test
func structuredSchemaRoundTripsThroughCodable() throws {
    let format = LanguageModelResponseFormat.jsonSchema(
        TestCharacterProfile.languageModelSchema
    )

    let data = try JSONEncoder().encode(format)
    let decoded = try JSONDecoder().decode(
        LanguageModelResponseFormat.self,
        from: data
    )

    #expect(decoded == format)
}
