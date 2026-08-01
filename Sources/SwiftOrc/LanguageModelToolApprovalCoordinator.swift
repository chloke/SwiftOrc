import Foundation

/// One tool call waiting for an application-level approval decision.
///
/// The request contains raw model-generated arguments. Treat them as sensitive
/// and untrusted, and display only the information a user needs to decide.
public struct LanguageModelToolPendingApproval: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let request: LanguageModelToolApprovalRequest

    public init(
        id: UUID = UUID(),
        request: LanguageModelToolApprovalRequest
    ) {
        self.id = id
        self.request = request
    }

    public var tool: String {
        request.call.name
    }

    public var arguments: String {
        request.call.arguments
    }

    public var provider: String? {
        request.provider
    }
}

/// Coordinates asynchronous tool approvals between model execution and an
/// application UI.
///
/// Supply ``approvalHandler`` to a policy-aware model. Observe ``updates()``
/// from a UI task, then call ``approve(_:)`` or ``deny(_:)`` with the pending
/// approval's identifier. Requests are ordered first-in, first-out and multiple
/// observers each receive complete snapshots.
public actor LanguageModelToolApprovalCoordinator {
    private struct Entry {
        let approval: LanguageModelToolPendingApproval
        let continuation:
            CheckedContinuation<
                LanguageModelToolApprovalDecision,
                Never
            >
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var observers: [UUID: AsyncStream<[LanguageModelToolPendingApproval]>.Continuation] =
        [:]

    public init() {}

    /// A handler ready to pass to ``ToolCallingLanguageModel`` or a provider
    /// adapter.
    public nonisolated var approvalHandler: LanguageModelToolApprovalHandler {
        { request in
            await self.requestApproval(request)
        }
    }

    /// Returns the current queue and every subsequent queue snapshot.
    ///
    /// The newest snapshot is buffered, so a slow UI does not need to process
    /// obsolete intermediate states.
    public func updates() -> AsyncStream<[LanguageModelToolPendingApproval]> {
        let observerID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [LanguageModelToolPendingApproval].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[observerID] = continuation
        continuation.yield(pendingApprovals)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task {
                await self.removeObserver(observerID)
            }
        }
        return stream
    }

    /// The currently unresolved approvals in arrival order.
    public var pendingApprovals: [LanguageModelToolPendingApproval] {
        order.compactMap { entries[$0]?.approval }
    }

    /// Resolves a pending request. Returns `false` if it was already resolved.
    @discardableResult
    public func resolve(
        _ id: UUID,
        decision: LanguageModelToolApprovalDecision
    ) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else {
            return false
        }
        order.removeAll { $0 == id }
        publish()
        entry.continuation.resume(returning: decision)
        return true
    }

    @discardableResult
    public func approve(_ id: UUID) -> Bool {
        resolve(id, decision: .approved)
    }

    @discardableResult
    public func deny(_ id: UUID) -> Bool {
        resolve(id, decision: .denied)
    }

    /// Denies and resumes every pending request.
    public func denyAll() {
        let unresolved = order.compactMap { entries[$0] }
        entries.removeAll()
        order.removeAll()
        publish()
        for entry in unresolved {
            entry.continuation.resume(returning: .denied)
        }
    }

    private func requestApproval(
        _ request: LanguageModelToolApprovalRequest
    ) async -> LanguageModelToolApprovalDecision {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .denied)
                    return
                }

                let approval = LanguageModelToolPendingApproval(
                    id: id,
                    request: request
                )
                entries[id] = Entry(
                    approval: approval,
                    continuation: continuation
                )
                order.append(id)
                publish()
            }
        } onCancel: {
            Task {
                await self.deny(id)
            }
        }
    }

    private func publish() {
        let snapshot = pendingApprovals
        for observer in observers.values {
            observer.yield(snapshot)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
