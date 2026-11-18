import Foundation

/// The data-protection class applied to files the built-in checkpoint and
/// artifact stores write.
///
/// Protection is enforced by iOS, iPadOS, and visionOS; macOS ignores it. The
/// default keeps files readable after the device is first unlocked, so
/// workflows can resume in the background while the device is locked. Use
/// ``complete`` when files only need to be read while the app is in use.
public struct WorkflowFileProtection: Sendable, Hashable {
    let writingOptionsRawValue: UInt

    private init(_ options: Data.WritingOptions) {
        writingOptionsRawValue = options.rawValue
    }

    var writingOptions: Data.WritingOptions {
        Data.WritingOptions(rawValue: writingOptionsRawValue)
    }

    /// Readable only while the device is unlocked.
    public static let complete = WorkflowFileProtection(.completeFileProtection)

    /// Files already open stay readable after the device locks; new files can
    /// be written while locked.
    public static let completeUnlessOpen = WorkflowFileProtection(
        .completeFileProtectionUnlessOpen
    )

    /// Readable after the device is first unlocked until it restarts. The
    /// default.
    public static let completeUntilFirstUserAuthentication = WorkflowFileProtection(
        .completeFileProtectionUntilFirstUserAuthentication
    )

    /// No data protection.
    public static let unprotected = WorkflowFileProtection(.noFileProtection)

    public static let `default` = completeUntilFirstUserAuthentication
}
