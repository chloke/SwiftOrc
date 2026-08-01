import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

struct SupportDeskView: View {
    @State private var viewModel = SupportDeskViewModel()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        ZStack {
            SupportDeskStyle.pageBackground
                .ignoresSafeArea()

            screen

            if viewModel.isRunning {
                SupportDeskProgressOverlay(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.stage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRunning)
        .navigationTitle(viewModel.stage.navigationTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(viewModel.stage != .inbox)
        #endif
        .toolbar {
            if viewModel.stage != .inbox, !viewModel.isRunning {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if viewModel.stage == .result {
                            viewModel.showTicket()
                        } else {
                            viewModel.showInbox()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        viewModel.resetExample()
                    } label: {
                        Label("Reset example", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Label("Support Desk options", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .disabled(viewModel.isRunning)
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch viewModel.stage {
        case .inbox:
            SupportInboxScreen(
                viewModel: viewModel,
                usesCompactLayout: usesCompactLayout
            )
        case .ticket:
            SupportTicketScreen(
                viewModel: viewModel,
                usesCompactLayout: usesCompactLayout
            )
        case .result:
            SupportReviewScreen(
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

private struct SupportInboxScreen: View {
    @Bindable var viewModel: SupportDeskViewModel
    let usesCompactLayout: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                queueSummary

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("New tickets")
                            .font(.title2.bold())
                        Spacer()
                        Text("\(viewModel.tickets.count)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.tickets.enumerated()), id: \.element.id) {
                            index,
                            ticket in
                            ticketRow(ticket)
                            if index < viewModel.tickets.count - 1 {
                                Divider()
                                    .padding(.leading, 62)
                            }
                        }
                    }
                    .supportCard()
                }
            }
            .padding(.horizontal, usesCompactLayout ? 18 : 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A calmer support queue")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Turn local ticket context into grounded drafts while application policy keeps sensitive decisions with people."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(
                viewModel.modelAvailability,
                systemImage: viewModel.modelIsAvailable
                    ? "iphone.gen3.radiowaves.left.and.right"
                    : "arrow.triangle.2.circlepath"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(viewModel.modelIsAvailable ? Color.green : Color.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                (viewModel.modelIsAvailable ? Color.green : Color.orange)
                    .opacity(0.11),
                in: Capsule()
            )
        }
    }

    private var queueSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                summaryValue(
                    value: "3",
                    label: "New",
                    symbol: "tray.full.fill",
                    color: .indigo
                )
                summaryValue(
                    value: "1",
                    label: "Sensitive",
                    symbol: "person.badge.shield.checkmark.fill",
                    color: .orange
                )
                summaryValue(
                    value: "2",
                    label: "Routine",
                    symbol: "checkmark.message.fill",
                    color: .green
                )
            }

            VStack(spacing: 10) {
                summaryValue(
                    value: "3",
                    label: "New",
                    symbol: "tray.full.fill",
                    color: .indigo
                )
                summaryValue(
                    value: "1",
                    label: "Sensitive",
                    symbol: "person.badge.shield.checkmark.fill",
                    color: .orange
                )
                summaryValue(
                    value: "2",
                    label: "Routine",
                    symbol: "checkmark.message.fill",
                    color: .green
                )
            }
        }
    }

    private func summaryValue(
        value: String,
        label: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .supportCard()
    }

    private func ticketRow(_ ticket: SupportTicket) -> some View {
        Button {
            viewModel.open(ticket)
        } label: {
            HStack(alignment: .top, spacing: 13) {
                Text(initials(for: ticket.customerName))
                    .font(.caption.bold())
                    .foregroundStyle(Color.indigo)
                    .frame(width: 40, height: 40)
                    .background(Color.indigo.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ticket.customerName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(ticket.receivedLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(ticket.subject)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 7) {
                        priorityBadge(ticket.minimumPriority)
                        Text(ticket.plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 13)
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the mock support ticket")
    }

    private func priorityBadge(_ priority: SupportPriority) -> some View {
        Text(priority == .normal ? "Normal" : priority.displayName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(priority == .normal ? Color.secondary : Color.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (priority == .normal ? Color.secondary : Color.orange).opacity(0.11),
                in: Capsule()
            )
    }
}

private struct SupportTicketScreen: View {
    @Bindable var viewModel: SupportDeskViewModel
    let usesCompactLayout: Bool

    private var ticket: SupportTicket {
        viewModel.selectedTicket
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ticketHeader
                customerMessage
                accountContext
                availableKnowledge
                primaryAction
                statusMessage
            }
            .padding(.horizontal, usesCompactLayout ? 18 : 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var ticketHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(ticket.id, systemImage: "number")
                Spacer()
                Text(ticket.receivedLabel)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Text(ticket.subject)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label(ticket.customerName, systemImage: "person.fill")
                Text("•")
                Text("\(ticket.plan) plan")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var customerMessage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Customer message", systemImage: "bubble.left.and.text.bubble.right.fill")
                .font(.headline)
                .foregroundStyle(.indigo)

            Text(ticket.message)
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .supportCard(padding: 18)
    }

    private var accountContext: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("App-owned account context", systemImage: "person.text.rectangle.fill")
                .font(.headline)

            ForEach(ticket.accountContext, id: \.self) { fact in
                Label(fact, systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .supportCard(padding: 18)
    }

    private var availableKnowledge: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available knowledge")
                .font(.title3.bold())

            ForEach(ticket.relevantKnowledgeArticleIDs, id: \.self) { articleID in
                if let article = SupportDeskCatalog.articleByID[articleID] {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.indigo)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(article.title)
                                .font(.subheadline.weight(.semibold))
                            Text(article.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .supportCard(padding: 14)
                }
            }
        }
    }

    private var primaryAction: some View {
        VStack(spacing: 11) {
            Button {
                viewModel.prepareResponse()
            } label: {
                Label("Prepare agent response", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SupportPrimaryButtonStyle())

            Label(
                "Ticket context stays on this device",
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch viewModel.status {
        case let .blocked(message):
            SupportDeskMessage(
                symbol: "hand.raised.fill",
                title: "No reply was prepared",
                message: message,
                color: .orange
            )
        case .cancelled:
            SupportDeskMessage(
                symbol: "pause.circle.fill",
                title: "Triage cancelled",
                message: "The mock ticket is unchanged.",
                color: .orange
            )
        case let .failed(message):
            SupportDeskMessage(
                symbol: "exclamationmark.triangle.fill",
                title: "The workflow stopped",
                message: message,
                color: .red
            )
        default:
            EmptyView()
        }
    }
}

private struct SupportReviewScreen: View {
    @Bindable var viewModel: SupportDeskViewModel
    let usesCompactLayout: Bool

    var body: some View {
        ScrollView {
            if let decision = viewModel.decision {
                VStack(alignment: .leading, spacing: 22) {
                    dispositionBanner
                    ticketSummary(decision)
                    classification(decision)
                    replyEditor
                    sources
                    internalNote(decision)
                    reviewAction
                    workflowDisclosure
                }
                .padding(.horizontal, usesCompactLayout ? 18 : 28)
                .padding(.vertical, 20)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "Response unavailable",
                    systemImage: "text.bubble",
                    description: Text("Return to the ticket and try again.")
                )
                .padding()
            }
        }
    }

    private var dispositionBanner: some View {
        let needsHuman = viewModel.disposition == .humanReview
        let color: Color = needsHuman ? .orange : .green
        let symbol =
            needsHuman
            ? "person.badge.shield.checkmark.fill"
            : "checkmark.message.fill"
        let title = needsHuman ? "Human decision required" : "Grounded draft ready"

        return HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(viewModel.reviewReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
    }

    private func ticketSummary(_ decision: SupportDeskDecision) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.selectedTicket.subject)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(decision.summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(decision.customerNeed, systemImage: "scope")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func classification(_ decision: SupportDeskDecision) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                classificationValue(
                    "Category",
                    decision.category.displayName,
                    "tray.full.fill"
                )
                classificationValue(
                    "Priority",
                    decision.priority.displayName,
                    "flag.fill"
                )
                classificationValue(
                    "Request",
                    decision.requestedAction.displayName,
                    "arrow.triangle.branch"
                )
            }

            VStack(spacing: 10) {
                classificationValue(
                    "Category",
                    decision.category.displayName,
                    "tray.full.fill"
                )
                classificationValue(
                    "Priority",
                    decision.priority.displayName,
                    "flag.fill"
                )
                classificationValue(
                    "Request",
                    decision.requestedAction.displayName,
                    "arrow.triangle.branch"
                )
            }
        }
    }

    private func classificationValue(
        _ label: String,
        _ value: String,
        _ symbol: String
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(.indigo)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
        .supportCard(padding: 14)
    }

    private var replyEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Draft reply", systemImage: "text.bubble.fill")
                    .font(.title3.bold())
                Spacer()
                Text("\(viewModel.draftReply.count) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $viewModel.draftReply)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 230)
                .padding(12)
                .background(
                    SupportDeskStyle.surface,
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.indigo.opacity(0.28), lineWidth: 1)
                }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Grounded in local sources", systemImage: "checkmark.seal.fill")
                .font(.title3.bold())

            ForEach(viewModel.selectedArticles) { article in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(article.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(article.id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(article.facts.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .supportCard(padding: 14)
            }
        }
    }

    private func internalNote(_ decision: SupportDeskDecision) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Internal note", systemImage: "eye.slash.fill")
                .font(.headline)
            Text(decision.internalNote)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .supportCard(padding: 16)
    }

    private var reviewAction: some View {
        VStack(spacing: 11) {
            Button {
                viewModel.markReviewed()
            } label: {
                Label(
                    viewModel.isMarkedReviewed
                        ? "Reviewed"
                        : viewModel.disposition == .humanReview
                            ? "Mark reviewed by agent"
                            : "Mark reply ready",
                    systemImage: viewModel.isMarkedReviewed
                        ? "checkmark.circle.fill"
                        : "person.crop.circle.badge.checkmark"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SupportPrimaryButtonStyle())
            .disabled(viewModel.isMarkedReviewed)

            if viewModel.isMarkedReviewed {
                Text(
                    "Simulated only—this example does not send a message or change an account."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
    }

    private var workflowDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 11) {
                Label(
                    "Swift supplied the policy-owned triage and approval route. The model drafted the reply, then application checks reviewed its grounding, sensitive-action claims, and quality in parallel.",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if viewModel.usedFallback {
                    Label(
                        "Apple’s model was unavailable, so this run used bundled mock output before applying the same checks and route policy.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                ForEach(viewModel.trace.suffix(18)) { item in
                    SupportDeskTraceRow(item: item)
                }
            }
            .padding(.top, 12)
        } label: {
            Label("How this ticket was handled", systemImage: "info.circle")
                .font(.headline)
        }
        .supportCard(padding: 16)
    }
}

private struct SupportDeskProgressOverlay: View {
    @Bindable var viewModel: SupportDeskViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.indigo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Preparing an agent response")
                            .font(.headline)
                        Text(viewModel.phase)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ProgressView(value: viewModel.progress)
                    .tint(.indigo)

                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                }
                .buttonStyle(.bordered)
            }
            .padding(22)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.16), radius: 28, y: 12)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct SupportDeskMessage: View {
    let symbol: String
    let title: String
    let message: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .supportCard(padding: 16)
    }
}

private struct SupportDeskTraceRow: View {
    let item: TraceItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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

private struct SupportPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 54)
            .background(
                Color.indigo.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

private enum SupportDeskStyle {
    #if canImport(UIKit)
        static let pageBackground = Color(uiColor: .systemGroupedBackground)
        static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    #elseif canImport(AppKit)
        static let pageBackground = Color(nsColor: .windowBackgroundColor)
        static let surface = Color(nsColor: .controlBackgroundColor)
    #else
        static let pageBackground = Color.clear
        static let surface = Color.clear
    #endif
}

private extension View {
    func supportCard(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(
                SupportDeskStyle.surface,
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.primary.opacity(0.07))
            }
    }
}

private func initials(for name: String) -> String {
    name.split(separator: " ")
        .prefix(2)
        .compactMap(\.first)
        .map(String.init)
        .joined()
}

#Preview {
    NavigationStack {
        SupportDeskView()
    }
}
