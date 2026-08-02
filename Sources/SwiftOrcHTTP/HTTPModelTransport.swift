import Foundation

/// The transport-neutral result of one HTTP request.
public struct HTTPModelTransportResponse: Sendable, Equatable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(
        data: Data,
        statusCode: Int,
        headers: [String: String] = [:]
    ) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    public func header(named name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

/// An injectable HTTP client used by remote model adapters.
public protocol HTTPModelTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPModelTransportResponse
}

/// The response metadata and server-sent-event lines from a streaming request.
public struct HTTPModelTransportStream: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let lines: AsyncThrowingStream<String, any Error>

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        lines: AsyncThrowingStream<String, any Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.lines = lines
    }

    public func header(named name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

/// An optional transport refinement used only by streaming model adapters.
public protocol HTTPStreamingModelTransport: HTTPModelTransport {
    func stream(_ request: URLRequest) async throws -> HTTPModelTransportStream
}

/// Hard byte and event limits enforced by the bundled HTTP transport and
/// OpenAI-compatible adapter. These limits bound memory use even when a remote
/// provider is faulty or malicious.
public struct HTTPModelResourceLimits: Sendable, Equatable {
    public var maximumRequestBodyBytes: Int
    public var maximumResponseBodyBytes: Int
    public var maximumStreamingEventBytes: Int
    public var maximumStreamingResponseBytes: Int
    public var maximumStreamingEvents: Int

    public init(
        maximumRequestBodyBytes: Int = 32 * 1_024 * 1_024,
        maximumResponseBodyBytes: Int = 8 * 1_024 * 1_024,
        maximumStreamingEventBytes: Int = 1 * 1_024 * 1_024,
        maximumStreamingResponseBytes: Int = 32 * 1_024 * 1_024,
        maximumStreamingEvents: Int = 10_000
    ) {
        self.maximumRequestBodyBytes = maximumRequestBodyBytes
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
        self.maximumStreamingEventBytes = maximumStreamingEventBytes
        self.maximumStreamingResponseBytes = maximumStreamingResponseBytes
        self.maximumStreamingEvents = maximumStreamingEvents
    }

    public static let `default` = HTTPModelResourceLimits()

    package var isValid: Bool {
        maximumRequestBodyBytes > 0
            && maximumResponseBodyBytes > 0
            && maximumStreamingEventBytes > 0
            && maximumStreamingResponseBytes >= maximumStreamingEventBytes
            && maximumStreamingEvents > 0
    }
}

/// The production transport backed by `URLSession`.
public struct URLSessionHTTPModelTransport: HTTPStreamingModelTransport {
    private let session: URLSession
    private let limits: HTTPModelResourceLimits

    /// Creates an isolated session with no shared cookies, credentials, or
    /// cache. Redirects are restricted to the request's original origin.
    public init(limits: HTTPModelResourceLimits = .default) {
        self.limits = limits
        session = Self.makeSecureSession()
    }

    /// Uses an application-owned session. The application is responsible for
    /// its cache, cookie, credential, TLS, and redirect policies.
    public init(
        session: URLSession,
        limits: HTTPModelResourceLimits = .default
    ) {
        self.session = session
        self.limits = limits
    }

    public func send(
        _ request: URLRequest
    ) async throws -> HTTPModelTransportResponse {
        guard limits.isValid else {
            throw HTTPModelTransportError.invalidResourceLimits
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HTTPModelTransportError.nonHTTPResponse
        }
        try Self.validateContentLength(
            response,
            maximum: limits.maximumResponseBodyBytes
        )

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(
                    Int(response.expectedContentLength),
                    limits.maximumResponseBodyBytes
                )
            )
        }
        for try await byte in bytes {
            guard data.count < limits.maximumResponseBodyBytes else {
                throw HTTPModelTransportError.responseBodyTooLarge(
                    maximum: limits.maximumResponseBodyBytes
                )
            }
            data.append(byte)
        }

        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }

        return HTTPModelTransportResponse(
            data: data,
            statusCode: response.statusCode,
            headers: headers
        )
    }

    public func stream(
        _ request: URLRequest
    ) async throws -> HTTPModelTransportStream {
        guard limits.isValid else {
            throw HTTPModelTransportError.invalidResourceLimits
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HTTPModelTransportError.nonHTTPResponse
        }
        try Self.validateContentLength(
            response,
            maximum: limits.maximumStreamingResponseBytes
        )

        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }

        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    var lineBytes: [UInt8] = []
                    var totalBytes = 0
                    var eventCount = 0
                    lineBytes.reserveCapacity(
                        min(4_096, limits.maximumStreamingEventBytes)
                    )

                    for try await byte in bytes {
                        totalBytes += 1
                        guard
                            totalBytes <= limits.maximumStreamingResponseBytes
                        else {
                            throw
                                HTTPModelTransportError
                                .streamingResponseTooLarge(
                                    maximum: limits.maximumStreamingResponseBytes
                                )
                        }

                        if byte == 0x0A {
                            if lineBytes.last == 0x0D {
                                lineBytes.removeLast()
                            }
                            eventCount += 1
                            guard eventCount <= limits.maximumStreamingEvents else {
                                throw
                                    HTTPModelTransportError
                                    .tooManyStreamingEvents(
                                        maximum: limits.maximumStreamingEvents
                                    )
                            }
                            continuation.yield(
                                String(decoding: lineBytes, as: UTF8.self)
                            )
                            lineBytes.removeAll(keepingCapacity: true)
                        } else {
                            guard
                                lineBytes.count
                                    < limits.maximumStreamingEventBytes
                            else {
                                throw
                                    HTTPModelTransportError
                                    .streamingEventTooLarge(
                                        maximum: limits.maximumStreamingEventBytes
                                    )
                            }
                            lineBytes.append(byte)
                        }
                    }

                    if !lineBytes.isEmpty {
                        eventCount += 1
                        guard eventCount <= limits.maximumStreamingEvents else {
                            throw HTTPModelTransportError.tooManyStreamingEvents(
                                maximum: limits.maximumStreamingEvents
                            )
                        }
                        continuation.yield(
                            String(decoding: lineBytes, as: UTF8.self)
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPModelTransportStream(
            statusCode: response.statusCode,
            headers: headers,
            lines: lines
        )
    }

    private static func makeSecureSession() -> URLSession {
        let configuration = makeSecureConfiguration()
        return URLSession(
            configuration: configuration,
            delegate: SameOriginRedirectDelegate(),
            delegateQueue: nil
        )
    }

    static func makeSecureConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    private static func validateContentLength(
        _ response: HTTPURLResponse,
        maximum: Int
    ) throws {
        guard response.expectedContentLength > Int64(maximum) else { return }
        throw HTTPModelTransportError.responseBodyTooLarge(maximum: maximum)
    }
}

public enum HTTPModelTransportError: Error, Sendable, Equatable {
    case nonHTTPResponse
    case invalidResourceLimits
    case responseBodyTooLarge(maximum: Int)
    case streamingEventTooLarge(maximum: Int)
    case streamingResponseTooLarge(maximum: Int)
    case tooManyStreamingEvents(maximum: Int)
}

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
            let redirectedURL = request.url,
            Self.haveSameOrigin(originalURL, redirectedURL)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func haveSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// Resolves request headers at call time, allowing credentials to come from
/// Keychain or another application-owned secret store.
public struct HTTPRequestHeaders: Sendable {
    private let resolver: @Sendable () async throws -> [String: String]

    public init(
        resolve: @escaping @Sendable () async throws -> [String: String]
    ) {
        resolver = resolve
    }

    public static let none = HTTPRequestHeaders { [:] }

    public static func bearerToken(_ token: String) -> HTTPRequestHeaders {
        HTTPRequestHeaders {
            try bearerHeaders(token)
        }
    }

    public static func bearerToken(
        resolve: @escaping @Sendable () async throws -> String
    ) -> HTTPRequestHeaders {
        HTTPRequestHeaders {
            try bearerHeaders(try await resolve())
        }
    }

    /// Resolves the headers for one request. Remote adapter packages use this
    /// at call time so applications can keep credentials in Keychain.
    public func values() async throws -> [String: String] {
        try await resolver()
    }

    private static func bearerHeaders(
        _ token: String
    ) throws -> [String: String] {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPRequestHeadersError.missingBearerToken
        }
        guard !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw HTTPRequestHeadersError.invalidBearerToken
        }
        return ["Authorization": "Bearer \(token)"]
    }
}

public enum HTTPRequestHeadersError: Error, Sendable, Equatable {
    case missingBearerToken
    case invalidBearerToken
}
