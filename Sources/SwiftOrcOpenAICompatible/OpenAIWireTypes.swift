import Foundation
import SwiftOrc

struct ChatCompletionRequestBody: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let topProbability: Double?
    let seed: UInt64?
    let maximumCompletionTokens: Int?
    let tools: [ChatTool]?
    let toolChoice: ChatToolChoice?
    let parallelToolCalls: Bool?
    let responseFormat: ChatResponseFormat?
    let stream: Bool?
    let streamOptions: ChatStreamOptions?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topProbability = "top_p"
        case seed
        case maximumCompletionTokens = "max_completion_tokens"
        case tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case responseFormat = "response_format"
        case stream
        case streamOptions = "stream_options"
    }
}

struct ChatStreamOptions: Encodable {
    let includeUsage = true

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

struct ChatResponseFormat: Encodable {
    let type = "json_schema"
    let jsonSchema: JSONSchema

    init(_ format: LanguageModelResponseFormat) {
        switch format {
        case let .jsonSchema(schema):
            jsonSchema = JSONSchema(schema)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    struct JSONSchema: Encodable {
        let name: String
        let description: String?
        let schema: JSONValue
        let strict: Bool

        init(_ schema: LanguageModelJSONSchema) {
            name = schema.name
            description = schema.description
            self.schema = schema.schema
            strict = schema.strict
        }
    }
}

struct ChatMessage: Encodable {
    let role: String
    let content: ChatMessageContent?
    let toolCalls: [ChatToolCall]?
    let toolCallID: String?

    init(
        role: String,
        content: String?,
        toolCalls: [ChatToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.init(
            role: role,
            encodedContent: content.map(ChatMessageContent.text),
            toolCalls: toolCalls,
            toolCallID: toolCallID
        )
    }

    private init(
        role: String,
        encodedContent: ChatMessageContent?,
        toolCalls: [ChatToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        content = encodedContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    init(
        userPrompt: String,
        input: [LanguageModelInputPart],
        maximumInlineImageBytes: Int
    ) throws {
        guard !input.isEmpty else {
            self.init(role: "user", content: userPrompt)
            return
        }
        let parts = [LanguageModelInputPart.text(userPrompt)] + input
        self.init(
            role: "user",
            encodedContent: .parts(
                try parts.map {
                    try ChatContentPart(
                        $0,
                        maximumInlineImageBytes: maximumInlineImageBytes
                    )
                }
            )
        )
    }

    init(
        _ message: LanguageModelMessage,
        maximumInlineImageBytes: Int
    ) throws {
        switch message {
        case let .user(content):
            self.init(role: "user", content: content)
        case let .userContent(parts):
            self.init(
                role: "user",
                encodedContent: .parts(
                    try parts.map {
                        try ChatContentPart(
                            $0,
                            maximumInlineImageBytes: maximumInlineImageBytes
                        )
                    }
                )
            )
        case let .assistant(content, toolCalls):
            self.init(
                role: "assistant",
                content: content,
                toolCalls: toolCalls.map(ChatToolCall.init)
            )
        case let .tool(callID, content):
            self.init(
                role: "tool",
                content: content,
                toolCallID: callID
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

enum ChatMessageContent: Encodable {
    case text(String)
    case parts([ChatContentPart])

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

enum ChatContentPart: Encodable {
    case text(String)
    case imageURL(url: String, detail: String)

    init(
        _ part: LanguageModelInputPart,
        maximumInlineImageBytes: Int
    ) throws {
        switch part {
        case let .text(text):
            self = .text(text)
        case let .image(image):
            let url: String
            switch image.source {
            case let .url(remoteURL):
                guard let scheme = remoteURL.scheme?.lowercased(),
                    ["http", "https"].contains(scheme),
                    remoteURL.host != nil
                else {
                    throw OpenAICompatibleLanguageModelError.invalidImageURL
                }
                url = remoteURL.absoluteString
            case let .data(data, mediaType):
                guard mediaType.lowercased().hasPrefix("image/"),
                    !mediaType.contains(where: { $0.isWhitespace })
                else {
                    throw
                        OpenAICompatibleLanguageModelError
                        .invalidImageMediaType(mediaType)
                }
                guard data.count <= maximumInlineImageBytes else {
                    throw
                        OpenAICompatibleLanguageModelError
                        .inlineImageTooLarge(
                            byteCount: data.count,
                            maximum: maximumInlineImageBytes
                        )
                }
                url = "data:\(mediaType);base64,\(data.base64EncodedString())"
            }
            let detail =
                image.detail == .automatic
                ? "auto"
                : image.detail.rawValue
            self = .imageURL(url: url, detail: detail)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .imageURL(url, detail):
            try container.encode("image_url", forKey: .type)
            try container.encode(
                ImageURL(url: url, detail: detail),
                forKey: .imageURL
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private struct ImageURL: Encodable {
        let url: String
        let detail: String
    }
}

struct ChatTool: Encodable {
    let type = "function"
    let function: Function

    init(_ definition: LanguageModelToolDefinition) {
        function = Function(
            name: definition.name,
            description: definition.description,
            parameters: definition.parameters,
            strict: definition.strict
        )
    }

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
        let strict: Bool
    }
}

enum ChatToolChoice: Encodable {
    case mode(String)
    case function(String)

    init(_ choice: LanguageModelToolChoice) {
        switch choice {
        case .automatic:
            self = .mode("auto")
        case .none:
            self = .mode("none")
        case .required:
            self = .mode("required")
        case let .tool(name):
            self = .function(name)
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
            try container.encode(
                FunctionChoice(name: name),
                forKey: .function
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case function
    }

    private struct FunctionChoice: Encodable {
        let name: String
    }
}

struct ChatToolCall: Codable {
    let id: String
    let type: String
    let function: Function

    init(_ call: LanguageModelToolCall) {
        id = call.id
        type = "function"
        function = Function(name: call.name, arguments: call.arguments)
    }

    struct Function: Codable {
        let name: String
        let arguments: String
    }
}

struct ChatCompletionResponseBody: Decodable {
    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String?
        let toolCalls: [ChatToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

struct ChatCompletionStreamChunk: Decodable {
    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: ChatCompletionResponseBody.Usage?

    struct Choice: Decodable {
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }
}

struct ErrorEnvelope: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }
}
