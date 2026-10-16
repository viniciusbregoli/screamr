import Foundation

/// Fn gesture rules, mirroring Wispr Flow's: hold to talk, double-tap or Fn+Space to lock
/// hands-free, Esc to cancel. Pure so it can be tested without an event tap.
struct PushToTalk {
    enum Action: Equatable { case none, start, lock, finish, cancel }

    /// Wispr's DICTATION_DEBOUNCE_DELAY: shorter holds count as taps.
    static let tapWindow: TimeInterval = 0.5

    private enum State: Equatable { case idle, holding(since: TimeInterval), awaitingSecondTap(releasedAt: TimeInterval), locked }
    private var state = State.idle

    var isActive: Bool { state != .idle }

    mutating func fnDown(at t: TimeInterval) -> Action {
        switch state {
        case .idle: state = .holding(since: t); return .start
        case .awaitingSecondTap: state = .locked; return .lock
        case .locked: state = .idle; return .finish
        case .holding: return .none
        }
    }

    mutating func fnUp(at t: TimeInterval) -> Action {
        guard case .holding(let since) = state else { return .none }
        if t - since >= Self.tapWindow { state = .idle; return .finish }
        state = .awaitingSecondTap(releasedAt: t)
        return .none
    }

    /// Call once tapWindow has passed after a short release; a lone tap is treated as accidental.
    mutating func tick(at t: TimeInterval) -> Action {
        guard case .awaitingSecondTap(let releasedAt) = state, t - releasedAt >= Self.tapWindow else { return .none }
        state = .idle
        return .cancel
    }

    /// Space while holding Fn locks hands-free. Returns true when the key should be swallowed.
    mutating func space() -> Bool {
        guard case .holding = state else { return false }
        state = .locked
        return true
    }

    /// Esc cancels any take in progress. Returns true when the key should be swallowed.
    mutating func escape() -> Bool {
        guard isActive else { return false }
        state = .idle
        return true
    }
}
