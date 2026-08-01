/// A stable, sendable description of a workflow's declared topology.
public struct WorkflowGraphDescription: Sendable, Equatable, Codable {
    public let definitionID: WorkflowDefinitionID
    public let initialNode: NodeID
    public let nodes: [WorkflowGraphNodeDescription]
    public let configuration: WorkflowConfiguration

    public init(
        definitionID: WorkflowDefinitionID,
        initialNode: NodeID,
        nodes: [WorkflowGraphNodeDescription],
        configuration: WorkflowConfiguration
    ) {
        self.definitionID = definitionID
        self.initialNode = initialNode
        self.nodes = nodes
        self.configuration = configuration
    }
}

/// One node and its statically declared outgoing destinations.
public struct WorkflowGraphNodeDescription: Sendable, Equatable, Codable {
    public let id: NodeID
    public let destinations: [NodeID]

    public init(id: NodeID, destinations: [NodeID]) {
        self.id = id
        self.destinations = destinations
    }
}

public extension Workflow {
    /// The statically declared graph, suitable for diagnostics and developer UI.
    /// Dynamic destinations cannot be represented until runtime.
    var declaredGraph: WorkflowGraphDescription {
        let descriptions = nodes.values.map { node in
            WorkflowGraphNodeDescription(
                id: node.id,
                destinations: node.declaredDestinations.sorted {
                    $0.rawValue < $1.rawValue
                }
            )
        }.sorted { $0.id.rawValue < $1.id.rawValue }

        return WorkflowGraphDescription(
            definitionID: definitionID,
            initialNode: initialNode,
            nodes: descriptions,
            configuration: configuration
        )
    }
}
