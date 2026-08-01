/// A technical request feature that a configured model route can accept.
///
/// Capabilities are declared by the application. The framework does not query
/// providers or model APIs to discover them.
public struct LanguageModelCapability: RawRepresentable, Hashable, Sendable,
    Codable, ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public static let textInput = LanguageModelCapability(
        rawValue: "text-input"
    )
    public static let imageInput = LanguageModelCapability(
        rawValue: "image-input"
    )
    public static let structuredOutput = LanguageModelCapability(
        rawValue: "structured-output"
    )
    public static let toolCalling = LanguageModelCapability(
        rawValue: "tool-calling"
    )
    public static let parallelToolCalling = LanguageModelCapability(
        rawValue: "parallel-tool-calling"
    )
    public static let conversationHistory = LanguageModelCapability(
        rawValue: "conversation-history"
    )
    public static let streaming = LanguageModelCapability(
        rawValue: "streaming"
    )
}

/// Developer-declared capabilities for one model route.
///
/// `unspecified` preserves ordinary attempt-and-fallback behavior. A declared
/// set opts the route into preflight capability filtering.
public struct LanguageModelCapabilities: Sendable, Equatable, Codable,
    ExpressibleByArrayLiteral
{
    public let declared: Set<LanguageModelCapability>?

    public init(_ capabilities: Set<LanguageModelCapability>) {
        declared = capabilities
    }

    public init(arrayLiteral elements: LanguageModelCapability...) {
        self.init(Set(elements))
    }

    private init(declared: Set<LanguageModelCapability>?) {
        self.declared = declared
    }

    public static let unspecified = LanguageModelCapabilities(declared: nil)

    public func missing(
        from requirements: Set<LanguageModelCapability>
    ) -> Set<LanguageModelCapability> {
        guard let declared else { return [] }
        return requirements.subtracting(declared)
    }

    public func supports(
        _ requirements: Set<LanguageModelCapability>
    ) -> Bool {
        missing(from: requirements).isEmpty
    }
}

public extension LanguageModelRequest {
    /// Capabilities inferred from concrete request features together with any
    /// additional requirements explicitly supplied by the application.
    var effectiveRequiredCapabilities: Set<LanguageModelCapability> {
        var requirements = requiredCapabilities
        requirements.insert(.textInput)

        if input.contains(where: \.containsImage)
            || messages.contains(where: \.containsImage)
        {
            requirements.insert(.imageInput)
        }
        if responseFormat != nil {
            requirements.insert(.structuredOutput)
        }
        if !tools.isEmpty {
            if case .some(.none) = toolChoice {
                // Tool definitions are explicitly disabled for this request.
            } else {
                requirements.insert(.toolCalling)
            }
        }
        if parallelToolCalls == true, requirements.contains(.toolCalling) {
            requirements.insert(.parallelToolCalling)
        }
        if !messages.isEmpty {
            requirements.insert(.conversationHistory)
        }
        return requirements
    }
}

private extension LanguageModelInputPart {
    var containsImage: Bool {
        if case .image = self { return true }
        return false
    }
}

private extension LanguageModelMessage {
    var containsImage: Bool {
        guard case let .userContent(parts) = self else { return false }
        return parts.contains(where: \.containsImage)
    }
}
