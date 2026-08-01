/// Builds a workflow's node collection using declarative Swift syntax.
@resultBuilder
public enum WorkflowBuilder<State: Sendable> {
    public static func buildExpression(
        _ expression: AnyWorkflowNode<State>
    ) -> [AnyWorkflowNode<State>] {
        [expression]
    }

    public static func buildExpression<Node: WorkflowNode>(
        _ expression: Node
    ) -> [AnyWorkflowNode<State>] where Node.State == State {
        [AnyWorkflowNode(expression)]
    }

    public static func buildExpression(
        _ expression: WorkflowComponent<State>
    ) -> [AnyWorkflowNode<State>] {
        expression.nodes
    }

    public static func buildBlock(
        _ components: [AnyWorkflowNode<State>]...
    ) -> [AnyWorkflowNode<State>] {
        components.flatMap { $0 }
    }

    public static func buildOptional(
        _ component: [AnyWorkflowNode<State>]?
    ) -> [AnyWorkflowNode<State>] {
        component ?? []
    }

    public static func buildEither(
        first component: [AnyWorkflowNode<State>]
    ) -> [AnyWorkflowNode<State>] {
        component
    }

    public static func buildEither(
        second component: [AnyWorkflowNode<State>]
    ) -> [AnyWorkflowNode<State>] {
        component
    }

    public static func buildArray(
        _ components: [[AnyWorkflowNode<State>]]
    ) -> [AnyWorkflowNode<State>] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(
        _ component: [AnyWorkflowNode<State>]
    ) -> [AnyWorkflowNode<State>] {
        component
    }
}
