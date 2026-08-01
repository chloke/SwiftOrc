import Foundation
import Observation
import SwiftOrc
import SwiftOrcFoundationModels

@MainActor
@Observable
final class PantryRescueViewModel {
    enum Stage: Equatable {
        case pantry
        case preferences
        case result

        var navigationTitle: String {
            switch self {
            case .pantry, .preferences: "Pantry Rescue"
            case .result: "Tonight’s rescue"
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

    var stage = Stage.pantry
    var selectedIngredientIDs = PantryCatalog.defaultIngredientIDs
    var preference = "Something warm, fresh, and filling—not too spicy."
    var maximumCookTime = 25
    private(set) var recipe: PantryRecipe?
    private(set) var status = RunStatus.idle
    private(set) var phase = "Ready"
    private(set) var progress = 0.0
    private(set) var trace: [TraceItem] = []
    private(set) var modelAvailability = "Checking Apple Intelligence…"

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    private let model = AppleFoundationModel()
    let allergies: Set<String> = ["peanut"]
    let allowedEquipment = Set(PantryEquipment.allCases)

    init() {
        refreshAvailability()
    }

    var isRunning: Bool {
        status == .running
    }

    var selectedIngredients: [PantryIngredient] {
        PantryCatalog.ingredients.filter {
            selectedIngredientIDs.contains($0.id)
        }
    }

    var canContinue: Bool {
        selectedIngredientIDs.count >= 3 && !isRunning
    }

    var canPlan: Bool {
        canContinue
            && preference.trimmingCharacters(in: .whitespacesAndNewlines).count <= 240
    }

    var modelIsAvailable: Bool {
        model.availability == .available
    }

    var modelStatusColorName: String {
        modelIsAvailable ? "green" : "orange"
    }

    func toggle(_ ingredient: PantryIngredient) {
        guard !isRunning else { return }
        if selectedIngredientIDs.contains(ingredient.id) {
            selectedIngredientIDs.remove(ingredient.id)
        } else {
            selectedIngredientIDs.insert(ingredient.id)
        }
    }

    func showPreferences() {
        guard canContinue else { return }
        stage = .preferences
        status = .idle
    }

    func showPantry() {
        guard !isRunning else { return }
        stage = .pantry
        status = .idle
    }

    func cycleCookingTime() {
        guard !isRunning else { return }
        switch maximumCookTime {
        case 15: maximumCookTime = 25
        case 25: maximumCookTime = 40
        default: maximumCookTime = 15
        }
    }

    func planMeal() {
        guard canPlan else { return }

        recipe = nil
        trace = []
        status = .running
        phase = "Checking your pantry"
        progress = 0.05

        let initialState = PantryRescueState(
            selectedIngredientIDs: selectedIngredientIDs.sorted(),
            request: preference,
            maximumCookTime: maximumCookTime,
            allergies: allergies,
            allowedEquipment: allowedEquipment
        )

        runTask = Task { [weak self, model] in
            guard let self else { return }
            do {
                let workflow = try PantryRescueWorkflowFactory.make(model: model)
                let result = try await workflow.run(
                    initialState,
                    onEvent: { [weak self] event in
                        await self?.record(event)
                    }
                )

                if let finishedRecipe = result.state.recipe {
                    recipe = finishedRecipe
                    progress = 1
                    phase = "Meal ready"
                    status =
                        result.state.usedStaticFallback
                        ? .recovered
                        : .succeeded
                    stage = .result
                } else {
                    phase = "No meal prepared"
                    status = .blocked(
                        result.state.blockedMessage
                            ?? "No meal could satisfy every configured constraint."
                    )
                }
            } catch is CancellationError {
                phase = "Planning cancelled"
                status = .cancelled
            } catch let error as WorkflowExecutionError {
                phase = "Planning stopped"
                status = .failed(error.failure.message)
            } catch {
                phase = "Planning stopped"
                status = .failed("The meal plan could not be completed.")
            }
            runTask = nil
            refreshAvailability()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func tryAnotherIdea() {
        guard !isRunning else { return }
        recipe = nil
        status = .idle
        phase = "Ready"
        progress = 0
        stage = .preferences
    }

    func startOver() {
        guard !isRunning else { return }
        selectedIngredientIDs = PantryCatalog.defaultIngredientIDs
        preference = "Something warm, fresh, and filling—not too spicy."
        maximumCookTime = 25
        recipe = nil
        trace = []
        status = .idle
        phase = "Ready"
        progress = 0
        stage = .pantry
    }

    private func refreshAvailability() {
        switch model.availability {
        case .available:
            modelAvailability = "Apple’s on-device model is ready"
        case let .unavailable(reason):
            modelAvailability =
                "On-device model unavailable; the local demo fallback will run"
                + reason.shortSuffix
        }
    }

    private func record(_ event: WorkflowEvent) {
        trace.append(TraceItem(event: event))

        switch event {
        case let .nodeStarted(node, _, _):
            updateProgress(for: node.rawValue)
        case let .branchSelected(node, route, _):
            if node.rawValue == "review-recipe", route == "revise" {
                phase = "Repairing a proposal that missed a constraint"
                progress = max(progress, 0.42)
            }
        case .fallbackSelected:
            phase = "Using the bundled local demo recipe"
            progress = max(progress, 0.45)
        case .finished:
            progress = 1
        default:
            break
        }
    }

    private func updateProgress(for node: String) {
        switch node {
        case "validate-input":
            phase = "Checking your pantry selection"
            progress = max(progress, 0.08)
        case "generate-recipe":
            phase = "Creating a meal from what you have"
            progress = max(progress, 0.25)
        case "demo-fallback":
            phase = "Preparing the bundled local example"
            progress = max(progress, 0.45)
        case "check-recipe":
            phase = "Checking pantry, allergy, time, and equipment rules"
            progress = max(progress, 0.68)
        case "review-recipe":
            phase = "Reviewing the check results"
            progress = max(progress, 0.82)
        case "finalize":
            phase = "Finishing tonight’s plan"
            progress = max(progress, 0.94)
        case "meal-unavailable":
            phase = "Stopping safely"
            progress = max(progress, 0.94)
        default:
            break
        }
    }
}

private extension AppleFoundationModelAvailability.Reason {
    var shortSuffix: String {
        switch self {
        case .deviceNotEligible: " (device not eligible)"
        case .appleIntelligenceNotEnabled: " (Apple Intelligence is disabled)"
        case .modelNotReady: " (model not ready)"
        case .unknown: ""
        }
    }
}
