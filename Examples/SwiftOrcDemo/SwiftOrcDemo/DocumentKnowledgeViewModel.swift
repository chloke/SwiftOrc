import Foundation
import Observation
import SwiftOrc
import SwiftOrcFoundationModels

@MainActor
@Observable
final class DocumentKnowledgeViewModel {
    enum Stage: Equatable {
        case chooseDocument
        case ask
        case answer

        var navigationTitle: String {
            switch self {
            case .chooseDocument: "PDF Knowledge"
            case .ask: "Ask this PDF"
            case .answer: "Document answer"
            }
        }
    }

    enum Status: Equatable {
        case idle
        case importing
        case answering
        case succeeded
        case extractiveFallback
        case noEvidence
        case blocked(String)
        case cancelled
        case failed(String)
    }

    var stage = Stage.chooseDocument
    var question = ""
    var showsFileImporter = false
    private(set) var document: PDFKnowledgeDocument?
    private(set) var answer: PDFKnowledgeAnswer?
    private(set) var answerMode: PDFKnowledgeAnswerMode?
    private(set) var status = Status.idle
    private(set) var phase = "Choose a PDF"
    private(set) var progress = 0.0
    private(set) var trace: [TraceItem] = []
    private(set) var modelAvailability = "Checking Apple Intelligence…"

    @ObservationIgnored
    private var workTask: Task<Void, Never>?

    private let model = AppleFoundationModel()

    init() {
        refreshAvailability()
    }

    var isBusy: Bool {
        status == .importing || status == .answering
    }

    var canAsk: Bool {
        guard document != nil, !isBusy else { return false }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= PDFKnowledgeLimits.maximumQuestionCharacters
    }

    var modelIsAvailable: Bool {
        model.availability == .available
    }

    var citedChunks: [PDFKnowledgeChunk] {
        guard let document, let answer else { return [] }
        let chunkByID = Dictionary(
            uniqueKeysWithValues: document.chunks.map { ($0.id, $0) }
        )
        return answer.citations.compactMap { chunkByID[$0.passageID] }
    }

    func choosePDF() {
        guard !isBusy else { return }
        showsFileImporter = true
    }

    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else {
                status = .failed("No PDF was selected.")
                phase = "Import failed"
                return
            }
            importPDF(at: url)
        case let .failure(error):
            if (error as NSError).code == NSUserCancelledError {
                return
            }
            status = .failed("The document picker could not open that file.")
            phase = "Import failed"
        }
    }

    func askQuestion() {
        guard canAsk, let document else { return }

        answer = nil
        answerMode = nil
        trace = []
        status = .answering
        phase = "Searching the PDF"
        progress = 0.05

        let initialState = PDFKnowledgeQuestionState(
            question: question,
            chunks: document.chunks
        )
        workTask = Task { [weak self, model] in
            guard let self else { return }
            do {
                let workflow = try PDFKnowledgeWorkflowFactory.make(model: model)
                let result = try await workflow.run(
                    initialState,
                    onEvent: { [weak self] event in
                        await self?.record(event)
                    }
                )

                guard let finishedAnswer = result.state.answer else {
                    phase = "No answer shown"
                    status = .blocked(
                        result.state.blockedMessage
                            ?? "The answer did not pass the citation checks."
                    )
                    workTask = nil
                    refreshAvailability()
                    return
                }

                answer = finishedAnswer
                answerMode = result.state.answerMode
                progress = 1
                switch result.state.answerMode {
                case .extractiveFallback:
                    phase = "Relevant passages ready"
                    status = .extractiveFallback
                case .noEvidence:
                    phase = "No matching evidence"
                    status = .noEvidence
                case .generated, .none:
                    phase = "Cited answer ready"
                    status = .succeeded
                }
                stage = .answer
            } catch is CancellationError {
                phase = "Question cancelled"
                status = .cancelled
            } catch let error as WorkflowExecutionError {
                phase = "Question stopped"
                status = .failed(error.failure.message)
            } catch {
                phase = "Question stopped"
                status = .failed("The PDF question could not be completed.")
            }
            workTask = nil
            refreshAvailability()
        }
    }

    func cancel() {
        workTask?.cancel()
    }

    func askAnotherQuestion() {
        guard !isBusy else { return }
        answer = nil
        answerMode = nil
        question = ""
        trace = []
        status = .idle
        phase = "Ready for a question"
        progress = 0
        stage = .ask
    }

    func showQuestion() {
        guard !isBusy else { return }
        stage = .ask
    }

    func replaceDocument() {
        guard !isBusy else { return }
        document = nil
        answer = nil
        answerMode = nil
        question = ""
        trace = []
        status = .idle
        phase = "Choose a PDF"
        progress = 0
        stage = .chooseDocument
        showsFileImporter = true
    }

    func resetExample() {
        guard !isBusy else { return }
        document = nil
        answer = nil
        answerMode = nil
        question = ""
        trace = []
        status = .idle
        phase = "Choose a PDF"
        progress = 0
        stage = .chooseDocument
    }

    private func importPDF(at url: URL) {
        workTask?.cancel()
        document = nil
        answer = nil
        answerMode = nil
        trace = []
        status = .importing
        phase = "Extracting selectable text"
        progress = 0.15

        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedDocument = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try PDFKnowledgeLoader.load(from: url)
                }.value
                try Task.checkCancellation()

                document = loadedDocument
                question = ""
                progress = 1
                phase = "PDF indexed locally"
                status = .idle
                stage = .ask
            } catch is CancellationError {
                phase = "Import cancelled"
                status = .cancelled
            } catch let error as PDFKnowledgeLoadingError {
                phase = "PDF not imported"
                status = .failed(error.message)
            } catch {
                phase = "PDF not imported"
                status = .failed("The PDF could not be processed locally.")
            }
            workTask = nil
        }
    }

    private func refreshAvailability() {
        switch model.availability {
        case .available:
            modelAvailability = "Apple’s on-device model is ready"
        case let .unavailable(reason):
            modelAvailability =
                "On-device model unavailable; relevant passages will be shown"
                + reason.documentKnowledgeSuffix
        }
    }

    private func record(_ event: WorkflowEvent) {
        trace.append(TraceItem(event: event))

        switch event {
        case let .nodeStarted(node, _, _):
            updateProgress(for: node.rawValue)
        case let .branchSelected(node, route, _):
            if node.rawValue == "review-answer", route == "revise" {
                phase = "Repairing citations or answer quality"
                progress = max(progress, 0.52)
            } else if node.rawValue == "route-evidence",
                route == "insufficient-evidence"
            {
                phase = "No matching passages found"
                progress = max(progress, 0.9)
            }
        case .fallbackSelected:
            phase = "Preparing relevant passages without generation"
            progress = max(progress, 0.5)
        case .finished:
            progress = 1
        default:
            break
        }
    }

    private func updateProgress(for node: String) {
        switch node {
        case "validate-question":
            phase = "Validating the question"
            progress = max(progress, 0.08)
        case "retrieve-passages":
            phase = "Searching the local PDF index"
            progress = max(progress, 0.22)
        case "route-evidence":
            phase = "Checking whether the PDF contains relevant evidence"
            progress = max(progress, 0.34)
        case "generate-answer":
            phase = "Writing an answer from retrieved passages"
            progress = max(progress, 0.46)
        case "extractive-fallback":
            phase = "Preparing the most relevant passages"
            progress = max(progress, 0.55)
        case "check-answer":
            phase = "Verifying citations and answer quality"
            progress = max(progress, 0.72)
        case "review-answer":
            phase = "Reviewing the validation result"
            progress = max(progress, 0.86)
        case "finish-answer", "no-evidence":
            phase = "Finishing the document answer"
            progress = max(progress, 0.95)
        case "answer-blocked":
            phase = "Stopping without an unsupported answer"
            progress = max(progress, 0.95)
        default:
            break
        }
    }
}

private extension AppleFoundationModelAvailability.Reason {
    var documentKnowledgeSuffix: String {
        switch self {
        case .deviceNotEligible: " (device not eligible)"
        case .appleIntelligenceNotEnabled: " (Apple Intelligence is disabled)"
        case .modelNotReady: " (model not ready)"
        case .unknown: ""
        }
    }
}
