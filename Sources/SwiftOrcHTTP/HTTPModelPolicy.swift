import Foundation

/// Which endpoint schemes remote adapters accept. Secure HTTPS is the default;
/// cleartext HTTP can be enabled only for a loopback development server.
public enum HTTPModelEndpointSecurityPolicy: Sendable, Equatable {
    case httpsOnly
    case allowInsecureLoopback
}

/// Retry settings used inside one remote provider before the router moves on.
public struct HTTPModelRetryPolicy: Sendable, Equatable {
    public var maximumAttempts: Int
    public var baseDelaySeconds: Double
    public var maximumDelaySeconds: Double
    public var retryableStatusCodes: Set<Int>

    public init(
        maximumAttempts: Int = 2,
        baseDelaySeconds: Double = 0.5,
        maximumDelaySeconds: Double = 8,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    ) {
        self.maximumAttempts = maximumAttempts
        self.baseDelaySeconds = baseDelaySeconds
        self.maximumDelaySeconds = maximumDelaySeconds
        self.retryableStatusCodes = retryableStatusCodes
    }

    public static let none = HTTPModelRetryPolicy(
        maximumAttempts: 1,
        baseDelaySeconds: 0,
        maximumDelaySeconds: 0,
        retryableStatusCodes: []
    )

    package func delaySeconds(afterFailedAttempt attempt: Int) -> Double {
        let multiplier = pow(2, Double(max(0, attempt - 1)))
        return min(maximumDelaySeconds, baseDelaySeconds * multiplier)
    }
}

/// A redacted diagnostic event. Prompt text, bodies, headers, endpoints, and
/// credentials are intentionally excluded.
public enum HTTPModelProviderEvent: Sendable, Equatable {
    case requestStarted(provider: String, attempt: Int)
    case retryScheduled(
        provider: String,
        nextAttempt: Int,
        delaySeconds: Double,
        reason: RetryReason
    )
    case requestSucceeded(provider: String, statusCode: Int, attempt: Int)
    case requestFailed(
        provider: String,
        statusCode: Int?,
        attempt: Int,
        retryable: Bool
    )

    public enum RetryReason: Sendable, Equatable {
        case transport
        case statusCode(Int)
    }
}

public typealias HTTPModelProviderEventHandler =
    @Sendable (
        HTTPModelProviderEvent
    ) async -> Void
