import Foundation

/// How a ``ToolCallingLanguageModel`` asks for tool approvals.
public struct LanguageModelToolApprovalMode: Sendable, Equatable {
    /// Whether approvals suspend the workflow instead of waiting in memory.
    public var isDurable: Bool
    /// Whether, in durable mode, the workflow saves a checkpoint after every
    /// tool round that ran a tool that may have side effects. Without it, a
    /// crash before the turn finishes runs that round again on resume.
    public var checkpointsAfterToolRounds: Bool

    public init(isDurable: Bool, checkpointsAfterToolRounds: Bool = true) {
        self.isDurable = isDurable
        self.checkpointsAfterToolRounds = checkpointsAfterToolRounds
    }

    /// Asks the approval handler and waits for its answer. The default.
    public static let immediate = LanguageModelToolApprovalMode(isDurable: false)

    /// Saves the turn and suspends the workflow until the application
    /// answers, so approvals survive the app being closed.
    ///
    /// Durable approvals work inside a `LanguageModelNode` or
    /// `StructuredLanguageModelNode` that keeps a conversation. Anywhere else
    /// the model falls back to its approval handler, and without one a call
    /// that needs approval is denied.
    public static let durable = LanguageModelToolApprovalMode(isDurable: true)

    /// Durable approvals with checkpoints after tool rounds turned on or off.
    public static func durable(checkpointsAfterToolRounds: Bool) -> Self {
        LanguageModelToolApprovalMode(
            isDurable: true,
            checkpointsAfterToolRounds: checkpointsAfterToolRounds
        )
    }
}

/// A conversation turn interrupted by a durable tool approval or a tool-round
/// checkpoint. It is stored in ``LanguageModelConversation/pendingTurn`` and
/// continued when the node runs again.
///
/// While ``isAwaitingApproval`` is true, record a decision for each call in
/// ``approvalRequests`` before resuming, for example in the resume call's
/// update closure. Calls without a decision are denied. Like approval
/// requests, the stored tool calls contain raw arguments: treat them as
/// sensitive and untrusted.
public struct LanguageModelPendingToolTurn: Sendable, Equatable, Codable {
    /// The prompt of the interrupted turn. Resuming with a different prompt
    /// fails with ``ToolCallingLanguageModelError/pendingTurnMismatch``.
    public let prompt: String
    /// Assistant tool calls and tool results recorded so far in this turn.
    public package(set) var exchange: [LanguageModelMessage]
    /// The tool calls of the round that has not run yet. None of them run
    /// until every call that needs approval has a decision.
    public package(set) var pendingCalls: [LanguageModelToolCall]
    /// Identifiers of the pending calls that need approval.
    public package(set) var callIDsRequiringApproval: [String]
    public package(set) var decisions: [String: LanguageModelToolApprovalDecision]
    /// The identifier of the workflow input request for this approval, while
    /// the turn waits for one.
    public package(set) var approvalRequestID: UUID?

    package var provider: String?
    package var modelCalls: Int
    package var toolRounds: Int
    package var executionCount: Int
    package var executions: [LanguageModelToolExecutionRecord]
    package var deniedToolNames: [String]

    package init(
        prompt: String,
        exchange: [LanguageModelMessage],
        pendingCalls: [LanguageModelToolCall],
        callIDsRequiringApproval: [String],
        approvalRequestID: UUID?,
        provider: String?,
        modelCalls: Int,
        toolRounds: Int,
        executionCount: Int,
        executions: [LanguageModelToolExecutionRecord],
        deniedToolNames: [String]
    ) {
        self.prompt = prompt
        self.exchange = exchange
        self.pendingCalls = pendingCalls
        self.callIDsRequiringApproval = callIDsRequiringApproval
        decisions = [:]
        self.approvalRequestID = approvalRequestID
        self.provider = provider
        self.modelCalls = modelCalls
        self.toolRounds = toolRounds
        self.executionCount = executionCount
        self.executions = executions
        self.deniedToolNames = deniedToolNames
    }

    /// Whether the turn is waiting for the application to decide on tool
    /// calls.
    public var isAwaitingApproval: Bool { approvalRequestID != nil }

    /// The calls waiting for a decision, in the order the model made them.
    public var approvalRequests: [LanguageModelToolApprovalRequest] {
        let ids = Set(callIDsRequiringApproval)
        return pendingCalls.filter { ids.contains($0.id) }.map {
            LanguageModelToolApprovalRequest(call: $0, provider: provider)
        }
    }

    public func decision(for callID: String) -> LanguageModelToolApprovalDecision? {
        decisions[callID]
    }

    /// Records a decision. Identifiers of calls that do not need approval
    /// are ignored.
    public mutating func setDecision(
        _ decision: LanguageModelToolApprovalDecision,
        for callID: String
    ) {
        guard callIDsRequiringApproval.contains(callID) else { return }
        decisions[callID] = decision
    }

    public mutating func approve(_ callID: String) {
        setDecision(.approved, for: callID)
    }

    public mutating func deny(_ callID: String) {
        setDecision(.denied, for: callID)
    }

    public mutating func approveAll() {
        for id in callIDsRequiringApproval { decisions[id] = .approved }
    }

    public mutating func denyAll() {
        for id in callIDsRequiringApproval { decisions[id] = .denied }
    }

    /// The workflow input request a conversation node suspends with.
    package var inputRequest: WorkflowInputRequest? {
        guard let approvalRequestID else { return nil }
        let requests = approvalRequests
        return WorkflowInputRequest(
            id: approvalRequestID,
            kind: .toolApproval,
            metadata: [
                "toolCalls": String(requests.count),
                "tools": requests.map(\.call.name).joined(separator: ","),
            ]
        )
    }

    /// Applies a generic answer: `true` or `false` decides every call, and an
    /// object maps call identifiers to `true`, `false`, `"approved"`, or
    /// `"denied"`. Other values are ignored, so decisions written into state
    /// still apply.
    package mutating func applyAnswer(_ value: JSONValue?) {
        switch value {
        case let .bool(approved):
            approved ? approveAll() : denyAll()
        case let .object(entries):
            for (id, entry) in entries {
                switch entry {
                case .bool(true), .string("approved"): approve(id)
                case .bool(false), .string("denied"): deny(id)
                default: break
                }
            }
        default:
            break
        }
    }
}

extension WorkflowInputKind {
    /// A request to approve or deny tool calls. The pending calls are in the
    /// conversation's ``LanguageModelConversation/pendingTurn``.
    public static let toolApproval: Self = "toolApproval"
}

/// Thrown by a ``ToolCallingLanguageModel`` in durable approval mode to hand
/// an interrupted turn to the conversation node that runs it.
///
/// Conversation nodes handle it. Custom model wrappers should rethrow it
/// unchanged instead of retrying or falling back to another model.
public struct LanguageModelToolTurnSuspended: Error, Sendable, Equatable {
    public let pendingTurn: LanguageModelPendingToolTurn

    public init(pendingTurn: LanguageModelPendingToolTurn) {
        self.pendingTurn = pendingTurn
    }
}

/// Set by conversation nodes while a turn runs, so a durable
/// ``ToolCallingLanguageModel`` knows it may suspend and can pick up an
/// interrupted turn.
final class LanguageModelToolTurnScope: @unchecked Sendable {
    @TaskLocal static var current: LanguageModelToolTurnScope?

    private let lock = NSLock()
    private var resumption: LanguageModelPendingToolTurn?

    init(resuming resumption: LanguageModelPendingToolTurn?) {
        self.resumption = resumption
    }

    /// Returns the interrupted turn once, to the first tool loop that asks.
    func claimResumption() -> LanguageModelPendingToolTurn? {
        lock.withLock {
            defer { resumption = nil }
            return resumption
        }
    }
}
