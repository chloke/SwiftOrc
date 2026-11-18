import Foundation

/// Provider-neutral image fidelity requested for one model input.
@nonexhaustive
public enum LanguageModelImageDetail: String, Sendable, Equatable, Codable {
    case automatic
    case low
    case high
}

/// Image bytes or a provider-fetchable URL used only for a model request.
@nonexhaustive
public enum LanguageModelImageSource: Sendable, Equatable, Codable {
    case data(Data, mediaType: String)
    case url(URL)
}

/// One provider-neutral image included in a multipart model request.
public struct LanguageModelImage: Sendable, Equatable, Codable {
    public var source: LanguageModelImageSource
    public var detail: LanguageModelImageDetail

    public init(
        source: LanguageModelImageSource,
        detail: LanguageModelImageDetail = .automatic
    ) {
        self.source = source
        self.detail = detail
    }
}

/// Ordered text and image content appended to a request's primary user prompt.
@nonexhaustive
public enum LanguageModelInputPart: Sendable, Equatable, Codable {
    case text(String)
    case image(LanguageModelImage)
}
