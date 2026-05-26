import Darwin

func testLifecycleReconciler() {
    runTests("LifecycleReconciler") {
        expect(LifecycleReconciler.staleWindowPids(windowPids: [10, 20, 20, 30], runningPids: Set([10, 30])) == Set<pid_t>([20]),
               "flags pids with no running app")
        expect(LifecycleReconciler.staleWindowPids(windowPids: [], runningPids: Set([1])) == [],
               "empty window list has no stale pids")
        expect(LifecycleReconciler.staleWindowPids(windowPids: [5, 5], runningPids: Set([5])) == [],
               "all window pids still running")
    }
}
