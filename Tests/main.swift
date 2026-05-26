import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

expect(LifecycleReconciler.staleTrackedIds(trackedIds: Set([1, 2, 3]), runningIds: Set([1, 3])) == Set([2]),
       "removes tracked apps missing from running app identities")
expect(LifecycleReconciler.staleTrackedIds(trackedIds: Set([1, 2]), runningIds: Set([1, 2, 3])) == Set<Int>(),
       "does not remove tracked apps that are still running")
expect(LifecycleReconciler.staleWindowPids(windowPids: [10, 20, 20, 30], runningPids: Set([10, 30])) == Set<pid_t>([20]),
       "removes orphan windows whose pid no longer exists")
expect(LifecycleReconciler.selectedIndexAfterRemoval(currentIndex: 3, newCount: 3) == 2,
       "clamps selected index after removing later item")
expect(LifecycleReconciler.selectedIndexAfterRemoval(currentIndex: 0, newCount: 0) == nil,
       "nil selected index when all windows are removed")

print("LifecycleReconcilerTests passed")
