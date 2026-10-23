import Foundation

public enum LanguageModelToolPolicyError: Error, Sendable, Equatable {
    case accessDenied(tool: String)
    case approvalHandlerMissing(tool: String)
    case approvalDenied(tool: String)
    case timedOut(tool: String)

    public var isAuthorizationDenial: Bool {
        switch self {
        case .accessDenied, .approvalHandlerMissing, .approvalDenied:
            return true
        case .timedOut:
            return false
        }
    }
}

public enum LanguageModelToolInvocationError: Error, Sendable, Equatable {
    case invalidArguments(tool: String, failure: WorkflowFailure)
    case outputEncodingFailed(tool: String, failure: WorkflowFailure)
}

/// Invalid tool registries rejected before model execution.
public enum LanguageModelToolRegistryError: Error, Sendable, Equatable {
    case noTools
    case emptyToolName
    case duplicateToolName(String)
    case invalidMaximumAttempts(tool: String)
    case invalidRetryDelay(tool: String)
    case invalidTimeout(tool: String)
}

/// A validated collection of named executable tools.
package struct LanguageModelToolRegistry: Sendable {
    package let definitions: [LanguageModelToolDefinition]

    private let registrations: [String: LanguageModelToolRegistration]

    package init(_ tools: [any LanguageModelTool]) throws {
        try self.init(
            registrations: tools.map {
                LanguageModelToolRegistration(tool: $0)
            }
        )
    }

    package init(
        registrations: [LanguageModelToolRegistration]
    ) throws {
        guard !registrations.isEmpty else {
            throw LanguageModelToolRegistryError.noTools
        }

        var indexed: [String: LanguageModelToolRegistration] = [:]
        var definitions: [LanguageModelToolDefinition] = []
        for registration in registrations {
            let name = registration.definition.name
            guard !name.isEmpty else {
                throw LanguageModelToolRegistryError.emptyToolName
            }
            guard indexed[name] == nil else {
                throw LanguageModelToolRegistryError.duplicateToolName(name)
            }
            guard registration.policy.retry.maximumAttempts >= 1 else {
                throw
                    LanguageModelToolRegistryError
                    .invalidMaximumAttempts(tool: name)
            }
            guard registration.policy.retry.delay >= .zero else {
                throw
                    LanguageModelToolRegistryError
                    .invalidRetryDelay(tool: name)
            }
            if let timeout = registration.policy.timeout,
                timeout <= .zero
            {
                throw LanguageModelToolRegistryError.invalidTimeout(tool: name)
            }
            indexed[name] = registration
            definitions.append(registration.definition)
        }

        self.registrations = indexed
        self.definitions = definitions
    }

    package func contains(_ name: String) -> Bool {
        registrations[name] != nil
    }

    package func metadata(
        for name: String
    ) -> LanguageModelToolMetadata? {
        registrations[name]?.metadata
    }

    package func call(_ call: LanguageModelToolCall) async throws -> String {
        guard let registration = registrations[call.name] else {
            throw ToolCallingLanguageModelError.unknownTool
        }
        return try await registration.tool.call(arguments: call.arguments)
    }

    func registration(
        named name: String
    ) -> LanguageModelToolRegistration? {
        registrations[name]
    }
}

package enum LanguageModelToolExecutorConfigurationError: Error, Sendable,
    Equatable
{
    case invalidMaximumConcurrentCalls
}

/// Executes registered tools while enforcing approvals, retries, timeouts, and
/// a shared concurrency limit.
package struct LanguageModelToolExecutor: Sendable {
    package let definitions: [LanguageModelToolDefinition]

    private let registry: LanguageModelToolRegistry
    private let permits: LanguageModelToolPermitPool
    private let approvalHandler: LanguageModelToolApprovalHandler?
    private let onEvent: LanguageModelToolEventHandler?
    private let maximumArgumentBytes: Int
    private let maximumOutputBytes: Int

    package init(
        registrations: [LanguageModelToolRegistration],
        maximumConcurrentCalls: Int = 1,
        maximumArgumentBytes: Int = 1 * 1_024 * 1_024,
        maximumOutputBytes: Int = 1 * 1_024 * 1_024,
        approvalHandler: LanguageModelToolApprovalHandler? = nil,
        onEvent: LanguageModelToolEventHandler? = nil
    ) throws {
        guard maximumConcurrentCalls >= 1,
            maximumArgumentBytes >= 1,
            maximumOutputBytes >= 1
        else {
            throw LanguageModelToolExecutorConfigurationError
                .invalidMaximumConcurrentCalls
        }
        let registry = try LanguageModelToolRegistry(
            registrations: registrations
        )
        self.registry = registry
        definitions = registry.definitions
        permits = LanguageModelToolPermitPool(
            maximumPermits: maximumConcurrentCalls
        )
        self.approvalHandler = approvalHandler
        self.onEvent = onEvent
        self.maximumArgumentBytes = maximumArgumentBytes
        self.maximumOutputBytes = maximumOutputBytes
    }

    package init(
        tools: [any LanguageModelTool],
        maximumConcurrentCalls: Int = 1,
        maximumArgumentBytes: Int = 1 * 1_024 * 1_024,
        maximumOutputBytes: Int = 1 * 1_024 * 1_024,
        approvalHandler: LanguageModelToolApprovalHandler? = nil,
        onEvent: LanguageModelToolEventHandler? = nil
    ) throws {
        try self.init(
            registrations: tools.map {
                LanguageModelToolRegistration(tool: $0)
            },
            maximumConcurrentCalls: maximumConcurrentCalls,
            maximumArgumentBytes: maximumArgumentBytes,
            maximumOutputBytes: maximumOutputBytes,
            approvalHandler: approvalHandler,
            onEvent: onEvent
        )
    }

    package func contains(_ name: String) -> Bool {
        registry.contains(name)
    }

    package func authorization(
        for name: String,
        under policy: LanguageModelToolAccessPolicy
    ) -> LanguageModelToolAuthorization? {
        guard let metadata = registry.metadata(for: name) else { return nil }
        return policy.authorization(for: name, metadata: metadata)
    }

    package func execute(
        _ call: LanguageModelToolCall,
        context: LanguageModelToolExecutionContext,
        authorization: LanguageModelToolAuthorization? = nil
    ) async throws -> String {
        guard let registration = registry.registration(named: call.name) else {
            throw ToolCallingLanguageModelError.unknownTool
        }
        guard call.arguments.utf8.count <= maximumArgumentBytes else {
            throw ToolCallingLanguageModelError.toolArgumentsTooLarge(
                maximum: maximumArgumentBytes
            )
        }

        if authorization == .denied {
            throw LanguageModelToolPolicyError.accessDenied(tool: call.name)
        }

        if registration.policy.approval == .always
            || authorization == .userApproval
        {
            await onEvent?(
                .approvalRequested(
                    round: context.round,
                    callNumber: context.callNumber,
                    tool: call.name
                )
            )
            guard let approvalHandler else {
                throw
                    LanguageModelToolPolicyError
                    .approvalHandlerMissing(tool: call.name)
            }
            let decision = await approvalHandler(
                LanguageModelToolApprovalRequest(
                    call: call,
                    provider: context.provider
                )
            )
            await onEvent?(
                .approvalResolved(
                    round: context.round,
                    callNumber: context.callNumber,
                    tool: call.name,
                    approved: decision == .approved
                )
            )
            guard decision == .approved else {
                throw
                    LanguageModelToolPolicyError
                    .approvalDenied(tool: call.name)
            }
        }

        if LanguageModelToolSideEffectTracker.mayHaveSideEffects(
            registration.metadata
        ) {
            LanguageModelToolSideEffectTracker.current?.recordSideEffect()
        }

        let output = try await executeAttempts(
            registration,
            call: call,
            context: context
        )
        guard output.utf8.count <= maximumOutputBytes else {
            throw ToolCallingLanguageModelError.toolOutputTooLarge(
                maximum: maximumOutputBytes
            )
        }
        return output
    }

    /// Runs attempts while holding one concurrency permit per attempt. Every
    /// exit path releases the permit, except that a timed-out or cancelled
    /// tool keeps it until its abandoned work actually finishes.
    private func executeAttempts(
        _ registration: LanguageModelToolRegistration,
        call: LanguageModelToolCall,
        context: LanguageModelToolExecutionContext
    ) async throws -> String {
        let retry = registration.policy.retry
        var attempt = 1

        while true {
            try await acquirePermit()
            guard !Task.isCancelled else {
                await permits.release()
                throw CancellationError()
            }

            let error: any Error
            switch await executeAttempt(registration, arguments: call.arguments) {
            case let .finished(.success(output)):
                await permits.release()
                return output
            case let .finished(.failure(failure)):
                await permits.release()
                error = failure
            case let .timedOut(work):
                releasePermit(afterAbandoning: work)
                error = LanguageModelToolPolicyError.timedOut(
                    tool: registration.definition.name
                )
            case let .cancelled(work):
                releasePermit(afterAbandoning: work)
                throw CancellationError()
            }

            if error is CancellationError { throw CancellationError() }
            try Task.checkCancellation()
            guard attempt < retry.maximumAttempts else { throw error }
            let failure = WorkflowFailure(error: error)
            if let shouldRetry = retry.shouldRetry {
                let retryAllowed = await shouldRetry(
                    LanguageModelToolRetryRequest(
                        tool: call.name,
                        attempt: attempt,
                        failure: failure
                    )
                )
                guard retryAllowed else { throw error }
            }
            try Task.checkCancellation()

            attempt += 1
            await onEvent?(
                .retryScheduled(
                    round: context.round,
                    callNumber: context.callNumber,
                    tool: call.name,
                    nextAttempt: attempt
                )
            )
            if retry.delay > .zero {
                try await Task.sleep(for: retry.delay)
            }
        }
    }

    private func acquirePermit() async throws {
        let permitID = UUID()
        try await withTaskCancellationHandler {
            try await permits.acquire(id: permitID)
        } onCancel: {
            Task { await permits.cancel(id: permitID) }
        }
    }

    private func releasePermit(
        afterAbandoning work: Task<String, any Error>
    ) {
        work.cancel()
        let permits = permits
        Task {
            _ = await work.result
            await permits.release()
        }
    }

    /// Runs one attempt. With a timeout, the tool runs in its own task so the
    /// deadline is honored even when the tool ignores cancellation.
    private func executeAttempt(
        _ registration: LanguageModelToolRegistration,
        arguments: String
    ) async -> LanguageModelToolAttemptOutcome {
        guard let timeout = registration.policy.timeout else {
            do {
                return .finished(
                    .success(try await registration.tool.call(arguments: arguments))
                )
            } catch {
                return .finished(.failure(error))
            }
        }

        let work = Task {
            try await registration.tool.call(arguments: arguments)
        }
        let race = LanguageModelToolAttemptRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                Task { race.resolve(.finished(await work.result)) }
                race.setTimer(
                    Task {
                        guard (try? await Task.sleep(for: timeout)) != nil else {
                            return
                        }
                        race.resolve(.timedOut(work))
                    }
                )
            }
        } onCancel: {
            race.resolve(.cancelled(work))
        }
    }
}

private enum LanguageModelToolAttemptOutcome: Sendable {
    case finished(Result<String, any Error>)
    case timedOut(Task<String, any Error>)
    case cancelled(Task<String, any Error>)
}

/// Delivers whichever of completion, timeout, or cancellation happens first.
private final class LanguageModelToolAttemptRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LanguageModelToolAttemptOutcome, Never>?
    private var outcome: LanguageModelToolAttemptOutcome?
    private var timer: Task<Void, Never>?

    func install(
        _ continuation: CheckedContinuation<LanguageModelToolAttemptOutcome, Never>
    ) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(returning: outcome)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        if outcome == nil {
            self.timer = timer
            lock.unlock()
        } else {
            lock.unlock()
            timer.cancel()
        }
    }

    func resolve(_ outcome: LanguageModelToolAttemptOutcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let continuation = self.continuation
        let timer = self.timer
        self.continuation = nil
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: outcome)
    }
}

private actor LanguageModelToolPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maximumPermits: Int
    private var availablePermits: Int
    private var waiters: [Waiter] = []

    init(maximumPermits: Int) {
        self.maximumPermits = maximumPermits
        availablePermits = maximumPermits
    }

    func acquire(id: UUID) async throws {
        try Task.checkCancellation()
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release() {
        if waiters.isEmpty {
            availablePermits = min(availablePermits + 1, maximumPermits)
        } else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        }
    }
}
