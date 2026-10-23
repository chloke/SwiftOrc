import Foundation

/// Records whether a tool that may change state began executing while one
/// router route was generating.
///
/// A route that fails after such a tool started must not be retried on
/// another route, because the replacement would run the tool again. Tools
/// whose metadata declares only read-only or computational effects do not
/// count.
package final class LanguageModelToolSideEffectTracker: @unchecked Sendable {
    @TaskLocal package static var current: LanguageModelToolSideEffectTracker?

    private let lock = NSLock()
    private let parent: LanguageModelToolSideEffectTracker?
    private var recorded = false

    package init(
        parent: LanguageModelToolSideEffectTracker? =
            LanguageModelToolSideEffectTracker.current
    ) {
        self.parent = parent
    }

    package var hasRecordedSideEffects: Bool {
        lock.withLock { recorded }
    }

    package func recordSideEffect() {
        lock.withLock { recorded = true }
        parent?.recordSideEffect()
    }

    package static func mayHaveSideEffects(
        _ metadata: LanguageModelToolMetadata
    ) -> Bool {
        metadata.effects.isEmpty
            || metadata.effects.contains(.localMutation)
            || metadata.effects.contains(.externalMutation)
    }
}
