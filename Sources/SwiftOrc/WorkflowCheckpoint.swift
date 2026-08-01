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
    public static var currentFormatVersion: Int { 1 }

    public let formatVersion: Int
    public let definitionID: WorkflowDefinitionID
    public let executionID: UUID
    public let state: State
    public let nextNode: NodeID
    public let attempt: Int
    public let steps: Int
    public let events: [WorkflowEvent]
    public let recoveries: [WorkflowRecovery]
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

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        maximumBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes

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
        try data.write(to: fileURL, options: .atomic)
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

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public enum JSONFileWorkflowCheckpointStoreError: Error, Sendable, Equatable {
    case invalidMaximumBytes
    case checkpointTooLarge(maximum: Int)
    case symbolicLinkNotAllowed
}
