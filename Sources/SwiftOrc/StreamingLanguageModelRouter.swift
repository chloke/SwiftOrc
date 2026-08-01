public extension LanguageModelRouter {
    /// Streams from the first eligible streaming route. A provider may fall
    /// back only before it emits text, preventing mixed output from two models.
    func stream(
        _ request: LanguageModelRequest
    ) -> AsyncThrowingStream<LanguageModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await routeStream(request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension LanguageModelRouter: StreamingWorkflowLanguageModel {}

private extension LanguageModelRouter {
    func routeStream(
        _ request: LanguageModelRequest,
        continuation: AsyncThrowingStream<
            LanguageModelStreamEvent,
            any Error
        >.Continuation
    ) async throws {
        var attempts: [LanguageModelRoutingAttempt] = []
        var foundEligibleProvider = false
        var foundCompatibleProvider = false
        var foundCapabilityMismatch = false
        var requiredCapabilities = request.effectiveRequiredCapabilities
        requiredCapabilities.insert(.streaming)

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

            var missing = route.missingCapabilities(for: requiredCapabilities)
            guard let model = route.streamingModel else {
                missing.insert(.streaming)
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
            var emittedText = false

            do {
                var completedResponse: LanguageModelResponse?
                for try await event in model.stream(request) {
                    try Task.checkCancellation()
                    switch event {
                    case let .textDelta(delta):
                        if !delta.isEmpty {
                            emittedText = true
                            continuation.yield(.textDelta(delta))
                        }
                    case let .completed(response):
                        completedResponse = response
                    }
                }
                guard var response = completedResponse else {
                    throw LanguageModelStreamingError.missingCompletion
                }

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
                continuation.yield(.completed(response))
                continuation.finish()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = WorkflowFailure(error: error)
                let decision: LanguageModelFallbackDecision =
                    emittedText
                    ? .stop
                    : route.decision(after: failure)
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
                attempts: attempts,
                requiredCapabilities: requiredCapabilities
            )
        )
    }
}
