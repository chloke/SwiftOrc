/// Safety limits applied to a workflow execution.
public struct WorkflowConfiguration: Sendable, Equatable, Codable {
    /// Maximum number of node executions in one workflow run.
    public var maximumSteps: Int

    /// Maximum retries allowed during one visit to a node.
    public var maximumRetriesPerNode: Int

    public init(
        maximumSteps: Int = 100,
        maximumRetriesPerNode: Int = 2
    ) {
        self.maximumSteps = maximumSteps
        self.maximumRetriesPerNode = maximumRetriesPerNode
    }

    public static let `default` = WorkflowConfiguration()
}
