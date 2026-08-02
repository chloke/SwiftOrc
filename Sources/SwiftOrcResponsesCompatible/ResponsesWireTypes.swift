import Foundation
import SwiftOrc

struct ResponsesRequestBody: Encodable {
    let model: String
    let instructions: String?
    let input: [ResponsesInputItem]
    let temperature: Double?
    let topProbability: Double?
    let maximumOutputTokens: Int?
    let tools: [ResponsesTool]?
    let toolChoice: ResponsesToolChoice?
    let parallelToolCalls: Bool?
    let text: ResponsesTextConfiguration?
    let stream: Bool?
    let store = false

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case temperature
        case topProbability = "top_p"
        case maximumOutputTokens = "max_output_tokens"
        case tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case text
        case stream
        case store
    }
}

enum ResponsesInputItem: Encodable {
    case message(role: String, content: ResponsesMessageContent)
    case functionCall(callID: String, name: String, arguments: String)
    case functionCallOutput(callID: String, output: String)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .message(role, content):
            try container.encode("message", forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case let .functionCall(callID, name, arguments):
            try container.encode("function_call", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case let .functionCallOutput(callID, output):
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(output, forKey: .output)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case role
        case content
        case callID = "call_id"
        case name
        case arguments
        case output
    }
}

enum ResponsesMessageContent: Encodable {
    case text(String)
    case parts([ResponsesInputContentPart])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value):
            try container.encode(value)
        case let .parts(value):
            try container.encode(value)
        }
    }
}

enum ResponsesInputContentPart: Encodable {
    case text(String)
    case image(url: String, detail: String)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(url, detail):
            try container.encode("input_image", forKey: .type)
            try container.encode(url, forKey: .imageURL)
            try container.encode(detail, forKey: .detail)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case detail
    }
}

struct ResponsesTool: Encodable {
    let type = "function"
    let name: String
    let description: String
    let parameters: JSONValue
    let strict: Bool

    init(_ definition: LanguageModelToolDefinition) {
        name = definition.name
        description = definition.description
        parameters = definition.parameters
        strict = definition.strict
    }
}

enum ResponsesToolChoice: Encodable {
    case mode(String)
    case function(String)

    init(_ choice: LanguageModelToolChoice) {
        switch choice {
        case .automatic: self = .mode("auto")
        case .none: self = .mode("none")
        case .required: self = .mode("required")
        case let .tool(name): self = .function(name)
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .mode(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .function(name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case name
    }
}

struct ResponsesTextConfiguration: Encodable {
    let format: Format

    init(_ responseFormat: LanguageModelResponseFormat) {
        switch responseFormat {
        case let .jsonSchema(schema):
            format = Format(
                type: "json_schema",
                name: schema.name,
                description: schema.description,
                schema: schema.schema,
                strict: schema.strict
            )
        }
    }

    struct Format: Encodable {
        let type: String
        let name: String
        let description: String?
        let schema: JSONValue
        let strict: Bool
    }
}

struct ResponsesResponseBody: Decodable {
    let id: String?
    let model: String?
    let status: String?
    let output: [OutputItem]
    let usage: Usage?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case status
        case output
        case usage
        case incompleteDetails = "incomplete_details"
    }

    struct OutputItem: Decodable {
        let type: String
        let content: [Content]?
        let callID: String?
        let name: String?
        let arguments: String?

        enum CodingKeys: String, CodingKey {
            case type
            case content
            case callID = "call_id"
            case name
            case arguments
        }
    }

    struct Content: Decodable {
        let type: String
        let text: String?
        let refusal: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
        }
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }
}

struct ResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let response: ResponsesResponseBody?
}

struct ResponsesErrorEnvelope: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }
}
