import Foundation
import SwiftOrc
import SwiftOrcFoundationModels

struct PantryIngredient: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let quantity: String
    let assetName: String
    let allergens: Set<String>
}

enum PantryEquipment: String, CaseIterable, Codable, Sendable {
    case stovetop
    case skillet
    case mixingBowl = "mixing-bowl"
    case knife
    case cuttingBoard = "cutting-board"

    var displayName: String {
        switch self {
        case .stovetop: "Stovetop"
        case .skillet: "Skillet"
        case .mixingBowl: "Mixing bowl"
        case .knife: "Knife"
        case .cuttingBoard: "Cutting board"
        }
    }
}

enum PantryCatalog {
    static let ingredients = [
        PantryIngredient(
            id: "chickpeas",
            name: "Chickpeas",
            quantity: "1 can (15 oz)",
            assetName: "PantryChickpeas",
            allergens: []
        ),
        PantryIngredient(
            id: "cherry-tomatoes",
            name: "Cherry tomatoes",
            quantity: "1 pint",
            assetName: "PantryTomatoes",
            allergens: []
        ),
        PantryIngredient(
            id: "spinach",
            name: "Spinach",
            quantity: "3 cups",
            assetName: "PantrySpinach",
            allergens: []
        ),
        PantryIngredient(
            id: "greek-yogurt",
            name: "Greek yogurt",
            quantity: "1 cup",
            assetName: "PantryYogurt",
            allergens: ["milk"]
        ),
        PantryIngredient(
            id: "pita-bread",
            name: "Pita bread",
            quantity: "2 pieces",
            assetName: "PantryPita",
            allergens: ["wheat"]
        ),
    ]

    static let defaultIngredientIDs = Set(ingredients.map(\.id))
    static let ingredientByID = Dictionary(
        uniqueKeysWithValues: ingredients.map { ($0.id, $0) }
    )

    static func displayName(for id: String) -> String {
        ingredientByID[id]?.name ?? id
    }
}

struct PantryRecipe: LanguageModelStructuredOutput, Codable {
    let title: String
    let summary: String
    let cookTimeMinutes: Int
    let equipment: [PantryEquipment]
    let ingredientIDs: [String]
    let steps: [String]
    let whyItWorks: [String]

    static let languageModelSchema = LanguageModelJSONSchema(
        name: "pantry_rescue_recipe",
        description: "A practical meal made only from selected pantry ingredients.",
        schema: .objectSchema(
            properties: [
                "title": .stringSchema("A concise appetizing recipe title."),
                "summary": .stringSchema(
                    "One sentence describing the finished meal in natural language."
                ),
                "cookTimeMinutes": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "The realistic total cooking time in whole minutes."
                    ),
                ]),
                "equipment": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Only the equipment tokens permitted by the request."
                    ),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array(
                            PantryEquipment.allCases.map {
                                .string($0.rawValue)
                            }
                        ),
                    ]),
                ]),
                "ingredientIDs": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Every selected ingredient ID exactly once, with no other IDs."
                    ),
                    "items": .object(["type": .string("string")]),
                ]),
                "steps": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Three to eight clear cooking steps in execution order."
                    ),
                    "items": .object(["type": .string("string")]),
                ]),
                "whyItWorks": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Exactly three concise reasons this plan fits the request."
                    ),
                    "items": .object(["type": .string("string")]),
                ]),
            ],
            required: [
                "title",
                "summary",
                "cookTimeMinutes",
                "equipment",
                "ingredientIDs",
                "steps",
                "whyItWorks",
            ]
        )
    )
}

struct PantryRescueState: Sendable, Codable {
    let selectedIngredientIDs: [String]
    let request: String
    let maximumCookTime: Int
    let allergies: Set<String>
    let allowedEquipment: Set<PantryEquipment>
    var recipe: PantryRecipe?
    var validationIssues: [String] = []
    var generationCount = 0
    var usedStaticFallback = false
    var blockedMessage: String?
}

enum PantryRecipeChecks {
    static func inventoryIssues(in state: PantryRescueState) -> [String] {
        guard let recipe = state.recipe else {
            return ["The meal proposal was missing."]
        }

        var issues: [String] = []
        let proposed = recipe.ingredientIDs
        let proposedSet = Set(proposed)
        let selectedSet = Set(state.selectedIngredientIDs)

        if proposed.count != proposedSet.count {
            issues.append("List every ingredient only once.")
        }

        let unknown = proposedSet.filter {
            PantryCatalog.ingredientByID[$0] == nil
        }
        if !unknown.isEmpty {
            issues.append("Do not introduce ingredients outside the mock pantry.")
        }

        if proposedSet != selectedSet {
            issues.append("Use every selected pantry ingredient and no unselected items.")
        }
        return issues
    }

    static func allergyIssues(in state: PantryRescueState) -> [String] {
        guard let recipe = state.recipe else {
            return ["The meal could not be checked for dietary safety."]
        }

        let conflicts = recipe.ingredientIDs.compactMap {
            PantryCatalog.ingredientByID[$0]
        }.filter {
            !$0.allergens.isDisjoint(with: state.allergies)
        }
        let recipeText = ([recipe.title, recipe.summary] + recipe.steps)
            .joined(separator: " ")
            .lowercased()
        let mentionedAllergens = state.allergies.filter {
            recipeText.contains($0.lowercased())
        }

        guard conflicts.isEmpty, mentionedAllergens.isEmpty else {
            return [
                "The proposal conflicts with the configured dietary restrictions."
            ]
        }
        return []
    }

    static func preparationIssues(in state: PantryRescueState) -> [String] {
        guard let recipe = state.recipe else {
            return ["The meal preparation details were missing."]
        }

        var issues: [String] = []
        if !(1...state.maximumCookTime).contains(recipe.cookTimeMinutes) {
            issues.append(
                "Keep total preparation within \(state.maximumCookTime) minutes."
            )
        }

        if !Set(recipe.equipment).isSubset(of: state.allowedEquipment) {
            issues.append("Use only the equipment permitted by the request.")
        }
        return issues
    }

    static func qualityIssues(in state: PantryRescueState) -> [String] {
        guard let recipe = state.recipe else {
            return ["The meal proposal was missing."]
        }

        var issues: [String] = []
        if recipe.title.trimmed.isEmpty || recipe.summary.trimmed.isEmpty {
            issues.append("Return a title and a useful one-sentence description.")
        }
        if !(3...8).contains(recipe.steps.count)
            || recipe.steps.contains(where: { $0.trimmed.isEmpty })
        {
            issues.append("Return between three and eight non-empty cooking steps.")
        }
        if recipe.whyItWorks.count != 3
            || recipe.whyItWorks.contains(where: { $0.trimmed.isEmpty })
        {
            issues.append("Return exactly three non-empty fit explanations.")
        }
        return issues
    }
}

enum PantryRescueWorkflowFactory {
    private static let checkNode: NodeID = "check-recipe"
    private static let safeStopNode: NodeID = "meal-unavailable"

    static func make(model: AppleFoundationModel) throws
        -> Workflow<PantryRescueState>
    {
        let checks = try makeChecksNode()
        let decision = BranchNode<PantryRescueState>(
            id: "review-recipe",
            routes: [
                BranchRoute("approved", to: "finalize") { state, _ in
                    state.validationIssues.isEmpty
                },
                BranchRoute("revise", to: "generate-recipe") { state, _ in
                    !state.validationIssues.isEmpty
                        && state.generationCount < 3
                        && !state.usedStaticFallback
                },
            ],
            defaultTarget: safeStopNode,
            defaultRouteName: "safe-stop"
        )

        let finalize = AnyWorkflowNode<PantryRescueState>(id: "finalize") {
            state,
            _ in
            .finish(state)
        }

        let safeStop = AnyWorkflowNode<PantryRescueState>(
            id: safeStopNode
        ) { state, _ in
            var state = state
            if state.blockedMessage == nil {
                state.blockedMessage =
                    state.validationIssues.isEmpty
                    ? "No safe meal could be prepared from this request."
                    : "The meal could not satisfy every pantry and safety constraint."
            }
            state.recipe = nil
            return .finish(state)
        }

        return try Workflow(
            definitionID: "pantry-rescue-v1",
            initialNode: "validate-input",
            configuration: WorkflowConfiguration(
                maximumSteps: 18,
                maximumRetriesPerNode: 1
            )
        ) {
            makeInputNode()
            makeGenerateNode(model: model)
            makeStaticFallbackNode()
            checks
            decision
            finalize
            safeStop
        }
    }

    private static func makeInputNode() -> AnyWorkflowNode<PantryRescueState> {
        AnyWorkflowNode(
            id: "validate-input",
            declaredDestinations: ["generate-recipe", safeStopNode]
        ) { state, _ in
            let selected = Set(state.selectedIngredientIDs)
            guard selected.count >= 3 else {
                var state = state
                state.blockedMessage = "Choose at least three pantry ingredients."
                return .next(state, safeStopNode)
            }

            guard selected.isSubset(of: PantryCatalog.defaultIngredientIDs) else {
                var state = state
                state.blockedMessage = "The pantry selection contained an unknown item."
                return .next(state, safeStopNode)
            }

            let selectedIngredients = selected.compactMap {
                PantryCatalog.ingredientByID[$0]
            }
            guard
                selectedIngredients.allSatisfy({
                    $0.allergens.isDisjoint(with: state.allergies)
                })
            else {
                var state = state
                state.blockedMessage =
                    "One of the selected ingredients conflicts with your dietary settings."
                return .next(state, safeStopNode)
            }

            return .next(state, "generate-recipe")
        }
    }

    private static func makeGenerateNode(
        model: AppleFoundationModel
    ) -> AnyWorkflowNode<PantryRescueState> {
        let node = StructuredLanguageModelNode<PantryRescueState, PantryRecipe>(
            id: "generate-recipe",
            model: model,
            request: { state, _ in
                let ingredients = state.selectedIngredientIDs.compactMap { id in
                    PantryCatalog.ingredientByID[id].map {
                        "\($0.id): \($0.name), available quantity \($0.quantity)"
                    }
                }.joined(separator: "\n")
                let equipment = state.allowedEquipment
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ", ")
                let revision =
                    state.validationIssues.isEmpty
                    ? ""
                    : """

                    The previous proposal failed these deterministic checks:
                    - \(state.validationIssues.joined(separator: "\n- "))
                    Return a corrected, materially usable proposal.
                    """

                return LanguageModelRequest(
                    prompt: """
                        Create tonight's meal from this exact mock pantry:
                        \(ingredients)

                        The person's preference is:
                        \(state.request.trimmed.isEmpty
                            ? "No additional preference; choose a balanced meal."
                            : state.request.trimmed)

                        Maximum time: \(state.maximumCookTime) minutes
                        Allergies to avoid: \(state.allergies.sorted().joined(separator: ", "))
                        Allowed equipment tokens: \(equipment)
                        \(revision)
                        """,
                    instructions: """
                        Create one practical home-cooked meal. Use every selected ingredient
                        ID exactly once in ingredientIDs and never invent another ingredient
                        ID. Respect the time, allergy, and equipment constraints. Return
                        three concise reasons the meal fits. Keep the title, summary, and
                        steps helpful and natural. Do not claim that model output itself
                        proves allergy safety; the application performs that check.
                        """,
                    options: LanguageModelGenerationOptions(
                        sampling: .randomProbabilityThreshold(0.9),
                        temperature: 0.4,
                        maximumResponseTokens: 650
                    ),
                    routingPolicy: .onDeviceOnly
                )
            },
            reduce: { output, _, state, _ in
                var state = state
                state.recipe = output
                state.validationIssues = []
                state.generationCount += 1
                return .next(state, checkNode)
            }
        )

        return AnyWorkflowNode(node)
            .timeout(after: .seconds(45))
            .retrying(WorkflowNodeRetryPolicy(maximumAttempts: 2))
            .recover(to: "demo-fallback")
    }

    private static func makeStaticFallbackNode()
        -> AnyWorkflowNode<PantryRescueState>
    {
        AnyWorkflowNode(
            id: "demo-fallback",
            declaredDestinations: [checkNode]
        ) { state, _ in
            var state = state
            state.recipe = fallbackRecipe(for: state)
            state.validationIssues = []
            state.generationCount += 1
            state.usedStaticFallback = true
            return .next(state, checkNode)
        }
    }

    private static func makeChecksNode() throws
        -> ParallelNode<PantryRescueState>
    {
        try ParallelNode(
            id: checkNode,
            branches: [
                ParallelBranch("pantry") { state, _ in
                    var state = state
                    state.validationIssues = PantryRecipeChecks.inventoryIssues(
                        in: state
                    )
                    return state
                },
                ParallelBranch("dietary-safety") { state, _ in
                    var state = state
                    state.validationIssues = PantryRecipeChecks.allergyIssues(
                        in: state
                    )
                    return state
                },
                ParallelBranch("time-and-equipment") { state, _ in
                    var state = state
                    state.validationIssues = PantryRecipeChecks.preparationIssues(
                        in: state
                    )
                    return state
                },
                ParallelBranch("recipe-quality") { state, _ in
                    var state = state
                    state.validationIssues = PantryRecipeChecks.qualityIssues(
                        in: state
                    )
                    return state
                },
            ],
            continuation: .next("review-recipe")
        ) { initialState, results, _ in
            var state = initialState
            state.validationIssues = unique(
                results.ordered.flatMap { $0.state.validationIssues }
            )
            return state
        }
    }

    private static func fallbackRecipe(
        for state: PantryRescueState
    ) -> PantryRecipe {
        let selected = state.selectedIngredientIDs
        let names = selected.map { PantryCatalog.displayName(for: $0) }
        let usesDefaultPantry = Set(selected) == PantryCatalog.defaultIngredientIDs
        let steps =
            usesDefaultPantry
            ? [
                "Wash and prepare the tomatoes and spinach while the skillet warms.",
                "Warm the chickpeas and vegetables in the skillet until tender.",
                "Warm the pita, add the cooked ingredients, and finish with the yogurt.",
            ]
            : [
                "Prepare \(names.joined(separator: ", ")) for cooking and serving.",
                "Use the skillet to warm the ingredients that benefit from heat.",
                "Arrange the cooked and fresh components together and serve.",
            ]

        return PantryRecipe(
            title: usesDefaultPantry
                ? "Warm Chickpea Pita Plate"
                : "Quick Pantry Plate",
            summary: usesDefaultPantry
                ? "Crisp chickpeas, wilted spinach, juicy tomatoes, and cool yogurt tucked into warm pita."
                : "A simple stovetop plate that makes practical use of \(names.joined(separator: ", ")).",
            cookTimeMinutes: min(25, state.maximumCookTime),
            equipment: [
                .stovetop,
                .skillet,
                .mixingBowl,
                .knife,
                .cuttingBoard,
            ],
            ingredientIDs: selected,
            steps: steps,
            whyItWorks: [
                "Everything is already in your kitchen",
                "No oven is needed",
                "The ingredients pass the configured dietary checks",
            ]
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension JSONValue {
    static func stringSchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }
}
