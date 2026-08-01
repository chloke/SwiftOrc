import SwiftUI
import UniformTypeIdentifiers

struct DocumentKnowledgeView: View {
    @State private var viewModel = DocumentKnowledgeViewModel()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        ZStack {
            Color.documentPageBackground
                .ignoresSafeArea()

            screen

            if viewModel.isBusy {
                DocumentKnowledgeProgressOverlay(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.stage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isBusy)
        .navigationTitle(viewModel.stage.navigationTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(viewModel.stage != .chooseDocument)
        #endif
        .toolbar {
            if viewModel.stage != .chooseDocument, !viewModel.isBusy {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if viewModel.stage == .answer {
                            viewModel.showQuestion()
                        } else {
                            viewModel.resetExample()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if viewModel.document != nil {
                        Button {
                            viewModel.replaceDocument()
                        } label: {
                            Label("Replace PDF", systemImage: "doc.badge.plus")
                        }
                    }
                    Button {
                        viewModel.resetExample()
                    } label: {
                        Label("Reset example", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Label("PDF Knowledge options", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .disabled(viewModel.isBusy)
            }
        }
        .fileImporter(
            isPresented: $viewModel.showsFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            viewModel.handleImport(result)
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch viewModel.stage {
        case .chooseDocument:
            PDFDocumentPickerScreen(
                viewModel: viewModel,
                usesCompactLayout: usesCompactLayout
            )
        case .ask:
            PDFQuestionScreen(
                viewModel: viewModel,
                usesCompactLayout: usesCompactLayout
            )
        case .answer:
            PDFAnswerScreen(
                viewModel: viewModel,
                usesCompactLayout: usesCompactLayout
            )
        }
    }

    private var usesCompactLayout: Bool {
        #if os(iOS)
            horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
        #else
            dynamicTypeSize.isAccessibilitySize
        #endif
    }
}

private struct PDFDocumentPickerScreen: View {
    @Bindable var viewModel: DocumentKnowledgeViewModel
    let usesCompactLayout: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 62, height: 62)
                        .background(
                            Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))

                    Text("Ask your own PDF")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Choose a document, ask a question, and get an answer tied back to the pages that support it."
                    )
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Label("The PDF stays on this device", systemImage: "lock.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.11), in: Capsule())

                VStack(alignment: .leading, spacing: 16) {
                    Text("How this demo works")
                        .font(.title3.bold())
                    feature(
                        symbol: "text.viewfinder",
                        title: "Extracts selectable text",
                        detail: "PDFKit reads text locally and keeps its original page number."
                    )
                    feature(
                        symbol: "magnifyingglass",
                        title: "Finds relevant passages",
                        detail: "A small local index narrows the document before the model runs."
                    )
                    feature(
                        symbol: "doc.text",
                        title: "Keeps source pages attached",
                        detail:
                            "Swift attaches retrieved passages and pages instead of asking the model to reproduce citation metadata."
                    )
                }
                .padding(20)
                .documentCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Demo limits")
                        .font(.headline)
                    Text(
                        "Selectable-text PDFs up to 20 MB and 250 pages. Scanned documents and password-protected files are not supported in this first example."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if case let .failed(message) = viewModel.status {
                    statusMessage(message, color: .red, symbol: "exclamationmark.triangle.fill")
                }

                Button {
                    viewModel.choosePDF()
                } label: {
                    Label("Choose a PDF", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isBusy)
            }
            .padding(.horizontal, usesCompactLayout ? 18 : 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func feature(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PDFQuestionScreen: View {
    @Bindable var viewModel: DocumentKnowledgeViewModel
    let usesCompactLayout: Bool
    @FocusState private var questionIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let document = viewModel.document {
                    documentSummary(document)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("What would you like to know?")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(
                        "Use words that appear in the document. The workflow searches locally before sending only the matching passages to Apple’s on-device model."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $viewModel.question)
                            .font(.body)
                            .focused($questionIsFocused)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 130)
                            .padding(10)
                            .background(.background, in: RoundedRectangle(cornerRadius: 13))
                            .overlay {
                                RoundedRectangle(cornerRadius: 13)
                                    .stroke(.separator, lineWidth: 1)
                            }

                        if viewModel.question.isEmpty {
                            Text("For example: What does the warranty cover?")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                    Text(
                        "\(viewModel.question.count)/\(PDFKnowledgeLimits.maximumQuestionCharacters)"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        viewModel.question.count > PDFKnowledgeLimits.maximumQuestionCharacters
                            ? Color.red : Color.secondary
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(20)
                .documentCard()

                Label(
                    viewModel.modelAvailability,
                    systemImage: viewModel.modelIsAvailable
                        ? "iphone.gen3.radiowaves.left.and.right"
                        : "text.quote"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(viewModel.modelIsAvailable ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

                statusView

                Button {
                    questionIsFocused = false
                    viewModel.askQuestion()
                } label: {
                    Label("Ask this PDF", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canAsk)
            }
            .padding(.horizontal, usesCompactLayout ? 18 : 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        questionIsFocused = false
                    }
                }
            }
        #endif
    }

    private func documentSummary(_ document: PDFKnowledgeDocument) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "doc.richtext.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(document.fileName)
                    .font(.headline)
                    .lineLimit(2)
                Text(
                    "\(document.pageCount) pages · \(document.chunks.count) searchable passages"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Replace") {
                questionIsFocused = false
                viewModel.replaceDocument()
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .documentCard()
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.status {
        case let .failed(message), let .blocked(message):
            statusMessage(message, color: .red, symbol: "exclamationmark.triangle.fill")
        case .cancelled:
            statusMessage("The question was cancelled.", color: .orange, symbol: "stop.circle")
        default:
            EmptyView()
        }
    }
}

private struct PDFAnswerScreen: View {
    @Bindable var viewModel: DocumentKnowledgeViewModel
    let usesCompactLayout: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                outcomeBanner

                if let answer = viewModel.answer {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Answer")
                            .font(.title2.bold())
                        Text(answer.answer)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .documentCard()

                    if !viewModel.citedChunks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                viewModel.answerMode == .extractiveFallback
                                    ? "Relevant passages" : "Sources"
                            )
                            .font(.title3.bold())
                            ForEach(viewModel.citedChunks) { chunk in
                                sourceCard(chunk)
                            }
                        }
                    }
                }

                Button {
                    viewModel.askAnotherQuestion()
                } label: {
                    Label("Ask another question", systemImage: "bubble.left.and.text.bubble.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                DisclosureGroup("How the workflow handled this question") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.trace) { item in
                            HStack(alignment: .top, spacing: 9) {
                                Circle()
                                    .fill(traceColor(item.kind))
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.caption.weight(.semibold))
                                    Text(item.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.callout)
                .padding(16)
                .documentCard()
            }
            .padding(.horizontal, usesCompactLayout ? 18 : 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var outcomeBanner: some View {
        switch viewModel.answerMode {
        case .generated:
            resultBanner(
                title: "Answered from this PDF",
                detail:
                    "The on-device model used locally retrieved passages. Swift attached the source pages shown below.",
                symbol: "checkmark.seal.fill",
                color: .green
            )
        case .extractiveFallback:
            resultBanner(
                title: "Showing source passages",
                detail:
                    "Apple’s model was unavailable, so no generated answer is presented. These passages were selected by local search.",
                symbol: "text.quote",
                color: .orange
            )
        case .noEvidence:
            resultBanner(
                title: "Not found in this document",
                detail:
                    "The local search did not find enough matching evidence, so the workflow stopped without asking the model to guess.",
                symbol: "questionmark.folder",
                color: .blue
            )
        case .none:
            EmptyView()
        }
    }

    private func resultBanner(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func sourceCard(_ chunk: PDFKnowledgeChunk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Page \(chunk.pageNumber)", systemImage: "doc.text")
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
            Text(chunk.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .documentCard()
    }

    private func traceColor(_ kind: TraceItem.Kind) -> Color {
        switch kind {
        case .information: .blue
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

private struct DocumentKnowledgeProgressOverlay: View {
    @Bindable var viewModel: DocumentKnowledgeViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 15) {
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text(viewModel.phase)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("All document processing stays on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 20, y: 8)
            .padding(24)
        }
    }
}

private func statusMessage(_ message: String, color: Color, symbol: String) -> some View {
    Label(message, systemImage: symbol)
        .font(.callout)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
}

private extension View {
    func documentCard() -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.separator.opacity(0.7), lineWidth: 0.5)
            }
    }
}

private extension Color {
    static var documentPageBackground: Color {
        #if canImport(UIKit)
            Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color.gray.opacity(0.08)
        #endif
    }
}
