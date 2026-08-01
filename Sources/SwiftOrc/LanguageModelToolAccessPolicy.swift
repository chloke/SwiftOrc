/// A stable, extensible category used to group related tools.
public struct LanguageModelToolCategory: RawRepresentable, Hashable, Codable,
    Sendable, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static let math: Self = "math"
    public static let text: Self = "text"
    public static let weather: Self = "weather"
    public static let localFiles: Self = "local-files"
    public static let location: Self = "location"
    public static let communication: Self = "communication"
    public static let financial: Self = "financial"
    public static let account: Self = "account"
}

/// The potential harm associated with invoking a tool correctly.
public enum LanguageModelToolRiskLevel: Int, Sendable, Equatable, Comparable,
    Codable, CaseIterable
{
    case minimal
    case low
    case moderate
    case high
    case critical

    /// Used when a developer has not yet classified a tool. It intentionally
    /// fails every ordinary maximum-risk threshold.
    case unclassified

    public static func < (
        lhs: LanguageModelToolRiskLevel,
        rhs: LanguageModelToolRiskLevel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The kind of observable effect a tool may have outside model inference.
public enum LanguageModelToolEffect: String, Sendable, Equatable, Hashable,
    Codable, CaseIterable
{
    case readOnly = "read-only"
    case localComputation = "local-computation"
    case localMutation = "local-mutation"
    case externalRead = "external-read"
    case externalMutation = "external-mutation"
}

/// Developer-supplied characteristics used by request-scoped access rules.
public struct LanguageModelToolMetadata: Sendable, Equatable, Codable {
    public var categories: Set<LanguageModelToolCategory>
    public var risk: LanguageModelToolRiskLevel
    public var effects: Set<LanguageModelToolEffect>

    public init(
        categories: Set<LanguageModelToolCategory> = [],
        risk: LanguageModelToolRiskLevel = .unclassified,
        effects: Set<LanguageModelToolEffect> = []
    ) {
        self.categories = categories
        self.risk = risk
        self.effects = effects
    }

    public static let unclassified = LanguageModelToolMetadata()
}

/// The authorization outcome for a tool matching an access rule.
public enum LanguageModelToolAuthorization: String, Sendable, Equatable,
    Codable
{
    case automatic
    case userApproval = "user-approval"
    case denied
}

/// What the tool loop does when user approval is denied or unavailable.
public enum LanguageModelToolDenialBehavior: String, Sendable, Equatable,
    Codable
{
    /// Stop execution with a structured workflow failure.
    case failWorkflow = "fail-workflow"

    /// Return a redacted tool error so the model can choose another approach.
    case returnToModel = "return-to-model"

    /// A provider-neutral denial result that intentionally excludes arguments,
    /// policy details, and application internals.
    public static let redactedModelResponse =
        #"{"error":{"code":"tool_authorization_denied","message":"The application did not authorize this tool call."}}"#
}

/// One ordered request-scoped rule. Every populated selector must match. Name,
/// category, and effect sets match when they share at least one value with the
/// registered tool. A rule with no selectors matches every tool.
public struct LanguageModelToolAccessRule: Sendable, Equatable, Codable {
    public var toolNames: Set<String>
    public var categories: Set<LanguageModelToolCategory>
    public var maximumRisk: LanguageModelToolRiskLevel?
    public var effects: Set<LanguageModelToolEffect>
    public var authorization: LanguageModelToolAuthorization

    public init(
        toolNames: Set<String> = [],
        categories: Set<LanguageModelToolCategory> = [],
        maximumRisk: LanguageModelToolRiskLevel? = nil,
        effects: Set<LanguageModelToolEffect> = [],
        authorization: LanguageModelToolAuthorization
    ) {
        self.toolNames = toolNames
        self.categories = categories
        self.maximumRisk = maximumRisk
        self.effects = effects
        self.authorization = authorization
    }

    public func matches(
        tool name: String,
        metadata: LanguageModelToolMetadata
    ) -> Bool {
        if !toolNames.isEmpty, !toolNames.contains(name) {
            return false
        }
        if !categories.isEmpty,
            categories.isDisjoint(with: metadata.categories)
        {
            return false
        }
        if let maximumRisk, metadata.risk > maximumRisk {
            return false
        }
        if !effects.isEmpty, effects.isDisjoint(with: metadata.effects) {
            return false
        }
        return true
    }
}

/// An ordered, request-scoped capability whitelist.
///
/// The first matching rule wins. Tools with a `.denied` result are not exposed
/// to the model. The default is intentionally deny-by-default whenever a policy
/// is supplied; omitting the policy preserves the legacy exposure behavior.
public struct LanguageModelToolAccessPolicy: Sendable, Equatable, Codable {
    public var rules: [LanguageModelToolAccessRule]
    public var defaultAuthorization: LanguageModelToolAuthorization
    public var denialBehavior: LanguageModelToolDenialBehavior

    public init(
        rules: [LanguageModelToolAccessRule],
        defaultAuthorization: LanguageModelToolAuthorization = .denied,
        denialBehavior: LanguageModelToolDenialBehavior = .failWorkflow
    ) {
        self.rules = rules
        self.defaultAuthorization = defaultAuthorization
        self.denialBehavior = denialBehavior
    }

    public func authorization(
        for tool: String,
        metadata: LanguageModelToolMetadata
    ) -> LanguageModelToolAuthorization {
        rules.first { $0.matches(tool: tool, metadata: metadata) }?
            .authorization ?? defaultAuthorization
    }
}
