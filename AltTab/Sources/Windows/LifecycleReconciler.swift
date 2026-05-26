import Foundation

/// Pure lifecycle reconciliation helpers. Kept separate so the app/window sync rules are testable
/// without launching AppKit, AX, or WindowServer.
enum LifecycleReconciler {
    static func staleWindowPids(windowPids: [pid_t], runningPids: Set<pid_t>) -> Set<pid_t> {
        Set(windowPids.filter { !runningPids.contains($0) })
    }
}
