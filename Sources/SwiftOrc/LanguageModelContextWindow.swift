import Foundation

/// Thrown when a provider rejects a request because its input exceeds the
/// model's context window.
///
/// Conversations react to it by applying their overflow strategy and retrying.
/// The provider's message is never included because it can echo request
/// content; only the token counts it reported are kept.
public struct LanguageModelContextWindowExceeded: Error, Sendable, Equatable {
    public let provider: String?
    public let maximumTokens: Int?
    public let requestedTokens: Int?

    public init(
        provider: String?,
        maximumTokens: Int? = nil,
        requestedTokens: Int? = nil
    ) {
        self.provider = provider
        self.maximumTokens = maximumTokens
        self.requestedTokens = requestedTokens
    }

    /// Recognizes a context-window rejection from a provider's error code or
    /// message and extracts any token counts it states. Used by the bundled
    /// adapters; the message is inspected but never stored.
    package static func detect(
        provider: String,
        statusCode: Int,
        code: String?,
        message: String?
    ) -> LanguageModelContextWindowExceeded? {
        guard statusCode == 400 || statusCode == 413 else { return nil }
        let lowercased = message?.lowercased() ?? ""
        let matches =
            code == "context_length_exceeded"
            || lowercased.contains("maximum context length")
            || lowercased.contains("context window")
            || lowercased.contains("prompt is too long")
        guard matches else { return nil }

        // "maximum context length is 8192 tokens ... resulted in 9000 tokens"
        // and "prompt is too long: 210000 tokens > 200000 maximum".
        let maximum =
            firstInteger(after: "maximum context length is ", in: lowercased)
            ?? firstInteger(before: " maximum", in: lowercased)
        let requested =
            firstInteger(after: "resulted in ", in: lowercased)
            ?? firstInteger(after: "prompt is too long: ", in: lowercased)
        return LanguageModelContextWindowExceeded(
            provider: provider,
            maximumTokens: maximum,
            requestedTokens: requested
        )
    }

    private static func firstInteger(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func firstInteger(before marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[..<range.lowerBound].reversed().prefix { $0.isNumber }
        return Int(String(digits.reversed()))
    }
}
