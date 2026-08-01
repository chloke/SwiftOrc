import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    introduction
                    calculatorExampleLink
                    documentKnowledgeExampleLink
                    supportDeskExampleLink
                    pantryExampleLink
                    storyExampleLink
                    modelVersionExampleLink
                }
                .padding()
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("SwiftOrc Demo")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Practical workflow examples")
                .font(.title2.bold())
            Text(
                "Explore focused examples of local generation, native tools, "
                    + "validation, routing, fallback, and human-review policies."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var calculatorExampleLink: some View {
        NavigationLink {
            CalculatorDemoView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "function")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Calculator Pipeline")
                        .font(.headline)
                    Text(
                        "Inspect tool calling, automatic low-risk authorization, "
                            + "validation, fallback, checkpoints, and tracing."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [
                        Color.orange.opacity(0.15),
                        Color.yellow.opacity(0.06),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }

    private var supportDeskExampleLink: some View {
        NavigationLink {
            SupportDeskView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "headset")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Support Desk")
                        .font(.headline)
                    Text(
                        "Turn mock tickets and local business facts into grounded "
                            + "drafts with human-review routing."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [
                        Color.indigo.opacity(0.13),
                        Color.blue.opacity(0.06),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }

    private var documentKnowledgeExampleLink: some View {
        NavigationLink {
            DocumentKnowledgeView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF Knowledge")
                        .font(.headline)
                    Text(
                        "Ask questions of a local PDF and receive grounded answers "
                            + "with checked page citations."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.14),
                        Color.cyan.opacity(0.06),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }

    private var pantryExampleLink: some View {
        NavigationLink {
            PantryRescueView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "carrot.fill")
                    .font(.title2)
                    .foregroundStyle(
                        Color(
                            red: 31.0 / 255.0,
                            green: 92.0 / 255.0,
                            blue: 57.0 / 255.0
                        )
                    )
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pantry Rescue")
                        .font(.headline)
                    Text(
                        "Turn mock pantry ingredients and real preferences into a "
                            + "checked on-device meal plan."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [
                        Color.green.opacity(0.14),
                        Color.orange.opacity(0.07),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }

    private var storyExampleLink: some View {
        NavigationLink {
            StoryDemoView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "book.pages.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pocket Story Studio")
                        .font(.headline)
                    Text(
                        "Try a local-only story app that plans five connected parts, "
                            + "reviews them, and presents one continuous story."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [.indigo.opacity(0.13), .purple.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }

    private var modelVersionExampleLink: some View {
        NavigationLink {
            ModelVersionDemoView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Model-version and fallback example")
                        .font(.headline)
                    Text(
                        "Test version-specific nodes, local availability, a mock "
                            + "remote provider, and static fallback without networking."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

}

private struct TraceRow: View {
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

#Preview {
    ContentView()
}

private struct ModelVersionDemoView: View {
    @State private var viewModel = ModelVersionDemoViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                explanation
                runtimeConfiguration
                requestEditor
                controls
                result
                trace
            }
            .padding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Model compatibility")
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A fully local routing demonstration")
                .font(.title2.bold())
            Text(
                "The simulated local and remote providers are Swift closures. They "
                    + "never open a network connection. Live mode replaces only the "
                    + "local simulation with Apple's on-device model."
            )
            .foregroundStyle(.secondary)
            Label(viewModel.runtimeSummary, systemImage: "cpu")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var runtimeConfiguration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Runtime conditions")
                .font(.headline)

            Toggle("Use the live Apple on-device model", isOn: $viewModel.useLiveAppleModel)

            Picker("Model generation", selection: $viewModel.versionSelection) {
                ForEach(DemoModelVersionSelection.allCases) { selection in
                    Text(selection.title).tag(selection)
                }
            }
            .disabled(viewModel.useLiveAppleModel || viewModel.isRunning)

            Toggle(
                "Simulate local model availability",
                isOn: $viewModel.simulatedLocalAvailability
            )
            .disabled(viewModel.useLiveAppleModel || viewModel.isRunning)

            Divider()

            Toggle("Permit a remote fallback", isOn: $viewModel.allowRemoteFallback)
                .disabled(viewModel.isRunning)

            Picker("Mock remote behavior", selection: $viewModel.remoteBehavior) {
                ForEach(DemoRemoteBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .disabled(!viewModel.allowRemoteFallback || viewModel.isRunning)

            Text(
                viewModel.allowRemoteFallback
                    ? "The route is classified as remote, but its implementation is still an in-process mock."
                    : "Remote routes are excluded by policy; fallback goes directly to bundled static copy."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var requestEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Request")
                .font(.headline)
            TextEditor(text: $viewModel.request)
                .frame(minHeight: 90)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .disabled(viewModel.isRunning)
        }
    }

    private var controls: some View {
        HStack {
            Button {
                viewModel.run()
            } label: {
                Label("Run example", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning || viewModel.request.isEmpty)

            if viewModel.isRunning {
                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                }
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()
            statusLabel
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
        case .recovered:
            Label("Recovered", systemImage: "arrow.uturn.forward.circle.fill")
                .foregroundStyle(.orange)
        case .cancelled:
            Text("Cancelled").foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected implementation")
                .font(.headline)
            Text(
                viewModel.selectedImplementation.isEmpty
                    ? "Run the example to select a path."
                    : viewModel.selectedImplementation
            )
            .foregroundStyle(
                viewModel.selectedImplementation.isEmpty ? .secondary : .primary
            )

            Text(viewModel.answer.isEmpty ? "No output yet." : viewModel.answer)
                .foregroundStyle(viewModel.answer.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var trace: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Execution trace")
                .font(.headline)
            if viewModel.trace.isEmpty {
                Text("The selected version, provider skips, and fallback appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.trace) { item in
                    TraceRow(item: item)
                }
            }
        }
    }
}
