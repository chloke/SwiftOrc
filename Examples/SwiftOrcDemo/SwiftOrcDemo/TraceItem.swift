import Foundation
import SwiftOrc

struct TraceItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case information
        case success
        case warning
        case failure
    }

    let id = UUID()
    let title: String
    let detail: String
    let kind: Kind

    init(event: WorkflowEvent) {
        switch event {
        case let .started(_, initialNode):
            title = "Workflow started"
            detail = "Initial node: \(initialNode)"
            kind = .information

        case let .resumed(_, node, attempt, steps):
            title = "Workflow resumed"
            detail = "Continue at \(node), attempt \(attempt), after \(steps) step(s)"
            kind = .information

        case let .checkpointCreated(_, nextNode, attempt, steps):
            title = "Checkpoint saved"
            detail = "Next: \(nextNode), attempt \(attempt), after \(steps) step(s)"
            kind = .information

        case let .nodeStarted(node, attempt, step):
            title = "Running \(node)"
            detail = "Step \(step), attempt \(attempt)"
            kind = .information

        case let .nodeCompleted(node, transition):
            title = "Completed \(node)"
            detail = transition.description
            kind = .success

        case let .branchSelected(node, route, target):
            title = "Branch selected: \(route)"
            detail = "\(node) → \(target)"
            kind = .information

        case let .parallelBranchesCompleted(node, branches):
            title = "Parallel work completed"
            detail = "\(node): \(branches.joined(separator: ", "))"
            kind = .success

        case let .annotation(node, value):
            switch value {
            case let .languageModelRouting(report):
                title = "Model provider selected"
                let selected = report.selectedProvider ?? "none"
                let selectedKind = report.selectedKind?.rawValue ?? "unknown"
                let decisions = report.attempts.map(\.traceDescription)
                    .joined(separator: " → ")
                detail = "\(node): \(selected) [\(selectedKind)] (\(decisions))"
                kind = .information
            case let .languageModelTools(report):
                if report.executions.isEmpty {
                    title = "No model tools requested"
                    detail = "\(node): \(report.modelCalls) model call(s)"
                } else {
                    title = "Model tools completed"
                    let tools = report.executions.map(\.tool).joined(separator: ", ")
                    let rounds =
                        report.providerManaged
                        ? "provider managed"
                        : "\(report.toolRounds) round(s)"
                    detail = "\(node): \(rounds), \(tools)"
                }
                kind = .information
            }

        case let .retryScheduled(node, nextAttempt, reason):
            title = "Retrying \(node)"
            detail = reason?.message ?? "Next attempt: \(nextAttempt)"
            kind = .warning

        case let .fallbackSelected(node, target, failure):
            title = "Fallback selected"
            detail = "\(node) → \(target): \(failure.message)"
            kind = .warning

        case let .nodeFailed(node, failure):
            title = "Node failed: \(node)"
            detail = failure.message
            kind = .failure

        case let .workflowFailed(_, node, failure, steps):
            title = "Workflow failed at \(node)"
            detail = "After \(steps) step(s): \(failure.message)"
            kind = .failure

        case let .cancelled(node):
            title = "Workflow cancelled"
            detail = "Stopped at \(node)"
            kind = .warning

        case let .finished(_, finalNode, steps):
            title = "Workflow finished"
            detail = "Final node: \(finalNode), \(steps) step(s)"
            kind = .success
        }
    }
}

private extension LanguageModelRoutingAttempt {
    var traceDescription: String {
        switch outcome {
        case .selected:
            return "\(provider) selected"
        case .failed:
            return "\(provider) failed"
        case .skipped:
            return "\(provider) skipped: \(skipReason?.traceDescription ?? "unknown")"
        }
    }
}

private extension LanguageModelRoutingSkipReason {
    var traceDescription: String {
        switch self {
        case .routingPolicy:
            "routing policy"
        case let .missingCapabilities(capabilities):
            "missing \(capabilities.map(\.rawValue).sorted().joined(separator: ", "))"
        case .ineligible:
            "ineligible"
        }
    }
}

private extension WorkflowTransitionKind {
    var description: String {
        switch self {
        case let .next(target):
            return "Continue to \(target)"
        case .retry:
            return "Retry"
        case let .fallback(target):
            return "Use fallback \(target)"
        case .finish:
            return "Finish"
        }
    }
}
