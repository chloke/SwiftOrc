import Foundation

/// A stable, checkpoint-friendly identifier for data kept outside workflow
/// state.
public struct WorkflowArtifactID: RawRepresentable, Hashable, Sendable,
    Codable, ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }
}

/// Where an artifact entered or was produced by an application workflow.
public enum WorkflowArtifactSource: Sendable, Equatable, Codable {
    case userProvided
    case workflowNode(NodeID)
    case tool(String)
    case model(provider: String?)
    case external
}

/// A small, Codable reference to binary data managed by an artifact store.
///
/// The referenced bytes are deliberately not part of this value, which keeps
/// workflow state, checkpoints, traces, and errors from copying image data.
public struct WorkflowArtifact: Sendable, Equatable, Codable {
    public let id: WorkflowArtifactID
    public let mediaType: String
    public let byteCount: Int
    public let suggestedFilename: String?
    public let source: WorkflowArtifactSource
    public let metadata: [String: String]
    public let createdAt: Date

    public init(
        id: WorkflowArtifactID,
        mediaType: String,
        byteCount: Int,
        suggestedFilename: String? = nil,
        source: WorkflowArtifactSource,
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.suggestedFilename = suggestedFilename
        self.source = source
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

/// Metadata supplied when an application stores an artifact.
public struct WorkflowArtifactWriteOptions: Sendable, Equatable {
    public var mediaType: String
    public var suggestedFilename: String?
    public var source: WorkflowArtifactSource?
    public var metadata: [String: String]

    public init(
        mediaType: String,
        suggestedFilename: String? = nil,
        source: WorkflowArtifactSource? = nil,
        metadata: [String: String] = [:]
    ) {
        self.mediaType = mediaType
        self.suggestedFilename = suggestedFilename
        self.source = source
        self.metadata = metadata
    }
}

/// Capacity limits enforced before bytes enter a built-in artifact store.
public struct WorkflowArtifactStoreLimits: Sendable, Equatable {
    public var maximumArtifactBytes: Int
    public var maximumTotalBytes: Int

    public init(
        maximumArtifactBytes: Int = 20 * 1_024 * 1_024,
        maximumTotalBytes: Int = 100 * 1_024 * 1_024
    ) {
        self.maximumArtifactBytes = maximumArtifactBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    public static let `default` = WorkflowArtifactStoreLimits()
}

/// Predictable failures produced by the built-in artifact stores.
public enum WorkflowArtifactStoreError: Error, Sendable, Equatable {
    case notConfigured
    case invalidLimits
    case invalidMediaType(String)
    case artifactTooLarge(byteCount: Int, maximum: Int)
    case capacityExceeded(requested: Int, available: Int)
    case notFound(WorkflowArtifactID)
    case invalidIdentifier(WorkflowArtifactID)
    case descriptorMismatch(WorkflowArtifactID)
    case expectedImage(mediaType: String)
}

/// Application-selected storage for binary workflow inputs and outputs.
///
/// Implementations may use memory, files, a database, or another private
/// backing store. They must not log artifact bytes.
public protocol WorkflowArtifactStore: Sendable {
    func store(
        _ data: Data,
        options: WorkflowArtifactWriteOptions
    ) async throws -> WorkflowArtifact

    func data(for artifact: WorkflowArtifact) async throws -> Data

    func remove(_ artifact: WorkflowArtifact) async throws
}

/// A bounded artifact store suited to one process or one short workflow run.
public actor InMemoryWorkflowArtifactStore: WorkflowArtifactStore {
    public let limits: WorkflowArtifactStoreLimits

    private var entries: [WorkflowArtifactID: Data] = [:]
    private var totalBytes = 0

    public init(limits: WorkflowArtifactStoreLimits = .default) throws {
        try Self.validate(limits)
        self.limits = limits
    }

    public func store(
        _ data: Data,
        options: WorkflowArtifactWriteOptions
    ) throws -> WorkflowArtifact {
        try Self.validate(options.mediaType)
        try validateCapacity(for: data.count)

        let artifact = WorkflowArtifact(
            id: WorkflowArtifactID(rawValue: UUID().uuidString),
            mediaType: options.mediaType,
            byteCount: data.count,
            suggestedFilename: options.suggestedFilename,
            source: options.source ?? .external,
            metadata: options.metadata
        )
        entries[artifact.id] = data
        totalBytes += data.count
        return artifact
    }

    public func data(for artifact: WorkflowArtifact) throws -> Data {
        guard let data = entries[artifact.id] else {
            throw WorkflowArtifactStoreError.notFound(artifact.id)
        }
        guard data.count == artifact.byteCount else {
            throw WorkflowArtifactStoreError.descriptorMismatch(artifact.id)
        }
        return data
    }

    public func remove(_ artifact: WorkflowArtifact) {
        guard let removed = entries.removeValue(forKey: artifact.id) else {
            return
        }
        totalBytes -= removed.count
    }

    private func validateCapacity(for byteCount: Int) throws {
        guard byteCount <= limits.maximumArtifactBytes else {
            throw WorkflowArtifactStoreError.artifactTooLarge(
                byteCount: byteCount,
                maximum: limits.maximumArtifactBytes
            )
        }
        let available = limits.maximumTotalBytes - totalBytes
        guard byteCount <= available else {
            throw WorkflowArtifactStoreError.capacityExceeded(
                requested: byteCount,
                available: max(0, available)
            )
        }
    }

    private static func validate(_ limits: WorkflowArtifactStoreLimits) throws {
        guard limits.maximumArtifactBytes > 0,
            limits.maximumTotalBytes >= limits.maximumArtifactBytes
        else {
            throw WorkflowArtifactStoreError.invalidLimits
        }
    }

    private static func validate(_ mediaType: String) throws {
        guard WorkflowArtifactValidation.isValidMediaType(mediaType) else {
            throw WorkflowArtifactStoreError.invalidMediaType(mediaType)
        }
    }
}

/// A bounded file-backed store whose references remain usable after a workflow
/// checkpoint is restored with a store pointing at the same directory.
public actor DirectoryWorkflowArtifactStore: WorkflowArtifactStore {
    public let directoryURL: URL
    public let limits: WorkflowArtifactStoreLimits

    private var totalBytes: Int

    public init(
        directoryURL: URL,
        limits: WorkflowArtifactStoreLimits = .default
    ) throws {
        guard limits.maximumArtifactBytes > 0,
            limits.maximumTotalBytes >= limits.maximumArtifactBytes
        else {
            throw WorkflowArtifactStoreError.invalidLimits
        }
        self.directoryURL = directoryURL
        self.limits = limits

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        totalBytes = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).reduce(into: 0) { total, url in
            total +=
                try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                ?? 0
        }
    }

    public func store(
        _ data: Data,
        options: WorkflowArtifactWriteOptions
    ) throws -> WorkflowArtifact {
        guard WorkflowArtifactValidation.isValidMediaType(options.mediaType) else {
            throw WorkflowArtifactStoreError.invalidMediaType(options.mediaType)
        }
        guard data.count <= limits.maximumArtifactBytes else {
            throw WorkflowArtifactStoreError.artifactTooLarge(
                byteCount: data.count,
                maximum: limits.maximumArtifactBytes
            )
        }
        let available = limits.maximumTotalBytes - totalBytes
        guard data.count <= available else {
            throw WorkflowArtifactStoreError.capacityExceeded(
                requested: data.count,
                available: max(0, available)
            )
        }

        let artifact = WorkflowArtifact(
            id: WorkflowArtifactID(rawValue: UUID().uuidString),
            mediaType: options.mediaType,
            byteCount: data.count,
            suggestedFilename: options.suggestedFilename,
            source: options.source ?? .external,
            metadata: options.metadata
        )
        try data.write(to: try fileURL(for: artifact.id), options: .atomic)
        totalBytes += data.count
        return artifact
    }

    public func data(for artifact: WorkflowArtifact) throws -> Data {
        let url = try fileURL(for: artifact.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkflowArtifactStoreError.notFound(artifact.id)
        }
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true,
            values.fileSize == artifact.byteCount
        else {
            throw WorkflowArtifactStoreError.descriptorMismatch(artifact.id)
        }
        guard artifact.byteCount <= limits.maximumArtifactBytes else {
            throw WorkflowArtifactStoreError.artifactTooLarge(
                byteCount: artifact.byteCount,
                maximum: limits.maximumArtifactBytes
            )
        }
        let data = try Data(contentsOf: url)
        guard data.count == artifact.byteCount else {
            throw WorkflowArtifactStoreError.descriptorMismatch(artifact.id)
        }
        return data
    }

    public func remove(_ artifact: WorkflowArtifact) throws {
        let url = try fileURL(for: artifact.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let byteCount =
            (try? url.resourceValues(forKeys: [.fileSizeKey])
                .fileSize) ?? 0
        try FileManager.default.removeItem(at: url)
        totalBytes = max(0, totalBytes - byteCount)
    }

    private func fileURL(for id: WorkflowArtifactID) throws -> URL {
        guard UUID(uuidString: id.rawValue) != nil else {
            throw WorkflowArtifactStoreError.invalidIdentifier(id)
        }
        return directoryURL.appendingPathComponent(id.rawValue, isDirectory: false)
    }
}

private enum WorkflowArtifactValidation {
    static func isValidMediaType(_ value: String) -> Bool {
        guard !value.isEmpty,
            !value.contains(where: { $0.isWhitespace }),
            let separator = value.firstIndex(of: "/"),
            separator != value.startIndex,
            value.index(after: separator) != value.endIndex
        else {
            return false
        }
        return true
    }
}
