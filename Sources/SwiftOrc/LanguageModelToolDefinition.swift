import Foundation

/// A Sendable, Codable representation of arbitrary JSON data.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(
            [String: JSONValue].self
        ) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "The value is not valid JSON."
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    /// Builds the JSON Schema used by a function tool with an object input.
    public static func objectSchema(
        properties: [String: JSONValue],
        required: [String],
        additionalProperties: Bool = false
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(additionalProperties),
        ])
    }
}

/// A provider-neutral function definition exposed to a language model.
public struct LanguageModelToolDefinition: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    public let strict: Bool

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        strict: Bool = true
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}

/// How the model may select from the tools on one request.
public enum LanguageModelToolChoice: Sendable, Equatable, Codable {
    case automatic
    case none
    case required
    case tool(String)
}

/// One function invocation requested by a model.
public struct LanguageModelToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Provider-neutral conversation state appended after the original prompt.
public enum LanguageModelMessage: Sendable, Equatable, Codable {
    case user(String)
    case userContent([LanguageModelInputPart])
    case assistant(content: String?, toolCalls: [LanguageModelToolCall])
    case tool(callID: String, content: String)
}

/// A callable function available to a ``ToolCallingLanguageModel``.
public protocol LanguageModelTool: Sendable {
    var definition: LanguageModelToolDefinition { get }

    func call(arguments: String) async throws -> String
}

/// A typed, closure-backed tool. Arguments are decoded from JSON and results
/// are returned to the model as JSON.
public struct ClosureLanguageModelTool<Arguments, Output>: LanguageModelTool
where Arguments: Decodable & Sendable, Output: Encodable & Sendable {
    public let definition: LanguageModelToolDefinition

    private let operation: @Sendable (Arguments) async throws -> Output

    public init(
        definition: LanguageModelToolDefinition,
        call: @escaping @Sendable (Arguments) async throws -> Output
    ) {
        self.definition = definition
        operation = call
    }

    public func call(arguments: String) async throws -> String {
        let decoded: Arguments
        do {
            decoded = try JSONDecoder().decode(
                Arguments.self,
                from: Data(arguments.utf8)
            )
        } catch {
            throw LanguageModelToolInvocationError.invalidArguments(
                tool: definition.name,
                failure: WorkflowFailure(error: error)
            )
        }

        let output = try await operation(decoded)
        do {
            return String(
                decoding: try JSONEncoder().encode(output),
                as: UTF8.self
            )
        } catch {
            throw LanguageModelToolInvocationError.outputEncodingFailed(
                tool: definition.name,
                failure: WorkflowFailure(error: error)
            )
        }
    }
}

/// Type-erases heterogeneous tool implementations.
package struct AnyLanguageModelTool: LanguageModelTool {
    package let definition: LanguageModelToolDefinition

    private let operation: @Sendable (String) async throws -> String

    package init<Tool: LanguageModelTool>(_ tool: Tool) {
        definition = tool.definition
        operation = tool.call
    }

    package func call(arguments: String) async throws -> String {
        try await operation(arguments)
    }
}
