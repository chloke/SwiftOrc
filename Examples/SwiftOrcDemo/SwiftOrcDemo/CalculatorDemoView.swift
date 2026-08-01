import SwiftUI

struct CalculatorDemoView: View {
    @State private var viewModel = DemoViewModel()
    @FocusState private var requestIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                introduction
                pipelineSummary
                requestEditor
                controls
                answerSection
                traceSection
            }
            .padding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Calculator Pipeline")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        requestIsFocused = false
                    }
                }
            }
        #endif
        .confirmationDialog(
            "Allow tool execution?",
            isPresented: toolApprovalIsPresented,
            titleVisibility: .visible,
            presenting: viewModel.pendingToolApproval
        ) { approval in
            Button("Allow \(approval.tool)") {
                viewModel.approveToolCall(approval)
            }
            Button("Deny", role: .destructive) {
                viewModel.denyToolCall(approval)
            }
        } message: { approval in
            let provider = approval.provider ?? "unknown provider"
            Text(
                "\(provider) wants to run \(approval.tool) with arguments:\n"
                    + approval.arguments
            )
        }
    }

    private var toolApprovalIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.pendingToolApproval != nil },
            set: { isPresented in
                guard !isPresented,
                    let approval = viewModel.pendingToolApproval
                else { return }
                viewModel.denyToolCall(approval)
            }
        )
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "function")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 58, height: 58)
                .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))

            Text("A tool-using workflow you can inspect")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "The model decides when arithmetic is needed, but a typed Swift tool performs every calculation. The workflow then validates, inspects, and finalizes the answer."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(viewModel.modelAvailability, systemImage: "apple.intelligence")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var pipelineSummary: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("What this page demonstrates")
                .font(.headline)
            Label("Typed calculator tool", systemImage: "function")
            Label("Automatic approval for minimal-risk local math", systemImage: "checkmark.shield")
            Label(
                "Retries, fallback, and checkpoint recovery",
                systemImage: "arrow.triangle.2.circlepath")
            Label(
                "Parallel inspection and a complete execution trace",
                systemImage: "point.3.connected.trianglepath.dotted")
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var requestEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Calculation request")
                    .font(.headline)
                Spacer()
                Button {
                    requestIsFocused = false
                    viewModel.loadCalculatorExample()
                } label: {
                    Label("Reset example", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRunning)
            }

            TextEditor(text: $viewModel.request)
                .focused($requestIsFocused)
                .font(.body)
                .frame(minHeight: 120)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .disabled(viewModel.isRunning)

            Text(
                "The bundled request requires two tool calls: multiplication followed by addition."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                controlButtons
                Spacer()
                statusLabel
            }

            VStack(alignment: .leading, spacing: 12) {
                controlButtons
                statusLabel
            }
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: 10) {
            Button {
                requestIsFocused = false
                viewModel.run()
            } label: {
                Label("Run workflow", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning || viewModel.request.isEmpty)

            if viewModel.hasSavedCheckpoint, !viewModel.isRunning {
                Button {
                    requestIsFocused = false
                    viewModel.resumeSaved()
                } label: {
                    Label("Resume saved", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            if viewModel.isRunning {
                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                }
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.status {
        case .idle:
            Text("Ready").foregroundStyle(.secondary)
        case .running:
            Text("Running…").foregroundStyle(.secondary)
        case .succeeded:
            Label("Succeeded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .recovered(message):
            Label("Recovered: \(message)", systemImage: "arrow.uturn.forward.circle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Text("Cancelled").foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Answer")
                .font(.headline)
            Text(
                viewModel.answer.isEmpty
                    ? "The checked workflow output will appear here." : viewModel.answer
            )
            .foregroundStyle(viewModel.answer.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var traceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Execution trace")
                .font(.headline)

            if viewModel.trace.isEmpty {
                Text("Run the workflow to see each node, tool event, and transition.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.trace) { item in
                    CalculatorTraceRow(item: item)
                }
            }
        }
    }
}

private struct CalculatorTraceRow: View {
    let item: TraceItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch item.kind {
        case .information: "circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch item.kind {
        case .information: .blue
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}
