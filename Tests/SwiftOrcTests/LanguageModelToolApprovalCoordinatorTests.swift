import Foundation
import Testing

@testable import SwiftOrc

private func approvalRequest(
    callID: String,
    tool: String,
    arguments: String = "{}"
) -> LanguageModelToolApprovalRequest {
    LanguageModelToolApprovalRequest(
        call: LanguageModelToolCall(
            id: callID,
            name: tool,
            arguments: arguments
        ),
        provider: "test-provider"
    )
}

@Test
func approvalCoordinatorPublishesAndApprovesARequest() async throws {
    let coordinator = LanguageModelToolApprovalCoordinator()
    let stream = await coordinator.updates()
    var updates = stream.makeAsyncIterator()
    #expect(await updates.next() == [])

    let request = approvalRequest(
        callID: "call-1",
        tool: "send_email",
        arguments: #"{"recipient":"person@example.com"}"#
    )
    let handler = coordinator.approvalHandler
    let decisionTask = Task {
        await handler(request)
    }

    let pending = try #require(await updates.next())
    let approval = try #require(pending.first)
    #expect(approval.request == request)
    #expect(approval.tool == "send_email")
    #expect(approval.arguments == #"{"recipient":"person@example.com"}"#)
    #expect(approval.provider == "test-provider")

    #expect(await coordinator.approve(approval.id))
    #expect(await decisionTask.value == .approved)
    #expect(await updates.next() == [])
    #expect(await coordinator.pendingApprovals.isEmpty)
    #expect(await !coordinator.approve(approval.id))
}

@Test
func approvalCoordinatorKeepsRequestsInArrivalOrder() async throws {
    let coordinator = LanguageModelToolApprovalCoordinator()
    let stream = await coordinator.updates()
    var updates = stream.makeAsyncIterator()
    _ = await updates.next()
    let handler = coordinator.approvalHandler

    let firstTask = Task {
        await handler(approvalRequest(callID: "first", tool: "write_file"))
    }
    let firstSnapshot = try #require(await updates.next())
    #expect(firstSnapshot.map(\.request.call.id) == ["first"])

    let secondTask = Task {
        await handler(approvalRequest(callID: "second", tool: "open_url"))
    }
    let secondSnapshot = try #require(await updates.next())
    #expect(secondSnapshot.map(\.request.call.id) == ["first", "second"])

    let second = try #require(secondSnapshot.last)
    #expect(await coordinator.deny(second.id))
    #expect(await secondTask.value == .denied)
    let remaining = try #require(await updates.next())
    #expect(remaining.map(\.request.call.id) == ["first"])

    let first = try #require(remaining.first)
    #expect(await coordinator.approve(first.id))
    #expect(await firstTask.value == .approved)
    #expect(await updates.next() == [])
}

@Test
func approvalCoordinatorDeniesCancelledRequests() async throws {
    let coordinator = LanguageModelToolApprovalCoordinator()
    let stream = await coordinator.updates()
    var updates = stream.makeAsyncIterator()
    _ = await updates.next()
    let handler = coordinator.approvalHandler

    let decisionTask = Task {
        await handler(approvalRequest(callID: "cancelled", tool: "delete_item"))
    }
    let pending = try #require(await updates.next())
    let approval = try #require(pending.first)

    decisionTask.cancel()

    #expect(await decisionTask.value == .denied)
    #expect(await updates.next() == [])
    #expect(await coordinator.pendingApprovals.isEmpty)
    #expect(await !coordinator.deny(approval.id))
}

@Test
func approvalCoordinatorPublishesSnapshotsToEveryObserver() async throws {
    let coordinator = LanguageModelToolApprovalCoordinator()
    let firstStream = await coordinator.updates()
    let secondStream = await coordinator.updates()
    var firstUpdates = firstStream.makeAsyncIterator()
    var secondUpdates = secondStream.makeAsyncIterator()
    _ = await firstUpdates.next()
    _ = await secondUpdates.next()
    let handler = coordinator.approvalHandler

    let decisionTask = Task {
        await handler(approvalRequest(callID: "shared", tool: "share_document"))
    }

    let firstSnapshot = try #require(await firstUpdates.next())
    let secondSnapshot = try #require(await secondUpdates.next())
    #expect(firstSnapshot == secondSnapshot)

    let approval = try #require(firstSnapshot.first)
    await coordinator.denyAll()
    #expect(await decisionTask.value == .denied)
    #expect(await firstUpdates.next() == [])
    #expect(await secondUpdates.next() == [])
    #expect(await !coordinator.approve(approval.id))
}
