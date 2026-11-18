import Foundation
import Testing

@testable import SwiftOrc

/// Returns scripted outcomes in order and records every request.
private actor ConversationScriptedModel: WorkflowLanguageModel {
    enum Step: Sendable {
        case respond(LanguageModelResponse)
        case fail(any Error)
    }

    private var steps: [Step]
    private(set) var requests: [LanguageModelRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func generate(_ request: LanguageModelRequest) async throws -> LanguageModelResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.unknown) }
        switch steps.removeFirst() {
        case let .respond(response): return response
        case let .fail(error): throw error
        }
    }
}

private actor ConversationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct ChatState: Sendable {
    var chat = LanguageModelConversation()
    var replies: [String] = []
}

private func reply(_ text: String) -> ConversationScriptedModel.Step {
    .respond(LanguageModelResponse(content: text))
}

private let overflow = LanguageModelContextWindowExceeded(provider: "test")

private func seeded(_ count: Int, size: Int = 10) -> LanguageModelConversation {
    LanguageModelConversation(
        turns: (1...count).map { index in
            LanguageModelConversationTurn(
                prompt: "question \(index) " + String(repeating: "x", count: size),
                transcript: [.assistant(content: "answer \(index)", toolCalls: [])]
            )
        }
    )
}

private func chatNode(
    _ id: NodeID,
    next: NodeID?,
    model: ConversationScriptedModel,
    prompt: String,
    policy: LanguageModelConversationPolicy = .default
) -> AnyWorkflowNode<ChatState> {
    AnyWorkflowNode(
        LanguageModelNode(
            id: id,
            model: model,
            conversation: \ChatState.chat,
            policy: policy,
            request: { _, _ in LanguageModelRequest(prompt: prompt) },
            reduce: { response, state, _ in
                var state = state
                state.replies.append(response.content)
                if let next { return .next(state, next) }
                return .finish(state)
            }
        )
    )
}

@Test
func conversationNodeSendsHistoryBeforePromptAndRecordsTurns() async throws {
    let model = ConversationScriptedModel([reply("Hi Ada"), reply("You are Ada")])
    let workflow = try Workflow(
        initialNode: "first",
        nodes: [
            chatNode("first", next: "second", model: model, prompt: "I am Ada"),
            chatNode("second", next: nil, model: model, prompt: "Who am I?"),
        ]
    )

    let run = try await workflow.run(ChatState())

    let requests = await model.requests
    #expect(requests[0].history.isEmpty)
    #expect(
        requests[1].history == [
            .user("I am Ada"),
            .assistant(content: "Hi Ada", toolCalls: []),
        ])
    #expect(requests[1].prompt == "Who am I?")
    #expect(run.state.chat.turns.map(\.prompt) == ["I am Ada", "Who am I?"])
    #expect(run.state.chat.turns.last?.reply == "You are Ada")
}

@Test
func toolLoopTranscriptIsRecordedInHistory() async throws {
    let model = ConversationScriptedModel([
        .respond(
            LanguageModelResponse(
                content: "",
                toolCalls: [LanguageModelToolCall(id: "c1", name: "lookup", arguments: "{}")]
            )
        ),
        reply("It is sunny."),
    ])
    struct NoArguments: Decodable, Sendable {}
    let lookup = ClosureLanguageModelTool<NoArguments, String>(
        definition: LanguageModelToolDefinition(
            name: "lookup",
            description: "Looks up the weather.",
            parameters: .objectSchema(properties: [:], required: [])
        ),
        call: { _ in "sunny" }
    )
    let conversational = ConversationalLanguageModel(
        model: try ToolCallingLanguageModel(model: model, tools: [lookup])
    )

    _ = try await conversational.generate(LanguageModelRequest(prompt: "Weather?"))

    let turn = try #require(await conversational.conversation.turns.first)
    #expect(
        turn.transcript == [
            .assistant(
                content: nil,
                toolCalls: [LanguageModelToolCall(id: "c1", name: "lookup", arguments: "{}")]
            ),
            .tool(callID: "c1", content: #""sunny""#),
            .assistant(content: "It is sunny.", toolCalls: []),
        ])
}

@Test
func unansweredToolCallsAreNotRecorded() {
    var conversation = LanguageModelConversation()
    conversation.record(
        prompt: "Do it",
        response: LanguageModelResponse(
            content: "Calling a tool",
            toolCalls: [LanguageModelToolCall(id: "c1", name: "act", arguments: "{}")]
        )
    )

    #expect(
        conversation.turns[0].transcript == [
            .assistant(content: "Calling a tool", toolCalls: [])
        ])
}

@Test
func toolResultRetentionChangesOnlyWhatIsSent() async throws {
    let conversation = LanguageModelConversation(turns: [
        LanguageModelConversationTurn(
            prompt: "Q",
            transcript: [
                .assistant(
                    content: nil,
                    toolCalls: [LanguageModelToolCall(id: "c1", name: "t", arguments: "{}")]
                ),
                .tool(callID: "c1", content: "abcdefghij"),
                .assistant(content: "A", toolCalls: []),
            ]
        )
    ])

    let omitted = try await conversation.messages(
        policy: LanguageModelConversationPolicy(toolResults: .omitted)
    )
    let truncated = try await conversation.messages(
        policy: LanguageModelConversationPolicy(toolResults: .truncated(toBytes: 4))
    )

    #expect(omitted[2] == .tool(callID: "c1", content: "[Tool result omitted from history.]"))
    #expect(truncated[2] == .tool(callID: "c1", content: "abcd [truncated]"))
    #expect(conversation.turns[0].transcript[1] == .tool(callID: "c1", content: "abcdefghij"))
}

@Test
func providerRejectionDropsOldestTurnsAndRetries() async throws {
    let model = ConversationScriptedModel([.fail(overflow), reply("Done")])
    let conversational = ConversationalLanguageModel(model: model, conversation: seeded(4))

    let response = try await conversational.generate(LanguageModelRequest(prompt: "Next"))

    #expect(response.content == "Done")
    let requests = await model.requests
    #expect(requests.count == 2)
    #expect(requests[0].history.count == 8)
    // Without a known budget, the older half of the turns is dropped.
    #expect(requests[1].history.count == 4)
    #expect(await conversational.conversation.turns.map(\.prompt).last == "Next")
    #expect(await conversational.conversation.turns.count == 3)
}

@Test
func failOverflowLeavesHistoryUnchanged() async throws {
    let model = ConversationScriptedModel([.fail(overflow)])
    let conversational = ConversationalLanguageModel(
        model: model,
        conversation: seeded(2),
        policy: LanguageModelConversationPolicy(overflow: .fail)
    )

    await #expect(throws: LanguageModelContextWindowExceeded.self) {
        _ = try await conversational.generate(LanguageModelRequest(prompt: "Next"))
    }
    #expect(await conversational.conversation == seeded(2))
    #expect(await model.requests.count == 1)
}

@Test
func summarizeOverflowReplacesOlderTurnsWithSummary() async throws {
    let model = ConversationScriptedModel([.fail(overflow), reply("Done")])
    let summarizer = ConversationScriptedModel([reply("Ada likes tea.")])
    let conversational = ConversationalLanguageModel(
        model: model,
        conversation: seeded(3),
        policy: LanguageModelConversationPolicy(
            overflow: .summarize(using: summarizer, keepRecentTurns: 1)
        )
    )

    _ = try await conversational.generate(LanguageModelRequest(prompt: "Next"))

    let summaryRequest = try #require(await summarizer.requests.first)
    #expect(summaryRequest.prompt.contains("question 1"))
    #expect(summaryRequest.toolChoice == LanguageModelToolChoice.disabled)
    let retried = try #require(await model.requests.last)
    #expect(
        retried.history.first
            == .user(LanguageModelConversation.summaryMessage("Ada likes tea.")))
    let conversation = await conversational.conversation
    #expect(conversation.summary == "Ada likes tea.")
    #expect(conversation.turns.map(\.prompt).last == "Next")
    #expect(conversation.turns.count == 2)
}

@Test
func customOverflowRunsApplicationLogic() async throws {
    let model = ConversationScriptedModel([.fail(overflow), reply("Done")])
    let conversational = ConversationalLanguageModel(
        model: model,
        conversation: seeded(3),
        policy: LanguageModelConversationPolicy(
            overflow: .custom { conversation, context in
                #expect(context.reason == .providerRejected(overflow))
                conversation.turns = Array(conversation.turns.suffix(1))
            }
        )
    )

    _ = try await conversational.generate(LanguageModelRequest(prompt: "Next"))

    #expect(await model.requests.last?.history.count == 2)
}

@Test
func inputBudgetTrimsHistoryBeforeSending() async throws {
    let model = ConversationScriptedModel([reply("Done")])
    let conversational = ConversationalLanguageModel(
        model: model,
        conversation: seeded(5, size: 400),
        policy: LanguageModelConversationPolicy(maximumInputTokens: 250)
    )

    _ = try await conversational.generate(LanguageModelRequest(prompt: "Next"))

    let requests = await model.requests
    #expect(requests.count == 1)
    let sentTurns = requests[0].history.count / 2
    #expect(sentTurns < 5)
    #expect(sentTurns >= 1)
    #expect(
        LanguageModelCharacterTokenEstimator().estimatedTokens(for: requests[0]) <= 250
    )
}

@Test
func overflowIsNotRetriedAfterAToolRan() async throws {
    let actions = ConversationCounter()
    let model = ConversationScriptedModel([
        .respond(
            LanguageModelResponse(
                content: "",
                toolCalls: [LanguageModelToolCall(id: "c1", name: "send", arguments: "{}")]
            )
        ),
        .fail(overflow),
    ])
    struct NoArguments: Decodable, Sendable {}
    let send = ClosureLanguageModelTool<NoArguments, Bool>(
        definition: LanguageModelToolDefinition(
            name: "send",
            description: "Sends a message.",
            parameters: .objectSchema(properties: [:], required: [])
        ),
        call: { _ in
            await actions.increment()
            return true
        }
    )
    let conversational = ConversationalLanguageModel(
        model: try ToolCallingLanguageModel(model: model, tools: [send]),
        conversation: seeded(4)
    )

    await #expect(throws: LanguageModelContextWindowExceeded.self) {
        _ = try await conversational.generate(LanguageModelRequest(prompt: "Send it"))
    }
    #expect(await actions.value == 1)
    #expect(await model.requests.count == 2)
}

@Test
func routerReportsContextOverflowWhenEveryRouteRejects() async throws {
    let router = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "a", model: ConversationScriptedModel([.fail(overflow)])),
        LanguageModelRoute(provider: "b", model: ConversationScriptedModel([.fail(overflow)])),
    ])
    await #expect(throws: LanguageModelContextWindowExceeded.self) {
        _ = try await router.generate(LanguageModelRequest(prompt: "Hi"))
    }

    let mixed = try LanguageModelRouter(routes: [
        LanguageModelRoute(provider: "a", model: ConversationScriptedModel([.fail(overflow)])),
        LanguageModelRoute(
            provider: "b",
            model: ConversationScriptedModel([.fail(URLError(.timedOut))])
        ),
    ])
    await #expect(throws: LanguageModelRoutingError.self) {
        _ = try await mixed.generate(LanguageModelRequest(prompt: "Hi"))
    }
}

@Test
func imagesAreStoredAsArtifactsWhenAStoreIsAvailable() async throws {
    let store = try InMemoryWorkflowArtifactStore()
    let model = ConversationScriptedModel([reply("A cat"), reply("Yes")])
    let image = LanguageModelImage(source: .data(Data([1, 2, 3]), mediaType: "image/png"))
    let workflow = try Workflow(
        initialNode: "look",
        nodes: [
            AnyWorkflowNode(
                LanguageModelNode(
                    id: "look",
                    model: model,
                    conversation: \ChatState.chat,
                    request: { _, _ in
                        LanguageModelRequest(prompt: "What is this?", input: [.image(image)])
                    },
                    reduce: { _, state, _ in .next(state, "follow-up") }
                )
            ),
            chatNode("follow-up", next: nil, model: model, prompt: "Sure?"),
        ]
    )

    let run = try await workflow.run(ChatState(), artifactStore: store)

    guard case .storedImage = run.state.chat.turns[0].attachments.first else {
        Issue.record("Expected an artifact reference in history")
        return
    }
    let followUp = try #require(await model.requests.last)
    #expect(followUp.history.first == .userContent([.text("What is this?"), .image(image)]))
}

@Test
func historyRequiresConversationCapability() {
    let request = LanguageModelRequest(prompt: "Hi", history: [.user("Earlier")])
    #expect(request.effectiveRequiredCapabilities.contains(.conversationHistory))
}

@Test
func detectsContextWindowErrorsAndTheirTokenCounts() {
    let openAI = LanguageModelContextWindowExceeded.detect(
        provider: "o",
        statusCode: 400,
        code: "context_length_exceeded",
        message:
            "This model's maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens."
    )
    #expect(
        openAI
            == LanguageModelContextWindowExceeded(
                provider: "o", maximumTokens: 8192, requestedTokens: 9000))

    let anthropic = LanguageModelContextWindowExceeded.detect(
        provider: "a",
        statusCode: 400,
        code: nil,
        message: "prompt is too long: 210000 tokens > 200000 maximum"
    )
    #expect(
        anthropic
            == LanguageModelContextWindowExceeded(
                provider: "a", maximumTokens: 200_000, requestedTokens: 210_000))

    #expect(
        LanguageModelContextWindowExceeded.detect(
            provider: "o", statusCode: 400, code: "invalid_value", message: "Bad temperature"
        ) == nil)
}

@Test
func conversationalModelSerializesOverlappingTurns() async throws {
    let model = ConversationScriptedModel([reply("one"), reply("two")])
    let conversational = ConversationalLanguageModel(model: model)

    async let first = conversational.generate(LanguageModelRequest(prompt: "1"))
    async let second = conversational.generate(LanguageModelRequest(prompt: "2"))
    _ = try await (first, second)

    let requests = await model.requests
    // The later turn always sees the earlier one in its history.
    #expect(requests[0].history.isEmpty)
    #expect(requests[1].history.count == 2)
    #expect(await conversational.conversation.turns.count == 2)
}

private struct Mood: LanguageModelStructuredOutput, Equatable {
    let mood: String

    static let languageModelSchema = LanguageModelJSONSchema(
        name: "mood",
        schema: .objectSchema(
            properties: ["mood": .object(["type": .string("string")])],
            required: ["mood"]
        )
    )
}

private struct MoodState: Sendable {
    var chat = LanguageModelConversation()
    var moods: [String] = []
}

private func moodNode(
    _ id: NodeID,
    next: NodeID?,
    model: ConversationScriptedModel,
    prompt: String
) -> AnyWorkflowNode<MoodState> {
    AnyWorkflowNode(
        StructuredLanguageModelNode<MoodState, Mood>(
            id: id,
            model: model,
            conversation: \MoodState.chat,
            request: { _, _ in LanguageModelRequest(prompt: prompt) },
            reduce: { output, _, state, _ in
                var state = state
                state.moods.append(output.mood)
                if let next { return .next(state, next) }
                return .finish(state)
            }
        )
    )
}

@Test
func structuredNodeKeepsConversationHistory() async throws {
    let model = ConversationScriptedModel([
        reply(#"{"mood":"happy"}"#),
        reply(#"{"mood":"calm"}"#),
    ])
    let workflow = try Workflow(
        initialNode: "first",
        nodes: [
            moodNode("first", next: "second", model: model, prompt: "I got a puppy"),
            moodNode("second", next: nil, model: model, prompt: "Now I rest"),
        ]
    )

    let run = try await workflow.run(MoodState())

    let requests = await model.requests
    #expect(requests.allSatisfy { $0.responseFormat != nil })
    #expect(requests[1].history.first == .user("I got a puppy"))
    #expect(run.state.moods == ["happy", "calm"])
    #expect(run.state.chat.turns.count == 2)
}

@Test
func structuredNodeFailsOnUndecodableReplies() async throws {
    let model = ConversationScriptedModel([reply("not json")])
    let workflow = try Workflow(
        initialNode: "only",
        nodes: [moodNode("only", next: nil, model: model, prompt: "Hi")]
    )

    await #expect(throws: WorkflowExecutionError.self) {
        _ = try await workflow.run(MoodState())
    }
}
