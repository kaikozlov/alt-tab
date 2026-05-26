import Foundation

/// Small state holder for switcher preparation, refresh, and repeated quit behavior.
/// Keeps AppDelegate focused on wiring instead of state transitions.
final class SwitcherSession {
    private(set) var isPreparing = false
    private(set) var isRefreshing = false
    private var lastQuitPid: pid_t = 0

    func beginPreparing() -> Bool {
        guard !isPreparing else { return false }
        isPreparing = true
        return true
    }

    func endPreparing() {
        isPreparing = false
    }

    func beginRefreshing() -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        return true
    }

    func endRefreshing() {
        isRefreshing = false
    }

    func shouldForceQuit(pid: pid_t) -> Bool {
        guard lastQuitPid != pid else { return true }
        lastQuitPid = pid
        return false
    }
}
