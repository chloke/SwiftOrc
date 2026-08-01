import Foundation
import Observation
import SwiftOrc
import SwiftOrcFoundationModels

@MainActor
@Observable
final class DemoViewModel {
    enum RunStatus: Equatable {
        case idle
        case running
        case succeeded
        case recovered(String)
        case cancelled
        case failed(String)
    }

    var request = DemoViewModel.calculatorExampleRequest
    var answer = ""
    var trace: [TraceItem] = []
    var status: RunStatus = .idle
    private(set) var modelAvailability = "Checking model availability…"
    private(set) var hasSavedCheckpoint = false
    private(set) var pendingToolApprovals: [LanguageModelToolPendingApproval] = []

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    @ObservationIgnored
    private var approvalUpdatesTask: Task<Void, Never>?

    private let approvalCoordinator: LanguageModelToolApprovalCoordinator
    private let model: AppleFoundationModel
    private let toolConfigurationFailure: String?
    private let checkpointStore = JSONFileWorkflowCheckpointStore<DemoWorkflowState>(
        fileURL: DemoViewModel.checkpointURL
    )

    init() {
        let approvalCoordinator = LanguageModelToolApprovalCoordinator()
        self.approvalCoordinator = approvalCoordinator
        let modelConfiguration = Self.makeModel(
            approvalHandler: approvalCoordinator.approvalHandler
        )
        model = modelConfiguration.model
        toolConfigurationFailure = modelConfiguration.failure
        refreshAvailability()
        approvalUpdatesTask = Task { [weak self, approvalCoordinator] in
            let updates = await approvalCoordinator.updates()
            for await approvals in updates {
                guard !Task.isCancelled else { break }
                self?.pendingToolApprovals = approvals
            }
        }
        Task { [weak self] in
            await self?.refreshCheckpointAvailability()
        }
    }

    deinit {
        approvalUpdatesTask?.cancel()
    }

    var isRunning: Bool {
        status == .running
    }

    var pendingToolApproval: LanguageModelToolPendingApproval? {
        pendingToolApprovals.first
    }

    func run() {
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty, !isRunning else { return }

        answer = ""
        trace = []
        status = .running

        runTask = Task { [weak self] in
            await self?.executeNew(request: trimmedRequest)
        }
    }

    func loadCalculatorExample() {
        guard !isRunning else { return }
        request = Self.calculatorExampleRequest
    }

    func resumeSaved() {
        guard hasSavedCheckpoint, !isRunning else { return }

        answer = ""
        trace = []
        status = .running

        runTask = Task { [weak self] in
            await self?.executeSaved()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func approveToolCall(_ approval: LanguageModelToolPendingApproval) {
        resolveToolCall(approval, decision: .approved)
    }

    func denyToolCall(_ approval: LanguageModelToolPendingApproval) {
        resolveToolCall(approval, decision: .denied)
    }

    func refreshAvailability() {
        if let toolConfigurationFailure {
            modelAvailability = "Tool configuration failed: \(toolConfigurationFailure)"
            return
        }

        switch model.availability {
        case .available:
            modelAvailability = "On-device model available"
        case let .unavailable(reason):
            modelAvailability = "Model unavailable: \(reason.description)"
        }
    }

    private func executeNew(request: String) async {
        defer { runTask = nil }

        do {
            try await checkpointStore.remove()
            let workflow = try DemoWorkflowFactory.make(
                model: model,
                approvalHandler: approvalCoordinator.approvalHandler
            )
            let result = try await workflow.run(
                DemoWorkflowState(request: request),
                onEvent: { [weak self] event in
                    await self?.record(event)
                },
                onCheckpoint: { [checkpointStore] checkpoint in
                    try await checkpointStore.save(checkpoint)
                }
            )

            try await finish(result)
        } catch is CancellationError {
            status = .cancelled
        } catch let error as WorkflowExecutionError {
            status = .failed(error.description)
        } catch {
            status = .failed(String(describing: error))
        }

        refreshAvailability()
        await refreshCheckpointAvailability()
    }

    private func executeSaved() async {
        defer { runTask = nil }

        do {
            guard let checkpoint = try await checkpointStore.load() else {
                status = .failed("No saved checkpoint was found.")
                hasSavedCheckpoint = false
                return
            }

            request = checkpoint.state.request
            answer = checkpoint.state.answer ?? ""
            trace = checkpoint.events.map { TraceItem(event: $0) }

            let workflow = try DemoWorkflowFactory.make(
                model: model,
                approvalHandler: approvalCoordinator.approvalHandler
            )
            let result = try await workflow.resume(
                from: checkpoint,
                onEvent: { [weak self] event in
                    await self?.record(event)
                },
                onCheckpoint: { [checkpointStore] checkpoint in
                    try await checkpointStore.save(checkpoint)
                }
            )

            try await finish(result)
        } catch is CancellationError {
            status = .cancelled
        } catch let error as WorkflowExecutionError {
            status = .failed(error.description)
        } catch {
            status = .failed(String(describing: error))
        }

        refreshAvailability()
        await refreshCheckpointAvailability()
    }

    private func finish(_ result: WorkflowRun<DemoWorkflowState>) async throws {
        answer = result.state.answer ?? "The workflow finished without an answer."
        switch result.outcome {
        case .completed:
            status = .succeeded
        case let .recovered(recoveries):
            status = .recovered(
                recoveries.last?.failure.message
                    ?? "The workflow used a recovery path."
            )
        }

        try await checkpointStore.remove()
        hasSavedCheckpoint = false
    }

    private func refreshCheckpointAvailability() async {
        do {
            hasSavedCheckpoint = try await checkpointStore.load() != nil
        } catch {
            hasSavedCheckpoint = false
        }
    }

    private func record(_ event: WorkflowEvent) {
        trace.append(TraceItem(event: event))
    }

    private func resolveToolCall(
        _ approval: LanguageModelToolPendingApproval,
        decision: LanguageModelToolApprovalDecision
    ) {
        pendingToolApprovals.removeAll { $0.id == approval.id }
        Task { [approvalCoordinator] in
            await approvalCoordinator.resolve(approval.id, decision: decision)
        }
    }

    private static func makeModel(
        approvalHandler: @escaping LanguageModelToolApprovalHandler
    ) -> (
        model: AppleFoundationModel,
        failure: String?
    ) {
        let instructions = """
            You are the model inside a SwiftOrc demonstration. When a request
            contains arithmetic, use the calculate tool instead of doing the arithmetic
            yourself. Call it repeatedly when a calculation has multiple steps.
            """

        do {
            return (
                try AppleFoundationModel(
                    workflowToolRegistrations: [
                        DemoCalculatorTool.registration()
                    ],
                    instructions: instructions,
                    approvalHandler: approvalHandler
                ),
                nil
            )
        } catch {
            return (
                AppleFoundationModel(instructions: instructions),
                String(describing: error)
            )
        }
    }

    private static var checkpointURL: URL {
        let root =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        return
            root
            .appendingPathComponent("SwiftOrcDemo", isDirectory: true)
            .appendingPathComponent("checkpoint.json")
    }

    private static let calculatorExampleRequest = """
        Use the calculate tool for every arithmetic step. First multiply 17.5 by
        8, then add 42 to that result. Briefly explain the final result.
        """
}

private extension AppleFoundationModelAvailability.Reason {
    var description: String {
        switch self {
        case .deviceNotEligible:
            return "this device isn't eligible"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is disabled"
        case .modelNotReady:
            return "the model isn't ready"
        case .unknown:
            return "unknown reason"
        }
    }
}

@MainActor
@Observable
final class ModelVersionDemoViewModel {
    enum RunStatus: Equatable {
        case idle
        case running
        case succeeded
        case recovered
        case cancelled
        case failed(String)
    }

    var request = "Explain one benefit of an offline-first AI workflow."
    var versionSelection = DemoModelVersionSelection.automatic
    var simulatedLocalAvailability = true
    var useLiveAppleModel = false
    var allowRemoteFallback = false
    var remoteBehavior = DemoRemoteBehavior.succeeds
    var answer = ""
    var selectedImplementation = ""
    var trace: [TraceItem] = []
    var status = RunStatus.idle

    @ObservationIgnored
    private var runTask: Task<Void, Never>?

    private let appleModel = AppleFoundationModel()

    var isRunning: Bool {
        status == .running
    }

    var resolvedGeneration: DemoAppleModelGeneration {
        useLiveAppleModel
            ? .currentOS
            : versionSelection.resolvedGeneration
    }

    var effectiveLocalAvailability: Bool {
        if useLiveAppleModel {
            return appleModel.availability == .available
        }
        return simulatedLocalAvailability
    }

    var runtimeSummary: String {
        let source = useLiveAppleModel ? "Live Apple model" : "Simulation"
        let availability =
            effectiveLocalAvailability
            ? "available"
            : "unavailable"
        return "\(source) · \(resolvedGeneration.title) · local \(availability)"
    }

    func run() {
        let prompt = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }

        answer = ""
        selectedImplementation = ""
        trace = []
        status = .running

        let configuration = ModelVersionDemoConfiguration(
            generation: resolvedGeneration,
            localModelAvailable: effectiveLocalAvailability,
            usesLiveAppleModel: useLiveAppleModel,
            allowsRemoteFallback: allowRemoteFallback,
            remoteBehavior: remoteBehavior
        )
        let initialState = ModelVersionDemoState(
            request: prompt,
            generation: configuration.generation,
            localModelAvailable: configuration.localModelAvailable
        )

        runTask = Task { [weak self, appleModel] in
            guard let self else { return }
            do {
                let result: WorkflowRun<ModelVersionDemoState>
                if configuration.usesLiveAppleModel {
                    let workflow = try ModelVersionDemoFactory.make(
                        localModel: appleModel,
                        configuration: configuration
                    )
                    result = try await workflow.run(
                        initialState,
                        onEvent: { [weak self] event in
                            await self?.record(event)
                        }
                    )
                } else {
                    let workflow = try ModelVersionDemoFactory.make(
                        localModel: ModelVersionDemoFactory.simulatedLocalModel(),
                        configuration: configuration
                    )
                    result = try await workflow.run(
                        initialState,
                        onEvent: { [weak self] event in
                            await self?.record(event)
                        }
                    )
                }

                answer = result.state.answer ?? "The workflow returned no answer."
                selectedImplementation =
                    result.state.selectedImplementation
                    ?? "Unknown implementation"
                status = result.outcome.wasRecovered ? .recovered : .succeeded
            } catch is CancellationError {
                status = .cancelled
            } catch let error as WorkflowExecutionError {
                status = .failed(error.description)
            } catch {
                status = .failed(String(describing: error))
            }
            runTask = nil
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func record(_ event: WorkflowEvent) {
        trace.append(TraceItem(event: event))
    }
}
