import Foundation
import Testing

@testable import SwiftOrc

private actor ScriptedLanguageModel: WorkflowLanguageModel {
    private var responses: [LanguageModelResponse]
    private(set) var requests: [LanguageModelRequest] = []

    init(_ responses: [LanguageModelResponse]) {
        self.responses = responses
    }

    func generate(
        _ request: LanguageModelRequest
    ) async throws -> LanguageModelResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw ScriptedLanguageModelError.noResponse
        }
        return responses.removeFirst()
    }
}

private enum ScriptedLanguageModelError: Error {
    case noResponse
}

private actor ToolEventRecorder {
    private(set) var events: [LanguageModelToolEvent] = []

    func record(_ event: LanguageModelToolEvent) {
        events.append(event)
    }
}

private actor InvocationRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private actor ApprovalRecorder {
    private(set) var requests: [LanguageModelToolApprovalRequest] = []

    func record(_ request: LanguageModelToolApprovalRequest) {
        requests.append(request)
    }
}

private actor AttemptRecorder {
    private(set) var attempts = 0

    func nextAttempt() -> Int {
        attempts += 1
        return attempts
    }
}

private actor ConcurrencyRecorder {
    private var active = 0
    private(set) var peak = 0

    func started() {
        active += 1
        peak = max(peak, active)
    }

    func finished() {
        active -= 1
    }
}

private enum PolicyTestError: Error {
    case transient
}

private struct AddArguments: Codable, Sendable, Equatable {
    let left: Int
    let right: Int
}

private struct AddResult: Codable, Sendable, Equatable {
    let sum: Int
}

private func addTool(
    recorder: InvocationRecorder? = nil
) -> ClosureLanguageModelTool<AddArguments, AddResult> {
    ClosureLanguageModelTool(
        definition: LanguageModelToolDefinition(
            name: "add",
            description: "Adds two integers.",
            parameters: .objectSchema(
                properties: [
                    "left": .object(["type": .string("integer")]),
                    "right": .object(["type": .string("integer")]),
                ],
                required: ["left", "right"]
            )
        ),
        call: { arguments in
            await recorder?.record("\(arguments.left)+\(arguments.right)")
            return AddResult(sum: arguments.left + arguments.right)
        }
    )
}

@Test
func executesTypedToolsUntilTheModelReturnsText() async throws {
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            provider: "remote",
            toolCalls: [
                LanguageModelToolCall(
                    id: "call-1",
                    name: "add",
                    arguments: #"{"left":2,"right":3}"#
                ),
                LanguageModelToolCall(
                    id: "call-2",
                    name: "add",
                    arguments: #"{"left":10,"right":5}"#
                ),
            ]
        ),
        LanguageModelResponse(
            content: "The totals are 5 and 15.",
            provider: "remote"
        ),
    ])
    let toolCalls = InvocationRecorder()
    let events = ToolEventRecorder()
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        tools: [addTool(recorder: toolCalls)],
        onEvent: { event in await events.record(event) }
    )

    let response = try await toolModel.generate(
        LanguageModelRequest(
            prompt: "Add two pairs of numbers.",
            toolChoice: .required,
            parallelToolCalls: false
        )
    )

    #expect(response.content == "The totals are 5 and 15.")
    #expect(await toolCalls.values == ["2+3", "10+5"])
    let report = try #require(response.toolExecutionReport)
    #expect(report.modelCalls == 2)
    #expect(report.toolRounds == 1)
    #expect(report.executions.map(\.callNumber) == [1, 2])
    #expect(report.executions.allSatisfy { $0.provider == "remote" })

    let requests = await model.requests
    #expect(requests.count == 2)
    #expect(requests[0].tools.map(\.name) == ["add"])
    #expect(requests[0].toolChoice == .required)
    #expect(requests[1].toolChoice == .automatic)
    #expect(requests[1].messages.count == 3)
    guard case let .assistant(content, calls) = requests[1].messages[0] else {
        Issue.record("Expected the assistant tool-call message")
        return
    }
    #expect(content == nil)
    #expect(calls.map(\.id) == ["call-1", "call-2"])
    guard case let .tool(firstID, firstOutput) = requests[1].messages[1],
        case let .tool(secondID, secondOutput) = requests[1].messages[2]
    else {
        Issue.record("Expected two tool result messages")
        return
    }
    #expect(firstID == "call-1")
    #expect(secondID == "call-2")
    #expect(
        try JSONDecoder().decode(
            AddResult.self,
            from: Data(firstOutput.utf8)
        ) == AddResult(sum: 5)
    )
    #expect(
        try JSONDecoder().decode(
            AddResult.self,
            from: Data(secondOutput.utf8)
        ) == AddResult(sum: 15)
    )

    #expect(
        await events.events == [
            .roundStarted(round: 1, calls: 2),
            .callStarted(round: 1, callNumber: 1, tool: "add"),
            .callCompleted(round: 1, callNumber: 1, tool: "add"),
            .callStarted(round: 1, callNumber: 2, tool: "add"),
            .callCompleted(round: 1, callNumber: 2, tool: "add"),
        ]
    )
}

@Test
func rejectsInvalidTypedToolArguments() async throws {
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "bad-call",
                    name: "add",
                    arguments: #"{"left":"not-an-integer","right":3}"#
                )
            ]
        )
    ])
    let events = ToolEventRecorder()
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        tools: [addTool()],
        onEvent: { event in await events.record(event) }
    )

    do {
        _ = try await toolModel.generate(
            LanguageModelRequest(prompt: "Add values")
        )
        Issue.record("Expected invalid tool arguments to fail")
    } catch let error as ToolCallingLanguageModelError {
        guard case let .executionFailed(callNumber, tool, failure) = error else {
            Issue.record("Expected a structured execution failure")
            return
        }
        #expect(callNumber == 1)
        #expect(tool == "add")
        #expect(failure.errorType.contains("LanguageModelToolInvocationError"))
    }
    #expect(
        await events.events == [
            .roundStarted(round: 1, calls: 1),
            .callStarted(round: 1, callNumber: 1, tool: "add"),
            .callFailed(round: 1, callNumber: 1, tool: "add"),
        ]
    )
}

@Test
func requiresApplicationApprovalBeforeExecutingProtectedTools() async throws {
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            provider: "remote",
            toolCalls: [
                LanguageModelToolCall(
                    id: "approved-call",
                    name: "add",
                    arguments: #"{"left":20,"right":22}"#
                )
            ]
        ),
        LanguageModelResponse(content: "42", provider: "remote"),
    ])
    let invocations = InvocationRecorder()
    let approvals = ApprovalRecorder()
    let events = ToolEventRecorder()
    let registration = LanguageModelToolRegistration(
        tool: addTool(recorder: invocations),
        policy: LanguageModelToolExecutionPolicy(approval: .always)
    )
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [registration],
        approvalHandler: { request in
            await approvals.record(request)
            return .approved
        },
        onEvent: { event in await events.record(event) }
    )

    let response = try await toolModel.generate(
        LanguageModelRequest(prompt: "Calculate")
    )

    #expect(response.content == "42")
    #expect(await invocations.values == ["20+22"])
    let approvalRequests = await approvals.requests
    #expect(approvalRequests.count == 1)
    #expect(approvalRequests[0].call.id == "approved-call")
    #expect(approvalRequests[0].provider == "remote")
    #expect(
        await events.events == [
            .roundStarted(round: 1, calls: 1),
            .callStarted(round: 1, callNumber: 1, tool: "add"),
            .approvalRequested(
                round: 1,
                callNumber: 1,
                tool: "add"
            ),
            .approvalResolved(
                round: 1,
                callNumber: 1,
                tool: "add",
                approved: true
            ),
            .callCompleted(round: 1, callNumber: 1, tool: "add"),
        ]
    )
}

@Test
func blocksToolsWhenApplicationApprovalIsDenied() async throws {
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "denied-call",
                    name: "add",
                    arguments: #"{"left":20,"right":22}"#
                )
            ]
        )
    ])
    let invocations = InvocationRecorder()
    let events = ToolEventRecorder()
    let registration = LanguageModelToolRegistration(
        tool: addTool(recorder: invocations),
        policy: LanguageModelToolExecutionPolicy(approval: .always)
    )
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [registration],
        approvalHandler: { _ in .denied },
        onEvent: { event in await events.record(event) }
    )

    do {
        _ = try await toolModel.generate(
            LanguageModelRequest(prompt: "Calculate")
        )
        Issue.record("Expected the denied tool call to fail")
    } catch let error as ToolCallingLanguageModelError {
        guard case let .executionFailed(callNumber, tool, failure) = error else {
            Issue.record("Expected a structured execution failure")
            return
        }
        #expect(callNumber == 1)
        #expect(tool == "add")
        #expect(failure.errorType.contains("LanguageModelToolPolicyError"))
    }

    #expect(await invocations.values.isEmpty)
    #expect(
        await events.events == [
            .roundStarted(round: 1, calls: 1),
            .callStarted(round: 1, callNumber: 1, tool: "add"),
            .approvalRequested(
                round: 1,
                callNumber: 1,
                tool: "add"
            ),
            .approvalResolved(
                round: 1,
                callNumber: 1,
                tool: "add",
                approved: false
            ),
            .callFailed(round: 1, callNumber: 1, tool: "add"),
        ]
    )
}

@Test
func retriesToolFailuresWithinTheRegisteredPolicy() async throws {
    let attempts = AttemptRecorder()
    let events = ToolEventRecorder()
    let flaky = ClosureLanguageModelTool<AddArguments, AddResult>(
        definition: addTool().definition,
        call: { arguments in
            guard await attempts.nextAttempt() >= 3 else {
                throw PolicyTestError.transient
            }
            return AddResult(sum: arguments.left + arguments.right)
        }
    )
    let registration = LanguageModelToolRegistration(
        tool: flaky,
        policy: LanguageModelToolExecutionPolicy(
            retry: LanguageModelToolRetryPolicy(maximumAttempts: 3)
        )
    )
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "retry-call",
                    name: "add",
                    arguments: #"{"left":2,"right":3}"#
                )
            ]
        ),
        LanguageModelResponse(content: "5"),
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [registration],
        onEvent: { event in await events.record(event) }
    )

    let response = try await toolModel.generate(
        LanguageModelRequest(prompt: "Calculate")
    )

    #expect(response.content == "5")
    #expect(await attempts.attempts == 3)
    #expect(
        await events.events == [
            .roundStarted(round: 1, calls: 1),
            .callStarted(round: 1, callNumber: 1, tool: "add"),
            .retryScheduled(
                round: 1,
                callNumber: 1,
                tool: "add",
                nextAttempt: 2
            ),
            .retryScheduled(
                round: 1,
                callNumber: 1,
                tool: "add",
                nextAttempt: 3
            ),
            .callCompleted(round: 1, callNumber: 1, tool: "add"),
        ]
    )
}

@Test
func timesOutSlowToolInvocations() async throws {
    let slow = ClosureLanguageModelTool<AddArguments, AddResult>(
        definition: addTool().definition,
        call: { arguments in
            try await Task.sleep(for: .seconds(1))
            return AddResult(sum: arguments.left + arguments.right)
        }
    )
    let registration = LanguageModelToolRegistration(
        tool: slow,
        policy: LanguageModelToolExecutionPolicy(
            timeout: .milliseconds(10)
        )
    )
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "slow-call",
                    name: "add",
                    arguments: #"{"left":2,"right":3}"#
                )
            ]
        )
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        registrations: [registration]
    )

    do {
        _ = try await toolModel.generate(
            LanguageModelRequest(prompt: "Calculate")
        )
        Issue.record("Expected the slow tool to time out")
    } catch let error as ToolCallingLanguageModelError {
        guard case let .executionFailed(_, _, failure) = error else {
            Issue.record("Expected a structured execution failure")
            return
        }
        #expect(failure.errorType.contains("LanguageModelToolPolicyError"))
        #expect(failure.message == "The operation failed.")
    }
}

@Test
func limitsParallelToolExecutionAndPreservesMessageOrder() async throws {
    let concurrency = ConcurrencyRecorder()
    let parallelTool = ClosureLanguageModelTool<AddArguments, AddResult>(
        definition: addTool().definition,
        call: { arguments in
            await concurrency.started()
            do {
                try await Task.sleep(for: .milliseconds(20))
                await concurrency.finished()
                return AddResult(sum: arguments.left + arguments.right)
            } catch {
                await concurrency.finished()
                throw error
            }
        }
    )
    let calls = (1...4).map { index in
        LanguageModelToolCall(
            id: "parallel-\(index)",
            name: "add",
            arguments: "{\"left\":\(index),\"right\":1}"
        )
    }
    let model = ScriptedLanguageModel([
        LanguageModelResponse(content: "", toolCalls: calls),
        LanguageModelResponse(content: "Finished"),
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        tools: [parallelTool],
        configuration: ToolCallingLanguageModelConfiguration(
            maximumConcurrentToolCalls: 2
        )
    )

    let response = try await toolModel.generate(
        LanguageModelRequest(
            prompt: "Calculate in parallel",
            parallelToolCalls: true
        )
    )

    #expect(response.content == "Finished")
    #expect(await concurrency.peak == 2)
    let requests = await model.requests
    let resultIDs = requests[1].messages.compactMap { message -> String? in
        guard case let .tool(callID, _) = message else { return nil }
        return callID
    }
    #expect(resultIDs == calls.map(\.id))
}

@Test
func refusesToolsThatWereNotExposedOnTheRequest() async throws {
    struct EmptyArguments: Codable, Sendable {}
    struct ToolResult: Codable, Sendable { let value: String }

    let secretCalls = InvocationRecorder()
    let secret = ClosureLanguageModelTool<EmptyArguments, ToolResult>(
        definition: LanguageModelToolDefinition(
            name: "secret",
            description: "A tool that is registered but not exposed.",
            parameters: .objectSchema(properties: [:], required: [])
        ),
        call: { _ in
            await secretCalls.record("called")
            return ToolResult(value: "secret")
        }
    )
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "secret-call",
                    name: "secret",
                    arguments: "{}"
                )
            ]
        )
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        tools: [addTool(), secret]
    )

    do {
        _ = try await toolModel.generate(
            LanguageModelRequest(
                prompt: "Use a tool",
                tools: [addTool().definition]
            )
        )
        Issue.record("Expected the unexposed tool call to be rejected")
    } catch let error as ToolCallingLanguageModelError {
        #expect(error == .toolNotAllowed)
    }
    #expect(await secretCalls.values.isEmpty)
}

@Test
func stopsToolLoopsAtTheConfiguredRoundLimit() async throws {
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "call-1",
                    name: "add",
                    arguments: #"{"left":1,"right":1}"#
                )
            ]
        ),
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "call-2",
                    name: "add",
                    arguments: #"{"left":2,"right":2}"#
                )
            ]
        ),
    ])
    let calls = InvocationRecorder()
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        tools: [addTool(recorder: calls)],
        configuration: ToolCallingLanguageModelConfiguration(
            maximumToolRounds: 1
        )
    )

    do {
        _ = try await toolModel.generate(
            LanguageModelRequest(prompt: "Keep using tools")
        )
        Issue.record("Expected the tool round limit to stop execution")
    } catch let error as ToolCallingLanguageModelError {
        #expect(error == .maximumToolRoundsExceeded(1))
    }
    #expect(await calls.values == ["1+1"])
    #expect(await model.requests.count == 2)
}

@Test
func addsCompletedToolExecutionToWorkflowTrace() async throws {
    struct ToolState: Sendable {
        var answer = ""
    }

    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "call-1",
                    name: "add",
                    arguments: #"{"left":20,"right":22}"#
                )
            ]
        ),
        LanguageModelResponse(content: "42"),
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        tools: [addTool()]
    )
    let node = LanguageModelNode<ToolState>(
        id: "calculate",
        model: toolModel,
        request: { _, _ in LanguageModelRequest(prompt: "Calculate") },
        reduce: { response, state, _ in
            var state = state
            state.answer = response.content
            return .finish(state)
        }
    )
    let workflow = try Workflow<ToolState>(initialNode: "calculate") {
        node
    }

    let run = try await workflow.run(ToolState())

    #expect(run.state.answer == "42")
    #expect(
        run.events.contains { event in
            guard
                case let .annotation(
                    "calculate",
                    .languageModelTools(report)
                ) = event
            else {
                return false
            }
            return report.modelCalls == 2
                && report.executions.map(\.tool) == ["add"]
        }
    )
}

@Test
func preservesProviderManagedToolExecutionReports() async throws {
    let providerReport = LanguageModelToolExecutionReport(
        modelCalls: 1,
        toolRounds: 0,
        executions: [
            LanguageModelToolExecutionRecord(
                round: 0,
                callNumber: 1,
                tool: "add",
                provider: "on-device"
            )
        ],
        providerManaged: true
    )
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "42",
            provider: "on-device",
            toolExecutionReport: providerReport
        )
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        tools: [addTool()]
    )

    let response = try await toolModel.generate(
        LanguageModelRequest(prompt: "Calculate")
    )

    let report = try #require(response.toolExecutionReport)
    #expect(report == providerReport)
}

@Test
func providerToolCallIDsNeverEnterDiagnostics() async throws {
    let sensitiveCallID = "secret-user-content-from-provider"
    let events = ToolEventRecorder()
    let model = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            provider: "remote",
            toolCalls: [
                LanguageModelToolCall(
                    id: sensitiveCallID,
                    name: "add",
                    arguments: #"{"left":1,"right":2}"#
                )
            ]
        ),
        LanguageModelResponse(content: "3", provider: "remote"),
    ])
    let toolModel = try ToolCallingLanguageModel(
        model: model,
        tools: [addTool()],
        onEvent: { event in await events.record(event) }
    )

    let response = try await toolModel.generate(
        LanguageModelRequest(prompt: "Calculate")
    )
    let report = try #require(response.toolExecutionReport)
    let encodedReport = String(
        decoding: try JSONEncoder().encode(report),
        as: UTF8.self
    )
    let eventDescription = String(reflecting: await events.events)

    #expect(report.executions.map(\.callNumber) == [1])
    #expect(!encodedReport.contains(sensitiveCallID))
    #expect(!eventDescription.contains(sensitiveCallID))

    let failure = WorkflowFailure(
        error: ToolCallingLanguageModelError.unregisteredDefinition(
            sensitiveCallID
        )
    )
    #expect(failure.message == "The operation failed.")
    #expect(!failure.message.contains(sensitiveCallID))
}

@Test
func enforcesToolArgumentAndOutputByteLimits() async throws {
    let oversizedArgumentsModel = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "arguments",
                    name: "add",
                    arguments: String(repeating: "x", count: 32)
                )
            ]
        )
    ])
    let argumentLimited = try ToolCallingLanguageModel(
        model: oversizedArgumentsModel,
        tools: [addTool()],
        configuration: ToolCallingLanguageModelConfiguration(
            maximumToolArgumentBytes: 16
        )
    )

    do {
        _ = try await argumentLimited.generate(
            LanguageModelRequest(prompt: "Calculate")
        )
        Issue.record("Expected oversized tool arguments to fail")
    } catch let error as ToolCallingLanguageModelError {
        guard case let .executionFailed(_, _, failure) = error else {
            Issue.record("Expected a structured tool execution failure")
            return
        }
        #expect(failure.errorType.contains("ToolCallingLanguageModelError"))
        #expect(failure.message == "The operation failed.")
    }

    let largeOutput = ClosureLanguageModelTool<AddArguments, String>(
        definition: addTool().definition,
        call: { _ in String(repeating: "x", count: 64) }
    )
    let oversizedOutputModel = ScriptedLanguageModel([
        LanguageModelResponse(
            content: "",
            toolCalls: [
                LanguageModelToolCall(
                    id: "output",
                    name: "add",
                    arguments: #"{"left":1,"right":2}"#
                )
            ]
        )
    ])
    let outputLimited = try ToolCallingLanguageModel(
        model: oversizedOutputModel,
        tools: [largeOutput],
        configuration: ToolCallingLanguageModelConfiguration(
            maximumToolOutputBytes: 16
        )
    )

    do {
        _ = try await outputLimited.generate(
            LanguageModelRequest(prompt: "Calculate")
        )
        Issue.record("Expected oversized tool output to fail")
    } catch let error as ToolCallingLanguageModelError {
        guard case let .executionFailed(_, _, failure) = error else {
            Issue.record("Expected a structured tool execution failure")
            return
        }
        #expect(failure.errorType.contains("ToolCallingLanguageModelError"))
        #expect(failure.message == "The operation failed.")
    }
}

@Test
func validatesLanguageModelToolRegistries() throws {
    let first = addTool()
    let second = addTool()

    do {
        _ = try LanguageModelToolRegistry([first, second])
        Issue.record("Expected duplicate tool names to be rejected")
    } catch let error as LanguageModelToolRegistryError {
        #expect(error == .duplicateToolName("add"))
    }

    do {
        _ = try LanguageModelToolRegistry(
            registrations: [
                LanguageModelToolRegistration(
                    tool: addTool(),
                    policy: LanguageModelToolExecutionPolicy(
                        retry: LanguageModelToolRetryPolicy(
                            maximumAttempts: 0
                        )
                    )
                )
            ]
        )
        Issue.record("Expected an invalid retry policy to be rejected")
    } catch let error as LanguageModelToolRegistryError {
        #expect(error == .invalidMaximumAttempts(tool: "add"))
    }

    do {
        _ = try ToolCallingLanguageModel(
            model: StaticLanguageModel(content: "unused"),
            tools: [addTool()],
            configuration: ToolCallingLanguageModelConfiguration(
                maximumConcurrentToolCalls: 0
            )
        )
        Issue.record("Expected an invalid concurrency limit to be rejected")
    } catch let error as ToolCallingLanguageModelConfigurationError {
        #expect(error == .invalidMaximumConcurrentToolCalls)
    }
}
