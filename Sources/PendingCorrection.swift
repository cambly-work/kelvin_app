import Foundation

/// Identifiable record of an automatic typo correction that can be undone or accepted.
/// Owns a unique ID so that a stale HUD cannot accidentally affect a newer correction,
/// and a status so that repeated undo/accept calls are safely no-ops.
struct PendingCorrection: Equatable {
    let id: UUID
    let original: String
    let corrected: String
    let bundleID: String?
    let createdAt: Date
    var status: Status

    enum Status: Equatable {
        case pending, accepted, restored, invalidated
    }

    var isActive: Bool { status == .pending }

    /// Elapsed time since the correction was applied.
    var age: TimeInterval { Date().timeIntervalSince(createdAt) }
}
