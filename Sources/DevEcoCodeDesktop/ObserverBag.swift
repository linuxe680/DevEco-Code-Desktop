import Foundation

/// Owns `NotificationCenter` registrations and removes them when the owner is
/// deallocated.
///
/// `SessionStore` registers for app-activation and saved-permission changes in
/// `init()`. The blocks capture the store weakly, so the store still deallocates
/// normally — but without removal NotificationCenter keeps the blocks and the
/// registrations forever, and a recreated store would leave a stale set behind.
///
/// The bag is deliberately a plain class (not `@MainActor`) so its `deinit` can
/// run on any thread: `removeObserver` is thread-safe and the tokens are only
/// appended during `init()`.
final class NotificationObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
