import Foundation

/// A named JSON Schema used to guide and validate a model response.
public struct LanguageModelJSONSchema: Sendable, Equatable, Codable {
    public var name: String
    public var description: String?
    public var schema: JSONValue
    public var strict: Bool
    public var includeSchemaInPrompt: Bool

    public init(
        name: String,
        description: String? = nil,
        schema: JSONValue,
        strict: Bool = true,
        includeSchemaInPrompt: Bool = true
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.strict = strict
        self.includeSchemaInPrompt = includeSchemaInPrompt
    }
}

/// Provider-neutral control over the expected model response representation.
public enum LanguageModelResponseFormat: Sendable, Equatable, Codable {
    case jsonSchema(LanguageModelJSONSchema)
}

/// A decodable result that declares the schema providers should generate.
public protocol LanguageModelStructuredOutput: Decodable, Sendable {
    static var languageModelSchema: LanguageModelJSONSchema { get }
}

/// A typed response paired with the original provider metadata and reports.
public struct StructuredLanguageModelResponse<Output: Sendable>: Sendable {
    public let output: Output
    public let response: LanguageModelResponse

    public init(output: Output, response: LanguageModelResponse) {
        self.output = output
        self.response = response
    }
}

/// Failures produced while decoding schema-guided model output.
///
/// The raw response is intentionally excluded because it may contain sensitive
/// application or user data.
public enum StructuredLanguageModelError: Error, Sendable, Equatable {
    case decodingFailed(outputType: String, failure: WorkflowFailure)
}

/// Adds a response schema to a request, invokes a model, and strictly decodes
/// the returned JSON into `Output`.
public struct StructuredLanguageModel<Output>: Sendable
where Output: LanguageModelStructuredOutput {
    private let model: any WorkflowLanguageModel

    public init<Model: WorkflowLanguageModel>(model: Model) {
        self.model = model
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> StructuredLanguageModelResponse<Output> {
        var request = request
        request.responseFormat = .jsonSchema(Output.languageModelSchema)
        let response = try await model.generate(request)

        do {
            let output = try JSONDecoder().decode(
                Output.self,
                from: Data(response.content.utf8)
            )
            return StructuredLanguageModelResponse(
                output: output,
                response: response
            )
        } catch {
            throw StructuredLanguageModelError.decodingFailed(
                outputType: String(reflecting: Output.self),
                failure: WorkflowFailure(error: error)
            )
        }
    }
}
