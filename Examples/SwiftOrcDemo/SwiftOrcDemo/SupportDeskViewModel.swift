import Foundation
import Observation
import SwiftOrc
import SwiftOrcFoundationModels

@MainActor
@Observable
final class SupportDeskViewModel {
    enum Stage: Equatable {
        case inbox
        case ticket
        case result

        var navigationTitle: String {
            switch self {
            case .inbox: "Support Desk"
            case .ticket: "Ticket details"
            case .result: "Agent review"
            }
        }
    }

    enum RunStatus: Equatable {
        case idle
        case running
        case succeeded
        case recovered
        case blocked(String)
        case cancelled
        case failed(String)
    }

    var stage = Stage.inbox
    var selectedTicketID = SupportDeskCatalog.tickets[0].id
    var draftReply = ""
    private(set) var decision: SupportDeskDecision?
    private(set) var disposition: SupportDisposition?
    private(set) var reviewReason = ""
    private(set) var status = RunStatus.idle
    private(set) var phase = "Ready"
    private(set) var progress = 0.0
    private(set) var trace: [TraceItem] = []
    private(set) var modelAvailability = "Checking Apple Intelligence…"
    private(set) var isMarkedReviewed = false

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    private let model = AppleFoundationModel()

    init() {
        refreshAvailability()
    }

    var tickets: [SupportTicket] {
        SupportDeskCatalog.tickets
    }

    var selectedTicket: SupportTicket {
        SupportDeskCatalog.ticketByID[selectedTicketID]
            ?? SupportDeskCatalog.tickets[0]
    }

    var selectedArticles: [SupportKnowledgeArticle] {
        guard let decision else { return [] }
        return decision.knowledgeArticleIDs.compactMap {
            SupportDeskCatalog.articleByID[$0]
        }
    }

    var modelIsAvailable: Bool {
        model.availability == .available
    }

    var isRunning: Bool {
        status == .running
    }

    var usedFallback: Bool {
        status == .recovered
    }

    func open(_ ticket: SupportTicket) {
        guard !isRunning else { return }
        selectedTicketID = ticket.id
        resetResult()
        stage = .ticket
    }

    func showInbox() {
        guard !isRunning else { return }
        resetResult()
        stage = .inbox
    }

    func showTicket() {
        guard !isRunning else { return }
        stage = .ticket
    }

    func prepareResponse() {
        guard !isRunning else { return }

        resetResult()
        status = .running
        phase = "Reading the ticket"
        progress = 0.04

        let initialState = SupportDeskState(ticketID: selectedTicketID)
        runTask = Task { [weak self, model] in
            guard let self else { return }
            do {
                let workflow = try SupportDeskWorkflowFactory.make(model: model)
                let result = try await workflow.run(
                    initialState,
                    onEvent: { [weak self] event in
                        await self?.record(event)
                    }
                )

                guard
                    let finishedDecision = result.state.decision,
                    let finishedDisposition = result.state.disposition,
                    finishedDisposition != .blocked
                else {
                    phase = "No reply prepared"
                    status = .blocked(
                        result.state.blockedMessage
                            ?? "The response did not pass every application check."
                    )
                    runTask = nil
                    refreshAvailability()
                    return
                }

                decision = finishedDecision
                disposition = finishedDisposition
                reviewReason =
                    result.state.reviewReason
                    ?? "An agent should review the proposed response."
                draftReply = finishedDecision.draftReply
                progress = 1
                phase =
                    finishedDisposition == .humanReview
                    ? "Human decision required"
                    : "Draft ready for review"
                status =
                    result.state.usedStaticFallback
                    ? .recovered
                    : .succeeded
                stage = .result
            } catch is CancellationError {
                phase = "Triage cancelled"
                status = .cancelled
            } catch let error as WorkflowExecutionError {
                phase = "Triage stopped"
                status = .failed(error.failure.message)
            } catch {
                phase = "Triage stopped"
                status = .failed("The ticket could not be processed.")
            }
            runTask = nil
            refreshAvailability()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func markReviewed() {
        guard decision != nil, !isRunning else { return }
        isMarkedReviewed = true
    }

    func resetExample() {
        guard !isRunning else { return }
        selectedTicketID = SupportDeskCatalog.tickets[0].id
        resetResult()
        stage = .inbox
    }

    private func resetResult() {
        decision = nil
        disposition = nil
        reviewReason = ""
        draftReply = ""
        trace = []
        status = .idle
        phase = "Ready"
        progress = 0
        isMarkedReviewed = false
    }

    private func refreshAvailability() {
        switch model.availability {
        case .available:
            modelAvailability = "Apple’s on-device model is ready"
        case let .unavailable(reason):
            modelAvailability =
                "On-device model unavailable; the local demo fallback will run"
                + reason.supportDeskSuffix
        }
    }

    private func record(_ event: WorkflowEvent) {
        trace.append(TraceItem(event: event))

        switch event {
        case let .nodeStarted(node, _, _):
            updateProgress(for: node.rawValue)
        case let .branchSelected(node, route, _):
            guard node.rawValue == "route-decision" else { break }
            switch route {
            case "revise":
                phase = "Repairing a draft that missed a policy"
                progress = max(progress, 0.48)
            case "safe-fallback":
                phase = "Switching to the bundled safe reply"
                progress = max(progress, 0.48)
            case "human-review":
                phase = "Routing a sensitive action to an agent"
                progress = max(progress, 0.88)
            case "reply-ready":
                phase = "Preparing the grounded reply"
                progress = max(progress, 0.88)
            default:
                break
            }
        case .fallbackSelected:
            phase = "Using the bundled local example"
            progress = max(progress, 0.42)
        case .finished:
            progress = 1
        default:
            break
        }
    }

    private func updateProgress(for node: String) {
        switch node {
        case "validate-ticket":
            phase = "Validating local ticket context"
            progress = max(progress, 0.08)
        case "generate-decision":
            phase = "Drafting the customer reply"
            progress = max(progress, 0.25)
        case "demo-fallback":
            phase = "Loading the bundled local example"
            progress = max(progress, 0.42)
        case "check-decision":
            phase = "Checking grounding, policy, priority, and reply quality"
            progress = max(progress, 0.68)
        case "route-decision":
            phase = "Choosing the safe handling path"
            progress = max(progress, 0.82)
        case "reply-ready", "human-review":
            phase = "Finishing the agent review"
            progress = max(progress, 0.94)
        case "triage-blocked":
            phase = "Stopping without a reply"
            progress = max(progress, 0.94)
        default:
            break
        }
    }
}

private extension AppleFoundationModelAvailability.Reason {
    var supportDeskSuffix: String {
        switch self {
        case .deviceNotEligible: " (device not eligible)"
        case .appleIntelligenceNotEnabled: " (Apple Intelligence is disabled)"
        case .modelNotReady: " (model not ready)"
        case .unknown: ""
        }
    }
}
