import Foundation
import SwiftOrc
import SwiftOrcFoundationModels

struct StoryDemoState: Sendable, Codable {
    let idea: String
    var plan: StoryPlan?
    var segments: [String] = []
    var continuitySummary = ""
    var pendingSegment: String?
    var pendingContinuitySummary: String?
    var safetyDecision: StorySafetyDecision?
    var safetyConcern: String?
    var revisionReason: StoryRevisionReason?
    var revisionAttempts = Array(repeating: 0, count: 5)
    var title: String?
    var story: String?
    var blockedMessage: String?
}

struct StoryPlan: LanguageModelStructuredOutput, Codable {
    let title: String
    let protagonist: String
    let setting: String
    let voice: String
    let storyPromise: String
    let beats: [StoryBeat]

    static let languageModelSchema = LanguageModelJSONSchema(
        name: "story_plan",
        description: "A five-part plan for a short children's story.",
        schema: .objectSchema(
            properties: [
                "title": .stringSchema(
                    "A short, inviting title without quotation marks."
                ),
                "protagonist": .stringSchema(
                    "The main character and their defining trait."
                ),
                "setting": .stringSchema(
                    "The concrete place and time of the story."
                ),
                "voice": .stringSchema(
                    "The narration style, tense, and emotional tone."
                ),
                "storyPromise": .stringSchema(
                    "The central desire, difficulty, and satisfying change."
                ),
                "beats": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Exactly five ordered story beats forming one complete arc."
                    ),
                    "items": StoryBeat.schema,
                ]),
            ],
            required: [
                "title",
                "protagonist",
                "setting",
                "voice",
                "storyPromise",
                "beats",
            ]
        )
    )

    var promptSummary: String {
        let beatLines = beats.enumerated().map { index, beat in
            "\(index + 1). \(beat.event) Purpose: \(beat.purpose) "
                + "End state: \(beat.endingSituation)"
        }
        return """
            Title: \(title)
            Protagonist: \(protagonist)
            Setting: \(setting)
            Voice: \(voice)
            Story promise: \(storyPromise)
            Beats:
            \(beatLines.joined(separator: "\n"))
            """
    }
}

struct StoryBeat: Sendable, Codable {
    let event: String
    let purpose: String
    let endingSituation: String

    static let schema = JSONValue.objectSchema(
        properties: [
            "event": .stringSchema(
                "The specific action or discovery that happens in this part."
            ),
            "purpose": .stringSchema(
                "How this part advances the story instead of summarizing it."
            ),
            "endingSituation": .stringSchema(
                "The concrete situation that naturally leads into the next part."
            ),
        ],
        required: ["event", "purpose", "endingSituation"]
    )
}

struct StorySegment: LanguageModelStructuredOutput, Codable {
    let prose: String
    let continuitySummary: String

    static let languageModelSchema = LanguageModelJSONSchema(
        name: "story_segment",
        description: "One continuous prose segment and compact continuity notes.",
        schema: .objectSchema(
            properties: [
                "prose": .stringSchema(
                    "Four to six polished story sentences with no heading."
                ),
                "continuitySummary": .stringSchema(
                    "A brief factual summary of characters, objects, and the ending state."
                ),
            ],
            required: ["prose", "continuitySummary"]
        )
    )
}

enum StorySafetyDecision: String, Sendable, Codable {
    case safe
    case rewrite
    case block
}

enum StoryRevisionReason: String, Sendable, Codable {
    case safety
    case duplicate
}

struct StorySafetyReview: LanguageModelStructuredOutput, Codable {
    let decision: StorySafetyDecision
    let concern: String

    static let languageModelSchema = LanguageModelJSONSchema(
        name: "child_friendly_story_review",
        description: "A conservative review of story text for young children.",
        schema: .objectSchema(
            properties: [
                "decision": .object([
                    "type": .string("string"),
                    "description": .string(
                        "safe for acceptable text, rewrite for repairable text, or block for clearly unsuitable text."
                    ),
                    "enum": .array([
                        .string("safe"),
                        .string("rewrite"),
                        .string("block"),
                    ]),
                ]),
                "concern": .stringSchema(
                    "A short neutral concern, or the word none when safe."
                ),
            ],
            required: ["decision", "concern"]
        )
    )
}

enum StoryDemoWorkflowFactory {
    private static let chapterCount = 5
    private static let maximumRevisions = 2
    private static let safeStopNode: NodeID = "story-unavailable"

    static func make(model: AppleFoundationModel) throws
        -> Workflow<StoryDemoState>
    {
        let routedModel = try LanguageModelRouter(
            routes: [
                LanguageModelRoute(
                    provider: AppleFoundationModel.providerIdentifier,
                    kind: .onDevice,
                    capabilities: [.textInput, .structuredOutput],
                    model: model
                )
            ]
        )

        var nodes: [AnyWorkflowNode<StoryDemoState>] = [
            makeInputNode(),
            makePlanNode(model: routedModel),
        ]

        for chapter in 0..<chapterCount {
            nodes.append(
                contentsOf: makeChapterNodes(
                    chapter: chapter,
                    model: routedModel
                ))
        }

        nodes.append(contentsOf: [
            makeFinalSafetyNode(model: routedModel),
            makeFinalSafetyDecisionNode(),
            makeAssemblyNode(),
            makeSafeStopNode(),
        ])

        return try Workflow(
            definitionID: "story-demo-v1",
            initialNode: "validate-idea",
            nodes: nodes,
            configuration: WorkflowConfiguration(
                maximumSteps: 40,
                maximumRetriesPerNode: 2
            )
        )
    }

    private static func makeInputNode() -> AnyWorkflowNode<StoryDemoState> {
        AnyWorkflowNode(
            id: "validate-idea",
            declaredDestinations: ["plan-story", safeStopNode]
        ) { state, _ in
            let idea = state.idea.trimmingCharacters(in: .whitespacesAndNewlines)
            guard idea.count >= 8, idea.count <= 500 else {
                var state = state
                state.blockedMessage =
                    idea.count < 8
                    ? "Add a little more detail to the story idea."
                    : "Keep the story idea below 500 characters."
                return .next(state, safeStopNode)
            }
            return .next(state, "plan-story")
        }
    }

    private static func makePlanNode(
        model: LanguageModelRouter
    ) -> AnyWorkflowNode<StoryDemoState> {
        let node = StructuredLanguageModelNode<StoryDemoState, StoryPlan>(
            id: "plan-story",
            model: model,
            request: { state, context in
                let retryGuidance =
                    context.attempt > 1
                    ? " The previous plan was invalid. Return exactly five distinct beats."
                    : ""
                return LanguageModelRequest(
                    prompt: """
                        Turn this person's rough idea into a five-part story plan:

                        \(state.idea)
                        \(retryGuidance)
                        """,
                    instructions: """
                        Plan one coherent, warm story suitable for children ages 6–10.
                        Use exactly five ordered beats: setup, development, complication,
                        turning point, and earned resolution. Each beat must add a concrete
                        event. Do not merely restate or summarize the user's idea. Avoid
                        graphic violence, sexual content, cruelty, hate, dangerous
                        instructions, and frightening detail.
                        """,
                    options: LanguageModelGenerationOptions(
                        sampling: .randomProbabilityThreshold(0.9),
                        temperature: 0.5,
                        maximumResponseTokens: 650
                    ),
                    routingPolicy: .onDeviceOnly
                )
            },
            reduce: { output, _, state, _ in
                var state = state
                state.plan = output
                state.title = output.title
                return .next(state, "generate-1")
            }
        )

        let validPlan = WorkflowValidator<StoryDemoState> { state, _ in
            guard let plan = state.plan, plan.beats.count == chapterCount else {
                return .invalid(reason: "The plan must contain exactly five beats.")
            }
            let fields = [
                plan.title,
                plan.protagonist,
                plan.setting,
                plan.voice,
                plan.storyPromise,
            ]
            guard fields.allSatisfy({ !$0.trimmed.isEmpty }),
                plan.beats.allSatisfy({
                    !$0.event.trimmed.isEmpty
                        && !$0.purpose.trimmed.isEmpty
                        && !$0.endingSituation.trimmed.isEmpty
                })
            else {
                return .invalid(reason: "The plan contained an empty required field.")
            }
            return .valid
        }

        return AnyWorkflowNode(node)
            .validated(by: validPlan, onFailure: .retry)
            .timeout(after: .seconds(45))
            .recover(to: safeStopNode)
    }

    private static func makeChapterNodes(
        chapter: Int,
        model: LanguageModelRouter
    ) -> [AnyWorkflowNode<StoryDemoState>] {
        let number = chapter + 1
        let generateID = NodeID(rawValue: "generate-\(number)")
        let safetyID = NodeID(rawValue: "safety-\(number)")
        let decisionID = NodeID(rawValue: "safety-decision-\(number)")
        let duplicateCheckID = NodeID(rawValue: "duplicate-check-\(number)")
        let acceptID = NodeID(rawValue: "accept-\(number)")
        let prepareSafetyRewriteID = NodeID(
            rawValue: "prepare-safety-rewrite-\(number)"
        )
        let prepareDuplicateRewriteID = NodeID(
            rawValue: "prepare-duplicate-rewrite-\(number)"
        )
        let acceptedDestination: NodeID =
            number == chapterCount
            ? "final-safety"
            : NodeID(rawValue: "generate-\(number + 1)")

        let generation = StructuredLanguageModelNode<StoryDemoState, StorySegment>(
            id: generateID,
            model: model,
            request: { state, context in
                guard let plan = state.plan, plan.beats.indices.contains(chapter) else {
                    throw StoryDemoError.missingPlan
                }
                let beat = plan.beats[chapter]
                let priorEnding =
                    state.segments.last.map {
                        String($0.suffix(420))
                    } ?? "This is the opening segment."
                let revisionGuidance: String
                switch state.revisionReason {
                case .safety:
                    revisionGuidance = """
                        A safety review rejected an earlier draft. Make this version
                        gentler and clearly age-appropriate.
                        """
                case .duplicate:
                    revisionGuidance = """
                        The earlier draft repeated a previous passage. Replace it with a
                        genuinely new event. Do not reuse earlier dialogue, sentences, or
                        descriptions.
                        """
                case nil:
                    revisionGuidance = ""
                }
                let qualityGuidance =
                    context.attempt > 1
                    ? "The previous response failed a format or quality check. Return four to six complete prose sentences."
                    : ""
                let completedEvents = plan.beats.prefix(chapter).enumerated().map {
                    index, completedBeat in
                    "\(index + 1). \(completedBeat.event)"
                }.joined(separator: "\n")

                return LanguageModelRequest(
                    prompt: """
                        Write part \(number) of 5 for this plan.

                        \(plan.promptSummary)

                        This part's event: \(beat.event)
                        This part's purpose: \(beat.purpose)
                        It should end with: \(beat.endingSituation)

                        Prior continuity notes: \(state.continuitySummary.isEmpty ? "none" : state.continuitySummary)
                        Previous prose ending: \(priorEnding)
                        Events already completed and not to be repeated:
                        \(completedEvents.isEmpty ? "none" : completedEvents)

                        \(revisionGuidance)
                        \(qualityGuidance)
                        """,
                    instructions: """
                        Write only the next continuous story passage. Use four to six
                        natural sentences and roughly 70–120 words. Do not add a chapter
                        label, heading, recap, moral, or ending summary. Show the event
                        through action, sensory detail, and dialogue where useful. Preserve
                        names, facts, tense, and voice from earlier parts. Keep everything
                        suitable for children ages 6–10. Never repeat an earlier passage,
                        event, exchange, or block of wording.
                        """,
                    options: LanguageModelGenerationOptions(
                        sampling: .randomProbabilityThreshold(0.92),
                        temperature: 0.65,
                        maximumResponseTokens: 320
                    ),
                    routingPolicy: .onDeviceOnly
                )
            },
            reduce: { output, _, state, _ in
                var state = state
                state.pendingSegment = output.prose.trimmed
                state.pendingContinuitySummary = output.continuitySummary.trimmed
                state.safetyDecision = nil
                state.safetyConcern = nil
                return .next(state, duplicateCheckID)
            }
        )

        let segmentQuality = WorkflowValidator<StoryDemoState> { state, _ in
            guard let prose = state.pendingSegment, !prose.isEmpty else {
                return .invalid(reason: "The model returned an empty story segment.")
            }
            let wordCount = prose.split(whereSeparator: \Character.isWhitespace).count
            guard (35...180).contains(wordCount) else {
                return .invalid(reason: "The story segment had an unsuitable length.")
            }
            guard !prose.lowercased().hasPrefix("chapter ") else {
                return .invalid(reason: "The story segment included a chapter heading.")
            }
            return .valid
        }

        let reliableGeneration = AnyWorkflowNode(generation)
            .validated(by: segmentQuality, onFailure: .retry)
            .timeout(after: .seconds(45))
            .recover(to: safeStopNode)

        let safety = makeSafetyNode(
            id: safetyID,
            model: model,
            text: { $0.pendingSegment ?? "" },
            continuingTo: decisionID
        )

        let decision = BranchNode<StoryDemoState>(
            id: decisionID,
            routes: [
                BranchRoute("accepted", to: acceptID) { state, _ in
                    state.safetyDecision == .safe
                },
                BranchRoute("rewrite", to: prepareSafetyRewriteID) { state, _ in
                    state.safetyDecision == .rewrite
                        && state.revisionAttempts[chapter] < maximumRevisions
                },
            ],
            defaultTarget: safeStopNode,
            defaultRouteName: "blocked"
        )

        let duplicateCheck = BranchNode<StoryDemoState>(
            id: duplicateCheckID,
            routes: [
                BranchRoute("unique", to: safetyID) { state, _ in
                    guard let candidate = state.pendingSegment else { return false }
                    return !StoryDuplicateDetector.isDuplicate(
                        candidate,
                        of: state.segments
                    )
                },
                BranchRoute(
                    "rewrite-duplicate",
                    to: prepareDuplicateRewriteID
                ) { state, _ in
                    state.revisionAttempts[chapter] < maximumRevisions
                },
            ],
            defaultTarget: safeStopNode,
            defaultRouteName: "duplicate-limit-reached"
        )

        let accept = AnyWorkflowNode<StoryDemoState>(
            id: acceptID,
            declaredDestinations: [acceptedDestination]
        ) { state, _ in
            guard let segment = state.pendingSegment else {
                throw StoryDemoError.missingSegment
            }
            var state = state
            state.segments.append(segment)
            state.continuitySummary = state.pendingContinuitySummary ?? ""
            state.pendingSegment = nil
            state.pendingContinuitySummary = nil
            state.safetyDecision = nil
            state.safetyConcern = nil
            state.revisionReason = nil
            return .next(state, acceptedDestination)
        }

        let prepareSafetyRewrite = AnyWorkflowNode<StoryDemoState>(
            id: prepareSafetyRewriteID,
            declaredDestinations: [generateID]
        ) { state, _ in
            var state = state
            state.revisionReason = .safety
            state.revisionAttempts[chapter] += 1
            state.pendingSegment = nil
            state.pendingContinuitySummary = nil
            return .next(state, generateID)
        }

        let prepareDuplicateRewrite = AnyWorkflowNode<StoryDemoState>(
            id: prepareDuplicateRewriteID,
            declaredDestinations: [generateID]
        ) { state, _ in
            var state = state
            state.revisionReason = .duplicate
            state.revisionAttempts[chapter] += 1
            state.pendingSegment = nil
            state.pendingContinuitySummary = nil
            return .next(state, generateID)
        }

        return [
            reliableGeneration,
            safety,
            AnyWorkflowNode(decision),
            AnyWorkflowNode(duplicateCheck),
            accept,
            prepareSafetyRewrite,
            prepareDuplicateRewrite,
        ]
    }

    private static func makeSafetyNode(
        id: NodeID,
        model: LanguageModelRouter,
        text: @escaping @Sendable (StoryDemoState) -> String,
        continuingTo target: NodeID
    ) -> AnyWorkflowNode<StoryDemoState> {
        let node = StructuredLanguageModelNode<StoryDemoState, StorySafetyReview>(
            id: id,
            model: model,
            request: { state, _ in
                LanguageModelRequest(
                    prompt: """
                        Review this story text conservatively for a general audience of
                        children ages 6–10:

                        \(text(state))
                        """,
                    instructions: """
                        Return safe only when the passage has no sexual content, graphic
                        injury, gore, hateful content, abuse, dangerous instructions,
                        intense horror, or glamorized cruelty. Return rewrite when a mild
                        concern can be repaired by gentler wording. Return block for a
                        serious or central unsuitable theme. Evaluate the text; do not
                        continue the story.
                        """,
                    options: LanguageModelGenerationOptions(
                        sampling: .greedy,
                        temperature: 0,
                        maximumResponseTokens: 120
                    ),
                    routingPolicy: .onDeviceOnly
                )
            },
            reduce: { output, _, state, _ in
                var state = state
                state.safetyDecision = output.decision
                state.safetyConcern = output.concern
                return .next(state, target)
            }
        )

        return AnyWorkflowNode(node)
            .timeout(after: .seconds(30))
            .recover(to: safeStopNode)
    }

    private static func makeFinalSafetyNode(
        model: LanguageModelRouter
    ) -> AnyWorkflowNode<StoryDemoState> {
        makeSafetyNode(
            id: "final-safety",
            model: model,
            text: { $0.segments.joined(separator: "\n\n") },
            continuingTo: "final-safety-decision"
        )
    }

    private static func makeFinalSafetyDecisionNode()
        -> AnyWorkflowNode<StoryDemoState>
    {
        AnyWorkflowNode(
            BranchNode<StoryDemoState>(
                id: "final-safety-decision",
                routes: [
                    BranchRoute("accepted", to: "assemble-story") { state, _ in
                        state.safetyDecision == .safe
                            && state.segments.count == chapterCount
                    }
                ],
                defaultTarget: safeStopNode,
                defaultRouteName: "blocked"
            )
        )
    }

    private static func makeAssemblyNode() -> AnyWorkflowNode<StoryDemoState> {
        AnyWorkflowNode(id: "assemble-story") { state, _ in
            var state = state
            state.story = state.segments
                .map(\.trimmed)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            state.pendingSegment = nil
            state.pendingContinuitySummary = nil
            return .finish(state)
        }
    }

    private static func makeSafeStopNode() -> AnyWorkflowNode<StoryDemoState> {
        AnyWorkflowNode(id: safeStopNode) { state, _ in
            var state = state
            if state.blockedMessage == nil {
                state.blockedMessage = """
                    The local model could not produce a story that passed every safety
                    and quality check. Try a gentler or more specific idea.
                    """
            }
            state.story = nil
            return .finish(state)
        }
    }
}

/// Detects repeated prose without involving the language model.
///
/// Five-word shingles avoid treating recurring character names or ordinary
/// connective phrases as duplicates. The containment score also catches a
/// previous passage copied into a slightly longer new passage.
enum StoryDuplicateDetector {
    static func isDuplicate(
        _ candidate: String,
        of acceptedSegments: [String]
    ) -> Bool {
        let candidateTokens = tokens(in: candidate)
        guard candidateTokens.count >= 12 else { return false }

        return acceptedSegments.contains { accepted in
            let acceptedTokens = tokens(in: accepted)
            guard acceptedTokens.count >= 12 else { return false }

            if candidateTokens == acceptedTokens {
                return true
            }

            let candidateShingles = shingles(from: candidateTokens, width: 5)
            let acceptedShingles = shingles(from: acceptedTokens, width: 5)
            let smallerCount = min(candidateShingles.count, acceptedShingles.count)
            guard smallerCount > 0 else { return false }

            let sharedCount =
                candidateShingles
                .intersection(acceptedShingles)
                .count
            let containment = Double(sharedCount) / Double(smallerCount)
            return containment >= 0.68
        }
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }

    private static func shingles(
        from tokens: [String],
        width: Int
    ) -> Set<String> {
        guard tokens.count >= width else { return [] }
        return Set(
            (0...(tokens.count - width)).map { start in
                tokens[start..<(start + width)].joined(separator: " ")
            })
    }
}

private enum StoryDemoError: Error, Sendable {
    case missingPlan
    case missingSegment
}

private extension JSONValue {
    static func stringSchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
