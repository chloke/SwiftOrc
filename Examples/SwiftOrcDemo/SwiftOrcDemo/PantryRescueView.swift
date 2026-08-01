import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

struct PantryRescueView: View {
    @State private var viewModel = PantryRescueViewModel()
    @State private var showsCookingSteps = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        ZStack {
            PantryStyle.pageBackground
                .ignoresSafeArea()

            screen

            if viewModel.isRunning {
                PantryPlanningOverlay(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .foregroundStyle(PantryStyle.bodyText)
        .animation(.easeInOut(duration: 0.2), value: viewModel.stage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRunning)
        .navigationTitle(viewModel.stage.navigationTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(viewModel.stage != .pantry)
        #endif
        .toolbar {
            if viewModel.stage != .pantry, !viewModel.isRunning {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if viewModel.stage == .result {
                            viewModel.tryAnotherIdea()
                        } else {
                            viewModel.showPantry()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Back")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                toolbarMenu
            }
        }
        .sheet(isPresented: $showsCookingSteps) {
            if let recipe = viewModel.recipe {
                CookingStepsView(recipe: recipe)
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch viewModel.stage {
        case .pantry:
            PantrySelectionScreen(
                viewModel: viewModel,
                usesCompactLayout: usesCompactLayout
            )
        case .preferences:
            PantryPreferencesScreen(
                viewModel: viewModel,
                usesCompactLayout: usesCompactLayout
            )
        case .result:
            PantryResultScreen(
                viewModel: viewModel,
                usesCompactLayout: usesCompactLayout,
                showCookingSteps: {
                    showsCookingSteps = true
                }
            )
        }
    }

    @ViewBuilder
    private var toolbarMenu: some View {
        switch viewModel.stage {
        case .pantry:
            Menu {
                Button {
                    viewModel.showPreferences()
                } label: {
                    Label("Meal preferences", systemImage: "slider.horizontal.3")
                }
                .disabled(!viewModel.canContinue)

                Button {
                    viewModel.startOver()
                } label: {
                    Label("Reset example", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Label("Pantry settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
        case .preferences:
            EmptyView()
        case .result:
            Menu {
                Button {
                    viewModel.tryAnotherIdea()
                } label: {
                    Label("Try another idea", systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    viewModel.startOver()
                } label: {
                    Label("Start over", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Label("Meal options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
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

private struct PantrySelectionScreen: View {
    @Bindable var viewModel: PantryRescueViewModel
    let usesCompactLayout: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ingredientSection
                safetySection
                primaryAction
            }
            .padding(.horizontal, usesCompactLayout ? 18 : 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What can we make tonight?")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(PantryStyle.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text("Choose what you have. Your allergies stay non-negotiable.")
                .font(.body)
                .foregroundStyle(PantryStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                viewModel.modelAvailability,
                systemImage: viewModel.modelIsAvailable
                    ? "iphone.gen3.radiowaves.left.and.right"
                    : "arrow.triangle.2.circlepath"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                viewModel.modelIsAvailable ? Color.green : Color.orange
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                (viewModel.modelIsAvailable ? Color.green : Color.orange)
                    .opacity(0.10),
                in: Capsule()
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ingredientSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In your kitchen")
                .font(.title2.bold())
                .foregroundStyle(PantryStyle.primaryText)

            VStack(spacing: 0) {
                ForEach(Array(PantryCatalog.ingredients.enumerated()), id: \.element.id) {
                    index,
                    ingredient in
                    ingredientRow(ingredient)
                    if index < PantryCatalog.ingredients.count - 1 {
                        Divider()
                            .padding(.leading, 84)
                    }
                }
            }
            .pantryGroupedSurface()
        }
    }

    private func ingredientRow(_ ingredient: PantryIngredient) -> some View {
        let selected = viewModel.selectedIngredientIDs.contains(ingredient.id)

        return Button {
            viewModel.toggle(ingredient)
        } label: {
            HStack(spacing: 14) {
                Image(ingredient.assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(Color.primary.opacity(0.06))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(ingredient.name)
                        .font(.headline)
                        .foregroundStyle(PantryStyle.bodyText)
                    Text(ingredient.quantity)
                        .font(.subheadline)
                        .foregroundStyle(PantryStyle.secondaryText)
                }

                Spacer(minLength: 12)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(
                        selected ? PantryStyle.green : PantryStyle.secondaryText.opacity(0.5)
                    )
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(ingredient.name), \(selected ? "selected" : "not selected")"
        )
    }

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep it safe")
                .font(.title2.bold())
                .foregroundStyle(PantryStyle.primaryText)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    safetyValue(
                        symbol: "allergens",
                        title: "Peanut allergy",
                        color: PantryStyle.terracotta
                    )
                    Divider()
                        .frame(height: 34)
                    safetyValue(
                        symbol: "clock",
                        title: "\(viewModel.maximumCookTime) min",
                        color: PantryStyle.terracotta
                    )
                }

                VStack(spacing: 0) {
                    safetyValue(
                        symbol: "allergens",
                        title: "Peanut allergy",
                        color: PantryStyle.terracotta
                    )
                    Divider()
                    safetyValue(
                        symbol: "clock",
                        title: "\(viewModel.maximumCookTime) min",
                        color: PantryStyle.terracotta
                    )
                }
            }
            .pantryGroupedSurface()

            Button("Edit preferences") {
                viewModel.showPreferences()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PantryStyle.green)
            .frame(maxWidth: .infinity)
        }
    }

    private func safetyValue(
        symbol: String,
        title: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var primaryAction: some View {
        VStack(spacing: 11) {
            Button {
                viewModel.showPreferences()
            } label: {
                Text("Find a meal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PantryPrimaryButtonStyle())
            .disabled(!viewModel.canContinue)

            Label("Planned on this device", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(PantryStyle.secondaryText)

            if !viewModel.canContinue {
                Text("Select at least three ingredients to continue.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct PantryPreferencesScreen: View {
    @Bindable var viewModel: PantryRescueViewModel
    let usesCompactLayout: Bool
    @FocusState private var preferenceIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                requestEditor
                boundaries
                selectedIngredients
                action
                statusMessage
            }
            .padding(.horizontal, usesCompactLayout ? 18 : 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        preferenceIsFocused = false
                    }
                }
            }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("What sounds good?")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(PantryStyle.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Give us a direction—or leave it open and we’ll work with your pantry."
            )
            .foregroundStyle(PantryStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var requestEditor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $viewModel.preference)
                .font(.body)
                .focused($preferenceIsFocused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 116)
                .padding(12)
                .background(
                    PantryStyle.surface,
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(PantryStyle.green.opacity(0.45), lineWidth: 1.5)
                }
                .disabled(viewModel.isRunning)

            Text("\(viewModel.preference.count)/240")
                .font(.caption.monospacedDigit())
                .foregroundStyle(
                    viewModel.preference.count > 240
                        ? Color.red : PantryStyle.secondaryText
                )
        }
    }

    private var boundaries: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tonight’s boundaries")
                .font(.title3.bold())
                .foregroundStyle(PantryStyle.primaryText)

            VStack(spacing: 0) {
                boundaryRow(
                    symbol: "clock",
                    title: "Cooking time",
                    value: "\(viewModel.maximumCookTime) min",
                    action: viewModel.cycleCookingTime
                )
                Divider().padding(.leading, 58)
                boundaryRow(
                    symbol: "checkmark.shield.fill",
                    title: "Dietary safety",
                    value: "Peanut-free"
                )
                Divider().padding(.leading, 58)
                boundaryRow(
                    symbol: "frying.pan.fill",
                    title: "Equipment",
                    value: "Stovetop only"
                )
            }
            .pantryGroupedSurface()
        }
    }

    @ViewBuilder
    private func boundaryRow(
        symbol: String,
        title: String,
        value: String,
        action: (() -> Void)? = nil
    ) -> some View {
        if let action {
            Button(action: action) {
                boundaryRowContent(
                    symbol: symbol,
                    title: title,
                    value: value,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRunning)
        } else {
            boundaryRowContent(
                symbol: symbol,
                title: title,
                value: value,
                showsDisclosure: false
            )
        }
    }

    private func boundaryRowContent(
        symbol: String,
        title: String,
        value: String,
        showsDisclosure: Bool
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(PantryStyle.green)
                .frame(width: 30)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(PantryStyle.bodyText)
            Spacer()
            Text(value)
                .foregroundStyle(PantryStyle.secondaryText)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(PantryStyle.tertiaryText)
            }
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    private var selectedIngredients: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Available ingredients")
                    .font(.title3.bold())
                    .foregroundStyle(PantryStyle.primaryText)
                Spacer()
                Button("Review") {
                    preferenceIsFocused = false
                    viewModel.showPantry()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PantryStyle.green)
                .disabled(viewModel.isRunning)
            }

            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: -10) {
                        ForEach(viewModel.selectedIngredients) { ingredient in
                            Image(ingredient.assetName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 58, height: 58)
                                .clipShape(Circle())
                                .overlay {
                                    Circle()
                                        .stroke(PantryStyle.surface, lineWidth: 3)
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                }

                Divider()
                    .padding(.top, 14)

                Text("\(viewModel.selectedIngredients.count) ingredients selected")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .pantryGroupedSurface()
        }
    }

    private var action: some View {
        VStack(spacing: 11) {
            Button {
                preferenceIsFocused = false
                viewModel.planMeal()
            } label: {
                Text("Plan tonight’s meal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PantryPrimaryButtonStyle())
            .disabled(!viewModel.canPlan)

            Label("Your request stays on this device", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(PantryStyle.secondaryText)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch viewModel.status {
        case let .blocked(message):
            PantryMessageView(
                symbol: "exclamationmark.shield.fill",
                title: "No meal was shown",
                message: message,
                color: .orange
            )
        case .cancelled:
            PantryMessageView(
                symbol: "pause.circle.fill",
                title: "Planning cancelled",
                message: "Your pantry and preferences are still here.",
                color: .orange
            )
        case let .failed(message):
            PantryMessageView(
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

private struct PantryResultScreen: View {
    @Bindable var viewModel: PantryRescueViewModel
    let usesCompactLayout: Bool
    let showCookingSteps: () -> Void

    var body: some View {
        ScrollView {
            if let recipe = viewModel.recipe {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    title(recipe)
                    metadata(recipe)
                    safetyConfirmation
                    Text(recipe.summary)
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(PantryStyle.bodyText)
                    whyItWorks(recipe)
                    actions
                    traceDisclosure
                }
                .padding(.horizontal, usesCompactLayout ? 18 : 28)
                .padding(.vertical, 18)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "Meal unavailable",
                    systemImage: "fork.knife.circle",
                    description: Text("Return to preferences and try again.")
                )
                .padding()
            }
        }
    }

    private var hero: some View {
        Image("PantryMealHero")
            .resizable()
            .scaledToFill()
            .frame(height: usesCompactLayout ? 220 : 300)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.primary.opacity(0.06))
            }
            .accessibilityLabel(
                "Warm chickpea, spinach, tomato, yogurt, and pita plate"
            )
    }

    private func title(_ recipe: PantryRecipe) -> some View {
        Text(recipe.title)
            .font(
                .system(
                    usesCompactLayout ? .largeTitle : .largeTitle,
                    design: .serif,
                    weight: .bold
                )
            )
            .foregroundStyle(PantryStyle.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metadata(_ recipe: PantryRecipe) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                metadataValue("clock", "\(recipe.cookTimeMinutes) min")
                metadataValue("frying.pan", "Stovetop")
                metadataValue(
                    "leaf",
                    "Uses all \(recipe.ingredientIDs.count) ingredients"
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                metadataValue("clock", "\(recipe.cookTimeMinutes) min")
                metadataValue("frying.pan", "Stovetop")
                metadataValue(
                    "leaf",
                    "Uses all \(recipe.ingredientIDs.count) ingredients"
                )
            }
        }
    }

    private func metadataValue(_ symbol: String, _ value: String) -> some View {
        Label(value, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(PantryStyle.secondaryText)
    }

    private var safetyConfirmation: some View {
        Label(
            "Checked against your peanut allergy",
            systemImage: "checkmark.shield.fill"
        )
        .font(.headline)
        .foregroundStyle(PantryStyle.green)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.green.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityHint(
            "The app verified the selected pantry ingredients against its local allergen data."
        )
    }

    private func whyItWorks(_ recipe: PantryRecipe) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why this works")
                .font(.title2.bold())
                .foregroundStyle(PantryStyle.primaryText)

            VStack(spacing: 0) {
                ForEach(Array(recipe.whyItWorks.enumerated()), id: \.offset) {
                    index,
                    reason in
                    HStack(spacing: 13) {
                        Image(
                            systemName: [
                                "house.fill",
                                "frying.pan.fill",
                                "checkmark.shield.fill",
                            ][min(index, 2)]
                        )
                        .foregroundStyle(PantryStyle.green)
                        .frame(width: 28)

                        Text(reason)
                            .font(.body)
                        Spacer()
                    }
                    .padding(16)

                    if index < recipe.whyItWorks.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .pantryGroupedSurface()
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: showCookingSteps) {
                Text("Cook this meal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PantryPrimaryButtonStyle())

            Button("Try another idea") {
                viewModel.tryAnotherIdea()
            }
            .font(.headline)
            .foregroundStyle(PantryStyle.green)
            .padding(.vertical, 8)
        }
    }

    private var traceDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "The model proposed the recipe. Swift code checked pantry membership, allergens, cooking time, and equipment in parallel.",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(.caption)
                .foregroundStyle(PantryStyle.secondaryText)

                if viewModel.status == .recovered {
                    Label(
                        "Apple’s model was unavailable, so this run used the bundled in-process demo recipe before applying the same checks.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                ForEach(viewModel.trace.suffix(18)) { item in
                    PantryTraceRow(item: item)
                }
            }
            .padding(.top, 12)
        } label: {
            Label("How this plan was checked", systemImage: "info.circle")
                .font(.headline)
                .foregroundStyle(PantryStyle.primaryText)
        }
        .pantryGroupedSurface(padding: 16)
    }
}

private struct PantryPlanningOverlay: View {
    @Bindable var viewModel: PantryRescueViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(PantryStyle.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Planning tonight’s meal")
                            .font(.headline)
                        Text(viewModel.phase)
                            .font(.subheadline)
                            .foregroundStyle(PantryStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ProgressView(value: viewModel.progress)
                    .tint(PantryStyle.green)

                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                }
                .buttonStyle(.bordered)
            }
            .padding(22)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.16), radius: 30, y: 12)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct PantryMessageView: View {
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
                    .foregroundStyle(PantryStyle.secondaryText)
            }
        }
        .pantryGroupedSurface(padding: 16)
    }
}

private struct PantryTraceRow: View {
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
                    .foregroundStyle(PantryStyle.secondaryText)
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

private struct CookingStepsView: View {
    let recipe: PantryRecipe
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) {
                        index,
                        step in
                        HStack(alignment: .top, spacing: 13) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(PantryStyle.green, in: Circle())
                            Text(step)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 5)
                    }
                } header: {
                    Text(recipe.title)
                }
            }
            .navigationTitle("Cooking steps")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #if os(iOS)
            .presentationDetents([.medium, .large])
        #endif
    }
}

private struct PantryPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 54)
            .background(
                PantryStyle.green.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

private enum PantryStyle {
    static let green = adaptiveColor(
        light: (31, 92, 57),
        dark: (91, 204, 128)
    )
    static let terracotta = adaptiveColor(
        light: (200, 82, 61),
        dark: (241, 126, 105)
    )
    static let pageBackground = adaptiveColor(
        light: (249, 247, 241),
        dark: (17, 20, 18)
    )
    static let surface = adaptiveColor(
        light: (255, 254, 250),
        dark: (31, 36, 33)
    )
    static let primaryText = adaptiveColor(
        light: (21, 64, 40),
        dark: (201, 232, 211)
    )
    static let bodyText = adaptiveColor(
        light: (30, 34, 31),
        dark: (239, 243, 240)
    )
    static let secondaryText = adaptiveColor(
        light: (91, 98, 93),
        dark: (174, 182, 176)
    )
    static let tertiaryText = adaptiveColor(
        light: (126, 133, 128),
        dark: (139, 147, 141)
    )

    private static func adaptiveColor(
        light: (red: Double, green: Double, blue: Double),
        dark: (red: Double, green: Double, blue: Double)
    ) -> Color {
        #if canImport(UIKit)
            Color(
                uiColor: UIColor { traits in
                    let values = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(
                        red: values.red / 255.0,
                        green: values.green / 255.0,
                        blue: values.blue / 255.0,
                        alpha: 1
                    )
                }
            )
        #elseif canImport(AppKit)
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark =
                        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let values = isDark ? dark : light
                    return NSColor(
                        srgbRed: values.red / 255.0,
                        green: values.green / 255.0,
                        blue: values.blue / 255.0,
                        alpha: 1
                    )
                }
            )
        #else
            Color(
                red: light.red / 255.0,
                green: light.green / 255.0,
                blue: light.blue / 255.0
            )
        #endif
    }
}

private extension View {
    func pantryGroupedSurface(padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .background(
                PantryStyle.surface,
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.primary.opacity(0.08))
            }
    }
}

#Preview {
    NavigationStack {
        PantryRescueView()
    }
}
