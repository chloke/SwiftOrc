import Foundation

/// A stable identifier and revision for checkpoint compatibility.
public struct WorkflowDefinitionID: RawRepresentable, Hashable, Sendable,
    Codable, ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String {
        rawValue
    }
}

/// A durable snapshot captured between workflow node executions.
public struct WorkflowCheckpoint<State: Sendable>: Sendable {
    /// Version 2 adds input requests and answers. Version 1 checkpoints are
    /// still accepted.
    public static var currentFormatVersion: Int { 2 }
    static var supportedFormatVersions: ClosedRange<Int> { 1...2 }

    public let formatVersion: Int
    public let definitionID: WorkflowDefinitionID
    public let executionID: UUID
    public let state: State
    public let nextNode: NodeID
    public let attempt: Int
    public let steps: Int
    public let events: [WorkflowEvent]
    public let recoveries: [WorkflowRecovery]
    /// The question the workflow is waiting on, if it suspended for input.
    public let pendingInput: WorkflowInputRequest?
    /// An answer not yet consumed by ``nextNode``.
    public let inputResponse: WorkflowInputResponse?
    public let createdAt: Date

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        definitionID: WorkflowDefinitionID,
        executionID: UUID,
        state: State,
        nextNode: NodeID,
        attempt: Int,
        steps: Int,
        events: [WorkflowEvent],
        recoveries: [WorkflowRecovery],
        pendingInput: WorkflowInputRequest? = nil,
        inputResponse: WorkflowInputResponse? = nil,
        createdAt: Date = Date()
    ) {
        self.formatVersion = formatVersion
        self.definitionID = definitionID
        self.executionID = executionID
        self.state = state
        self.nextNode = nextNode
        self.attempt = attempt
        self.steps = steps
        self.events = events
        self.recoveries = recoveries
        self.pendingInput = pendingInput
        self.inputResponse = inputResponse
        self.createdAt = createdAt
    }
}

extension WorkflowCheckpoint: Codable where State: Codable {}

/// Receives durable snapshots at safe boundaries between node executions.
public typealias WorkflowCheckpointHandler<State: Sendable> =
    @Sendable (
        WorkflowCheckpoint<State>
    ) async throws -> Void

/// Persists one Codable checkpoint as an atomically replaced JSON file.
public actor JSONFileWorkflowCheckpointStore<State: Codable & Sendable> {
    public let fileURL: URL
    public let maximumBytes: Int
    public let fileProtection: WorkflowFileProtection

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        maximumBytes: Int = 8 * 1_024 * 1_024,
        fileProtection: WorkflowFileProtection = .default
    ) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
        self.fileProtection = fileProtection

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func save(_ checkpoint: WorkflowCheckpoint<State>) throws {
        guard maximumBytes > 0 else {
            throw JSONFileWorkflowCheckpointStoreError.invalidMaximumBytes
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try encoder.encode(checkpoint)
        guard data.count <= maximumBytes else {
            throw JSONFileWorkflowCheckpointStoreError.checkpointTooLarge(
                maximum: maximumBytes
            )
        }
        try data.write(
            to: fileURL,
            options: [.atomic, fileProtection.writingOptions]
        )
    }

    public func load() throws -> WorkflowCheckpoint<State>? {
        guard maximumBytes > 0 else {
            throw JSONFileWorkflowCheckpointStoreError.invalidMaximumBytes
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let values = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true else {
            throw JSONFileWorkflowCheckpointStoreError.symbolicLinkNotAllowed
        }
        guard let fileSize = values.fileSize, fileSize <= maximumBytes else {
            throw JSONFileWorkflowCheckpointStoreError.checkpointTooLarge(
                maximum: maximumBytes
            )
        }
        return try decoder.decode(
            WorkflowCheckpoint<State>.self,
            from: Data(contentsOf: fileURL)
        )
    }

    /// A handler to pass as `onCheckpoint`, so every checkpoint, including
    /// one saved while waiting for input, is written automatically.
    public nonisolated var checkpointHandler: WorkflowCheckpointHandler<State> {
        { checkpoint in try await self.save(checkpoint) }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

@nonexhaustive
public enum JSONFileWorkflowCheckpointStoreError: Error, Sendable, Equatable {
    case invalidMaximumBytes
    case checkpointTooLarge(maximum: Int)
    case symbolicLinkNotAllowed
}
