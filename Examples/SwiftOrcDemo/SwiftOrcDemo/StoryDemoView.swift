import SwiftUI

struct StoryDemoView: View {
    @State private var viewModel = StoryDemoViewModel()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private let samples = [
        "A shy moon moth finds a tiny brass key in a rooftop garden.",
        "A teacup learns to sail across a kitchen sink during a thunderstorm.",
        "Two squirrels open a midnight bakery but forget how to make the moon pies glow.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: usesCompactLayout ? 16 : 22) {
                hero
                ideaCard

                if viewModel.isRunning {
                    progressCard
                }

                statusCard

                if !viewModel.story.isEmpty {
                    storyCard
                }

                howItWorks
                safetyNote
                traceDisclosure
            }
            .padding(.horizontal, usesCompactLayout ? 14 : 16)
            .padding(.vertical, usesCompactLayout ? 12 : 16)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(pageBackground)
        .navigationTitle("Story Studio")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var usesCompactLayout: Bool {
        #if os(iOS)
            horizontalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
        #else
            dynamicTypeSize.isAccessibilitySize
        #endif
    }

    private var pageBackground: some View {
        LinearGradient(
            colors: [
                Color.indigo.opacity(0.10),
                Color.purple.opacity(0.055),
                Color.clear,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var hero: some View {
        if usesCompactLayout {
            VStack(alignment: .leading, spacing: 14) {
                heroIcon(size: 48, cornerRadius: 14)
                heroCopy
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 16) {
                heroIcon(size: 58, cornerRadius: 16)
                heroCopy
            }
        }
    }

    private func heroIcon(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Image(systemName: "book.pages.fill")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [.indigo, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .shadow(color: .indigo.opacity(0.20), radius: 10, y: 5)
            .accessibilityHidden(true)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Turn one small idea into a real story")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "A local workflow plans the arc, writes five connected parts, "
                    + "checks each one, and joins them without chapter labels."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(
                viewModel.modelAvailability,
                systemImage: "iphone.gen3.radiowaves.left.and.right"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(viewModel.modelIsAvailable ? .green : .orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                (viewModel.modelIsAvailable ? Color.green : Color.orange)
                    .opacity(0.10),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private var ideaCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    ideaLabel
                    Spacer()
                    characterCount
                }

                VStack(alignment: .leading, spacing: 4) {
                    ideaLabel
                    characterCount
                }
            }

            TextEditor(text: $viewModel.idea)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 108)
                .padding(10)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 13)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(Color.primary.opacity(0.08))
                }
                .disabled(viewModel.isRunning)

            VStack(alignment: .leading, spacing: 8) {
                Text("Try an example")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(samples, id: \.self) { sample in
                            Button {
                                viewModel.useSample(sample)
                            } label: {
                                Text(sample)
                                    .lineLimit(1)
                                    .font(.caption)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isRunning)
                        }
                    }
                }
            }

            if usesCompactLayout, viewModel.isRunning {
                VStack(spacing: 10) {
                    generateButton
                    cancelButton
                }
            } else {
                HStack(spacing: 12) {
                    generateButton
                    if viewModel.isRunning {
                        cancelButton
                    }
                }
            }

            if !viewModel.modelIsAvailable {
                Text(
                    "This example intentionally has no network provider. Enable Apple "
                        + "Intelligence on a supported device to run it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .storyCardStyle()
    }

    private var ideaLabel: some View {
        Label("Your story seed", systemImage: "sparkles")
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var characterCount: some View {
        Text("\(viewModel.characterCount)/500")
            .font(.caption.monospacedDigit())
            .foregroundStyle(viewModel.characterCount > 500 ? .red : .secondary)
    }

    private var generateButton: some View {
        Button {
            viewModel.generate()
        } label: {
            Label(
                viewModel.story.isEmpty ? "Create story" : "Create a new version",
                systemImage: "wand.and.stars"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
        .controlSize(.large)
        .disabled(!viewModel.canGenerate)
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) {
            viewModel.cancel()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: usesCompactLayout ? .infinity : nil)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if usesCompactLayout {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.phase)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(Int(viewModel.progress * 100))% complete")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.phase)
                        .font(.headline)
                    Spacer()
                    Text("\(Int(viewModel.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: viewModel.progress)
                .tint(.indigo)

            HStack(spacing: usesCompactLayout ? 4 : 8) {
                ForEach(1...5, id: \.self) { number in
                    chapterIndicator(number)
                }
            }
        }
        .storyCardStyle()
    }

    private func chapterIndicator(_ number: Int) -> some View {
        let isComplete = number <= viewModel.completedChapters
        let isActive = number == viewModel.activeChapter

        return VStack(spacing: 6) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle.fill")
                .foregroundStyle(
                    isComplete
                        ? Color.green : isActive ? Color.indigo : Color.secondary.opacity(0.28)
                )
            Text(usesCompactLayout ? "\(number)" : "Part \(number)")
                .font(.caption2)
                .foregroundStyle(isActive || isComplete ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Story part \(number), "
                + (isComplete ? "complete" : isActive ? "in progress" : "waiting")
        )
    }

    @ViewBuilder
    private var statusCard: some View {
        switch viewModel.status {
        case .idle, .running, .succeeded:
            EmptyView()
        case .cancelled:
            messageCard(
                title: "Generation cancelled",
                message: "Nothing was saved. You can run the idea again whenever you like.",
                symbol: "pause.circle.fill",
                color: .orange
            )
        case let .blocked(message):
            messageCard(
                title: "No story was shown",
                message: message,
                symbol: "shield.lefthalf.filled.badge.checkmark",
                color: .orange
            )
        case let .failed(message):
            messageCard(
                title: "The workflow stopped",
                message: message,
                symbol: "exclamationmark.triangle.fill",
                color: .red
            )
        }
    }

    private func messageCard(
        title: String,
        message: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .storyCardStyle()
    }

    private var storyCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            if usesCompactLayout {
                VStack(alignment: .leading, spacing: 12) {
                    storyHeading
                    shareButton
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    storyHeading
                    Spacer()
                    shareButton
                }
            }

            Divider()

            Text(viewModel.story)
                .font(.system(.body, design: .serif))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.startOver()
            } label: {
                Label("Start another story", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.indigo.opacity(0.18))
        }
        .shadow(color: .indigo.opacity(0.08), radius: 18, y: 8)
    }

    private var storyHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your finished story")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(viewModel.title)
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shareButton: some View {
        ShareLink(item: viewModel.story) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Share story")
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What the workflow does")
                .font(.headline)

            workflowStep("1", "Plan", "Turns the idea into five connected story beats.")
            workflowStep(
                "2", "Write", "Generates one prose passage at a time with continuity notes.")
            workflowStep(
                "3",
                "Review",
                "Checks safety and repetition, then permits up to two replacement drafts."
            )
            workflowStep(
                "4", "Assemble", "Checks the whole result and joins the passages without headings.")
        }
        .storyCardStyle()
    }

    private func workflowStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.indigo, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var safetyNote: some View {
        Label {
            Text(
                "All model calls stay on device. Apple’s built-in guardrails and the "
                    + "workflow’s additional review reduce risk, but no automated filter "
                    + "can guarantee that every generated story is suitable for every child."
            )
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.indigo)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var traceDisclosure: some View {
        DisclosureGroup("Developer workflow trace") {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.trace.isEmpty {
                    Text("Run the story workflow to inspect its node transitions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.trace.suffix(16)) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(traceColor(item.kind))
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                Text(item.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
        .font(.subheadline.weight(.semibold))
        .storyCardStyle()
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

private extension View {
    func storyCardStyle() -> some View {
        padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.06))
            }
    }
}

#Preview {
    NavigationStack {
        StoryDemoView()
    }
}
