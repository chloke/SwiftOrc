import Foundation
import SwiftOrc

struct AnthropicRequestBody: Encodable {
    let model: String
    let maximumTokens: Int
    let system: String?
    let messages: [AnthropicMessage]
    let temperature: Double?
    let topProbability: Double?
    let tools: [AnthropicTool]?
    let toolChoice: AnthropicToolChoice?
    let outputConfiguration: AnthropicOutputConfiguration?
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case maximumTokens = "max_tokens"
        case system
        case messages
        case temperature
        case topProbability = "top_p"
        case tools
        case toolChoice = "tool_choice"
        case outputConfiguration = "output_config"
        case stream
    }
}

struct AnthropicMessage: Encodable {
    let role: String
    let content: AnthropicMessageContent
}

enum AnthropicMessageContent: Encodable {
    case text(String)
    case blocks([AnthropicContentBlock])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(text): try container.encode(text)
        case let .blocks(blocks): try container.encode(blocks)
        }
    }
}

enum AnthropicContentBlock: Encodable {
    case text(String)
    case image(AnthropicImageSource)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(source):
            try container.encode("image", forKey: .type)
            try container.encode(source, forKey: .source)
        case let .toolUse(id, name, input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case let .toolResult(toolUseID, content):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
        case id
        case name
        case input
        case toolUseID = "tool_use_id"
        case content
    }
}

enum AnthropicImageSource: Encodable {
    case base64(mediaType: String, data: String)
    case url(String)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .base64(mediaType, data):
            try container.encode("base64", forKey: .type)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encode(data, forKey: .data)
        case let .url(url):
            try container.encode("url", forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
        case url
    }
}

struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let strict: Bool

    init(_ definition: LanguageModelToolDefinition) {
        name = definition.name
        description = definition.description
        inputSchema = definition.parameters
        strict = definition.strict
    }

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
        case strict
    }
}

struct AnthropicToolChoice: Encodable {
    let type: String
    let name: String?
    let disableParallelToolUse: Bool?

    init(_ choice: LanguageModelToolChoice, parallelToolCalls: Bool?) {
        disableParallelToolUse = parallelToolCalls.map { !$0 }
        switch choice {
        case .automatic, .none:
            type = "auto"
            name = nil
        case .required:
            type = "any"
            name = nil
        case let .tool(toolName):
            type = "tool"
            name = toolName
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case disableParallelToolUse = "disable_parallel_tool_use"
    }
}

struct AnthropicOutputConfiguration: Encodable {
    let format: Format

    init(_ responseFormat: LanguageModelResponseFormat) {
        switch responseFormat {
        case let .jsonSchema(schema):
            format = Format(type: "json_schema", schema: schema.schema)
        }
    }

    struct Format: Encodable {
        let type: String
        let schema: JSONValue
    }
}

struct AnthropicResponseBody: Decodable {
    let id: String?
    let model: String?
    let content: [ContentBlock]
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case content
        case stopReason = "stop_reason"
        case usage
    }

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: JSONValue?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

struct AnthropicStreamEvent: Decodable {
    let type: String
    let message: StreamMessage?
    let delta: Delta?
    let usage: AnthropicResponseBody.Usage?

    struct StreamMessage: Decodable {
        let id: String?
        let model: String?
        let usage: AnthropicResponseBody.Usage?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case stopReason = "stop_reason"
        }
    }
}

struct AnthropicErrorEnvelope: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let type: String?
        let message: String?
    }
}
