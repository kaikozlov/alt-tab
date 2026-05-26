import Foundation

/// Pure lifecycle reconciliation helpers. Kept separate so the app/window sync rules are testable
/// without launching AppKit, AX, or WindowServer.
enum LifecycleReconciler {
    static func staleTrackedIds<T: Hashable>(trackedIds: Set<T>, runningIds: Set<T>) -> Set<T> {
        trackedIds.subtracting(runningIds)
    }

    static func staleWindowPids(windowPids: [pid_t], runningPids: Set<pid_t>) -> Set<pid_t> {
        Set(windowPids.filter { !runningPids.contains($0) })
    }

    static func selectedIndexAfterRemoval(currentIndex: Int, newCount: Int) -> Int? {
        guard newCount > 0 else { return nil }
        return min(currentIndex, newCount - 1)
    }
}
