import Foundation
import SwiftOrc

/// A consistent snapshot captured by ``WorkflowProbe``.
public struct WorkflowProbeSnapshot<State: Sendable>: Sendable {
    public let events: [WorkflowEvent]
    public let checkpoints: [WorkflowCheckpoint<State>]

    /// Counts executions of a node, including retries.
    public func startCount(for node: NodeID) -> Int {
        events.reduce(into: 0) { count, event in
            if case let .nodeStarted(startedNode, _, _) = event,
                startedNode == node
            {
                count += 1
            }
        }
    }

    /// Returns the named routes selected by one branch node in event order.
    public func selectedRoutes(for node: NodeID) -> [String] {
        events.compactMap { event in
            guard case let .branchSelected(selectedNode, route, _) = event,
                selectedNode == node
            else {
                return nil
            }
            return route
        }
    }

    /// Returns fallback targets selected from one node in event order.
    public func fallbackTargets(from node: NodeID) -> [NodeID] {
        events.compactMap { event in
            guard case let .fallbackSelected(selectedNode, target, _) = event,
                selectedNode == node
            else {
                return nil
            }
            return target
        }
    }
}

/// Records workflow events and checkpoints for deterministic assertions.
///
/// A probe owns concurrency-safe storage and exposes handlers with the exact
/// signatures accepted by `Workflow.run`.
public final class WorkflowProbe<State: Sendable>: Sendable {
    private let storage = WorkflowProbeStorage<State>()

    public init() {}

    public var eventHandler: WorkflowEventHandler {
        { [storage] event in
            await storage.record(event)
        }
    }

    public var checkpointHandler: WorkflowCheckpointHandler<State> {
        { [storage] checkpoint in
            await storage.record(checkpoint)
        }
    }

    /// Returns all observations made so far without clearing the probe.
    public func snapshot() async -> WorkflowProbeSnapshot<State> {
        await storage.snapshot()
    }

    /// Clears every recorded event and checkpoint.
    public func reset() async {
        await storage.reset()
    }
}

private actor WorkflowProbeStorage<State: Sendable> {
    private var events: [WorkflowEvent] = []
    private var checkpoints: [WorkflowCheckpoint<State>] = []

    func record(_ event: WorkflowEvent) {
        events.append(event)
    }

    func record(_ checkpoint: WorkflowCheckpoint<State>) {
        checkpoints.append(checkpoint)
    }

    func snapshot() -> WorkflowProbeSnapshot<State> {
        WorkflowProbeSnapshot(events: events, checkpoints: checkpoints)
    }

    func reset() {
        events.removeAll(keepingCapacity: true)
        checkpoints.removeAll(keepingCapacity: true)
    }
}
