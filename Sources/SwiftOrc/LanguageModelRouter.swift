/// A semantic category used by request-level routing policies.
public struct LanguageModelRouteKind: RawRepresentable, Hashable, Sendable,
    Codable, ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String {
        rawValue
    }

    public static let remote = LanguageModelRouteKind(rawValue: "remote")
    public static let onDevice = LanguageModelRouteKind(rawValue: "on-device")
    public static let staticFallback = LanguageModelRouteKind(
        rawValue: "static-fallback"
    )
}

/// Per-request constraints applied before route-specific eligibility checks.
///
/// A `nil` allowlist permits every value; an empty allowlist permits none.
/// Policies filter routes but do not reorder them.
public struct LanguageModelRoutingPolicy: Sendable, Equatable, Codable {
    public var allowedProviderIdentifiers: Set<String>?
    public var allowedKinds: Set<LanguageModelRouteKind>?

    public init(
        allowedProviderIdentifiers: Set<String>? = nil,
        allowedKinds: Set<LanguageModelRouteKind>? = nil
    ) {
        self.allowedProviderIdentifiers = allowedProviderIdentifiers
        self.allowedKinds = allowedKinds
    }

    public func allows(
        provider: String,
        kind: LanguageModelRouteKind
    ) -> Bool {
        let providerAllowed = allowedProviderIdentifiers?.contains(provider) ?? true
        let kindAllowed = allowedKinds?.contains(kind) ?? true
        return providerAllowed && kindAllowed
    }

    public static let automatic = LanguageModelRoutingPolicy()
    public static let remoteOnly = LanguageModelRoutingPolicy(
        allowedKinds: [.remote]
    )
    public static let onDeviceOnly = LanguageModelRoutingPolicy(
        allowedKinds: [.onDevice]
    )
    public static let staticFallbackOnly = LanguageModelRoutingPolicy(
        allowedKinds: [.staticFallback]
    )
    public static let remoteThenOnDevice = LanguageModelRoutingPolicy(
        allowedKinds: [.remote, .onDevice]
    )
    public static let remoteThenOnDeviceAndStatic = LanguageModelRoutingPolicy(
        allowedKinds: [.remote, .onDevice, .staticFallback]
    )
}

/// The action taken after one language-model provider fails.
public enum LanguageModelFallbackDecision: Sendable, Equatable, Codable {
    case tryNext
    case stop
}

/// The outcome of one provider considered by a model router.
public enum LanguageModelRoutingAttemptOutcome: Sendable, Equatable, Codable {
    case skipped
    case failed(WorkflowFailure)
    case selected
}

/// Why a provider was skipped without making a model request.
public enum LanguageModelRoutingSkipReason: Sendable, Equatable, Codable {
    case routingPolicy
    case missingCapabilities(Set<LanguageModelCapability>)
    case ineligible
}

/// One provider considered during a routed generation request.
public struct LanguageModelRoutingAttempt: Sendable, Equatable, Codable {
    public let provider: String
    public let kind: LanguageModelRouteKind
    public let outcome: LanguageModelRoutingAttemptOutcome
    public let skipReason: LanguageModelRoutingSkipReason?

    public init(
        provider: String,
        kind: LanguageModelRouteKind = .remote,
        outcome: LanguageModelRoutingAttemptOutcome,
        skipReason: LanguageModelRoutingSkipReason? = nil
    ) {
        self.provider = provider
        self.kind = kind
        self.outcome = outcome
        self.skipReason = skipReason
    }
}

/// The ordered provider decisions made for one generation request.
public struct LanguageModelRoutingReport: Sendable, Equatable, Codable {
    public let selectedProvider: String?
    public let selectedKind: LanguageModelRouteKind?
    public let attempts: [LanguageModelRoutingAttempt]
    public let requiredCapabilities: Set<LanguageModelCapability>

    public init(
        selectedProvider: String?,
        selectedKind: LanguageModelRouteKind? = nil,
        attempts: [LanguageModelRoutingAttempt],
        requiredCapabilities: Set<LanguageModelCapability> = []
    ) {
        self.selectedProvider = selectedProvider
        self.selectedKind = selectedKind
        self.attempts = attempts
        self.requiredCapabilities = requiredCapabilities
    }

    public var attemptedProviders: [String] {
        attempts.compactMap { attempt in
            switch attempt.outcome {
            case .skipped:
                return nil
            case .failed, .selected:
                return attempt.provider
            }
        }
    }
}

/// Live routing diagnostics emitted while providers are considered.
public enum LanguageModelRoutingEvent: Sendable, Equatable {
    case skipped(provider: String)
    case skippedForCapabilities(
        provider: String,
        missing: Set<LanguageModelCapability>
    )
    case started(provider: String)
    case failed(
        provider: String,
        failure: WorkflowFailure,
        decision: LanguageModelFallbackDecision
    )
    case selected(provider: String)
}

public typealias LanguageModelRoutingEventHandler =
    @Sendable (
        LanguageModelRoutingEvent
    ) async -> Void

/// One ordered provider candidate in a ``LanguageModelRouter``.
public struct LanguageModelRoute: Sendable {
    public let provider: String
    public let kind: LanguageModelRouteKind
    public let capabilities: LanguageModelCapabilities

    let model: any WorkflowLanguageModel
    private let eligibility: @Sendable (LanguageModelRequest) async -> Bool
    private let failureDecision:
        @Sendable (
            WorkflowFailure
        ) -> LanguageModelFallbackDecision

    public init<Model: WorkflowLanguageModel>(
        provider: String,
        kind: LanguageModelRouteKind = .remote,
        capabilities: LanguageModelCapabilities = .unspecified,
        model: Model,
        isEligible:
            @escaping @Sendable (
                LanguageModelRequest
            ) async -> Bool = { _ in true },
        onFailure:
            @escaping @Sendable (
                WorkflowFailure
            ) -> LanguageModelFallbackDecision = { _ in .tryNext }
    ) {
        self.provider = provider
        self.kind = kind
        self.capabilities = capabilities
        self.model = model
        eligibility = isEligible
        failureDecision = onFailure
    }

    func isEligible(for request: LanguageModelRequest) async -> Bool {
        await eligibility(request)
    }

    func missingCapabilities(
        for requirements: Set<LanguageModelCapability>
    ) -> Set<LanguageModelCapability> {
        capabilities.missing(from: requirements)
    }

    func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        try await model.generate(request)
    }

    var streamingModel: (any StreamingWorkflowLanguageModel)? {
        model as? any StreamingWorkflowLanguageModel
    }

    func decision(after failure: WorkflowFailure) -> LanguageModelFallbackDecision {
        failureDecision(failure)
    }
}

/// Invalid router definitions rejected during construction.
public enum LanguageModelRouterConfigurationError: Error, Sendable, Equatable {
    case noRoutes
    case emptyProviderIdentifier
    case duplicateProviderIdentifier(String)
}

/// Why no provider produced a response.
public enum LanguageModelRoutingFailureReason: Sendable, Equatable, Codable {
    case noEligibleProviders
    case noCompatibleProviders(Set<LanguageModelCapability>)
    case exhaustedProviders
    case stopped(provider: String)
}

/// A structured report produced when routing cannot select a provider.
public struct LanguageModelRoutingError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    public let reason: LanguageModelRoutingFailureReason
    public let report: LanguageModelRoutingReport

    public init(
        reason: LanguageModelRoutingFailureReason,
        report: LanguageModelRoutingReport
    ) {
        self.reason = reason
        self.report = report
    }

    public var description: String {
        switch reason {
        case .noEligibleProviders:
            return "No language-model provider was eligible for the request."
        case let .noCompatibleProviders(requirements):
            let names = requirements.map(\.rawValue).sorted().joined(
                separator: ", "
            )
            return "No language-model provider supports all required capabilities: \(names)."
        case .exhaustedProviders:
            return "Every eligible language-model provider failed."
        case let .stopped(provider):
            return "Language-model routing stopped after provider '\(provider)' failed."
        }
    }
}

/// Tries eligible language-model providers in declaration order.
public struct LanguageModelRouter: WorkflowLanguageModel {
    public let routes: [LanguageModelRoute]

    let onEvent: LanguageModelRoutingEventHandler?

    public init(
        routes: [LanguageModelRoute],
        onEvent: LanguageModelRoutingEventHandler? = nil
    ) throws {
        guard !routes.isEmpty else {
            throw LanguageModelRouterConfigurationError.noRoutes
        }

        var providers: Set<String> = []
        for route in routes {
            guard !route.provider.isEmpty else {
                throw LanguageModelRouterConfigurationError.emptyProviderIdentifier
            }
            guard providers.insert(route.provider).inserted else {
                throw
                    LanguageModelRouterConfigurationError
                    .duplicateProviderIdentifier(route.provider)
            }
        }

        self.routes = routes
        self.onEvent = onEvent
    }

    public func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        var attempts: [LanguageModelRoutingAttempt] = []
        var foundEligibleProvider = false
        var foundCompatibleProvider = false
        var foundCapabilityMismatch = false
        let requiredCapabilities = request.effectiveRequiredCapabilities

        for route in routes {
            guard
                request.routingPolicy.allows(
                    provider: route.provider,
                    kind: route.kind
                )
            else {
                attempts.append(
                    LanguageModelRoutingAttempt(
                        provider: route.provider,
                        kind: route.kind,
                        outcome: .skipped,
                        skipReason: .routingPolicy
                    )
                )
                await onEvent?(.skipped(provider: route.provider))
                continue
            }

            let missing = route.missingCapabilities(
                for: requiredCapabilities
            )
            guard missing.isEmpty else {
                foundCapabilityMismatch = true
                attempts.append(
                    LanguageModelRoutingAttempt(
                        provider: route.provider,
                        kind: route.kind,
                        outcome: .skipped,
                        skipReason: .missingCapabilities(missing)
                    )
                )
                await onEvent?(
                    .skippedForCapabilities(
                        provider: route.provider,
                        missing: missing
                    )
                )
                continue
            }
            foundCompatibleProvider = true

            guard await route.isEligible(for: request) else {
                attempts.append(
                    LanguageModelRoutingAttempt(
                        provider: route.provider,
                        kind: route.kind,
                        outcome: .skipped,
                        skipReason: .ineligible
                    )
                )
                await onEvent?(.skipped(provider: route.provider))
                continue
            }

            foundEligibleProvider = true
            await onEvent?(.started(provider: route.provider))

            do {
                try Task.checkCancellation()
                var response = try await route.generate(request)
                try Task.checkCancellation()

                attempts.append(
                    LanguageModelRoutingAttempt(
                        provider: route.provider,
                        kind: route.kind,
                        outcome: .selected
                    )
                )
                await onEvent?(.selected(provider: route.provider))

                if let upstreamProvider = response.provider,
                    upstreamProvider != route.provider
                {
                    response.metadata["routing.upstream-provider"] = upstreamProvider
                }
                response.provider = route.provider
                response.metadata["routing.selected-kind"] = route.kind.rawValue
                response.routingReport = LanguageModelRoutingReport(
                    selectedProvider: route.provider,
                    selectedKind: route.kind,
                    attempts: attempts,
                    requiredCapabilities: requiredCapabilities
                )
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = WorkflowFailure(error: error)
                let decision = route.decision(after: failure)
                attempts.append(
                    LanguageModelRoutingAttempt(
                        provider: route.provider,
                        kind: route.kind,
                        outcome: .failed(failure)
                    )
                )
                await onEvent?(
                    .failed(
                        provider: route.provider,
                        failure: failure,
                        decision: decision
                    )
                )

                if decision == .stop {
                    throw LanguageModelRoutingError(
                        reason: .stopped(provider: route.provider),
                        report: LanguageModelRoutingReport(
                            selectedProvider: nil,
                            selectedKind: nil,
                            attempts: attempts,
                            requiredCapabilities: requiredCapabilities
                        )
                    )
                }
            }
        }

        throw LanguageModelRoutingError(
            reason: foundEligibleProvider
                ? .exhaustedProviders
                : (!foundCompatibleProvider && foundCapabilityMismatch
                    ? .noCompatibleProviders(requiredCapabilities)
                    : .noEligibleProviders),
            report: LanguageModelRoutingReport(
                selectedProvider: nil,
                selectedKind: nil,
                attempts: attempts,
                requiredCapabilities: requiredCapabilities
            )
        )
    }
}
