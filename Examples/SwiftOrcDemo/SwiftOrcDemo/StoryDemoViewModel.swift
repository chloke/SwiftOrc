import Foundation
import Observation
import SwiftOrc
import SwiftOrcFoundationModels

@MainActor
@Observable
final class StoryDemoViewModel {
    enum RunStatus: Equatable {
        case idle
        case running
        case succeeded
        case blocked(String)
        case cancelled
        case failed(String)
    }

    var idea = "A shy moon moth finds a tiny brass key in a rooftop garden."
    private(set) var title = ""
    private(set) var story = ""
    private(set) var status = RunStatus.idle
    private(set) var phase = "Ready for an idea"
    private(set) var progress = 0.0
    private(set) var activeChapter: Int?
    private(set) var completedChapters = 0
    private(set) var trace: [TraceItem] = []
    private(set) var modelAvailability = "Checking Apple Intelligence…"

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    private let model = AppleFoundationModel()

    init() {
        refreshAvailability()
    }

    var isRunning: Bool {
        status == .running
    }

    var modelIsAvailable: Bool {
        model.availability == .available
    }

    var canGenerate: Bool {
        let count = idea.trimmingCharacters(in: .whitespacesAndNewlines).count
        return modelIsAvailable && !isRunning && (8...500).contains(count)
    }

    var characterCount: Int {
        idea.count
    }

    func useSample(_ sample: String) {
        guard !isRunning else { return }
        idea = sample
    }

    func generate() {
        let trimmedIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelIsAvailable, !isRunning, (8...500).contains(trimmedIdea.count) else {
            return
        }

        title = ""
        story = ""
        trace = []
        completedChapters = 0
        activeChapter = nil
        progress = 0.02
        phase = "Preparing the story"
        status = .running

        runTask = Task { [weak self, model] in
            guard let self else { return }
            do {
                let workflow = try StoryDemoWorkflowFactory.make(model: model)
                let result = try await workflow.run(
                    StoryDemoState(idea: trimmedIdea),
                    onEvent: { [weak self] event in
                        await self?.record(event)
                    }
                )

                if let generatedStory = result.state.story,
                    !generatedStory.isEmpty
                {
                    title = result.state.title ?? "Your story"
                    story = generatedStory
                    completedChapters = 5
                    activeChapter = nil
                    progress = 1
                    phase = "Story complete"
                    status = .succeeded
                } else {
                    let message =
                        result.state.blockedMessage
                        ?? "The story could not be completed safely."
                    activeChapter = nil
                    phase = "Story not created"
                    status = .blocked(message)
                }
            } catch is CancellationError {
                activeChapter = nil
                phase = "Generation cancelled"
                status = .cancelled
            } catch let error as WorkflowExecutionError {
                activeChapter = nil
                phase = "Workflow stopped"
                status = .failed(error.description)
            } catch {
                activeChapter = nil
                phase = "Workflow stopped"
                status = .failed(String(describing: error))
            }
            runTask = nil
            refreshAvailability()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func startOver() {
        guard !isRunning else { return }
        title = ""
        story = ""
        trace = []
        completedChapters = 0
        activeChapter = nil
        progress = 0
        phase = "Ready for an idea"
        status = .idle
    }

    private func refreshAvailability() {
        switch model.availability {
        case .available:
            modelAvailability = "Apple's on-device model is ready"
        case let .unavailable(reason):
            modelAvailability = "On-device model unavailable: \(reason.displayName)"
        }
    }

    private func record(_ event: WorkflowEvent) {
        trace.append(TraceItem(event: event))

        switch event {
        case let .nodeStarted(node, _, _):
            updateProgress(for: node.rawValue)
        case let .nodeCompleted(node, _):
            if let number = chapterNumber(in: node.rawValue, prefix: "accept-") {
                completedChapters = max(completedChapters, number)
                progress = max(progress, 0.12 + (Double(number) * 0.15))
            }
        case let .branchSelected(node, route, _):
            if node.rawValue.hasPrefix("safety-decision-"), route == "rewrite" {
                phase = "Rewriting this part more gently"
            } else if node.rawValue.hasPrefix("duplicate-check-"),
                route == "rewrite-duplicate"
            {
                phase = "Replacing a repeated story part"
            }
        case .fallbackSelected:
            phase = "Moving to the safe stop"
        default:
            break
        }
    }

    private func updateProgress(for node: String) {
        if node == "validate-idea" {
            phase = "Checking the idea"
            progress = max(progress, 0.03)
        } else if node == "plan-story" {
            phase = "Planning a five-part story arc"
            progress = max(progress, 0.07)
        } else if let number = chapterNumber(in: node, prefix: "generate-") {
            activeChapter = number
            phase = "Writing story part \(number) of 5"
            progress = max(progress, 0.12 + (Double(number - 1) * 0.15))
        } else if let number = chapterNumber(in: node, prefix: "safety-") {
            activeChapter = number
            phase = "Reviewing story part \(number) for children"
            progress = max(progress, 0.18 + (Double(number - 1) * 0.15))
        } else if let number = chapterNumber(in: node, prefix: "duplicate-check-") {
            activeChapter = number
            phase = "Checking story part \(number) for repetition"
        } else if node == "final-safety" {
            activeChapter = nil
            phase = "Reviewing the complete story"
            progress = max(progress, 0.91)
        } else if node == "assemble-story" {
            activeChapter = nil
            phase = "Assembling the final story"
            progress = max(progress, 0.97)
        }
    }

    private func chapterNumber(in node: String, prefix: String) -> Int? {
        guard node.hasPrefix(prefix) else { return nil }
        return Int(node.dropFirst(prefix.count))
    }
}

private extension AppleFoundationModelAvailability.Reason {
    var displayName: String {
        switch self {
        case .deviceNotEligible:
            "this device is not eligible"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is disabled"
        case .modelNotReady:
            "the model is not ready"
        case .unknown:
            "unknown reason"
        }
    }
}
