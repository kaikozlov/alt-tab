import CoreGraphics
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func expectEqual(_ lhs: CGFloat, _ rhs: CGFloat, _ message: String) {
    expect(abs(lhs - rhs) < 0.001, message)
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

let session = SwitcherSession()
expect(session.beginPreparing(), "starts first preparation")
expect(!session.beginPreparing(), "rejects overlapping preparation")
session.endPreparing()
expect(session.beginPreparing(), "allows preparation after completion")
session.endPreparing()
expect(!session.shouldForceQuit(pid: 42), "first quit request is graceful")
expect(session.shouldForceQuit(pid: 42), "second quit request on same pid is forceful")
expect(!session.shouldForceQuit(pid: 43), "different pid resets quit escalation")

let empty = TileLayout.calculate(tileWidths: [], tileHeight: 50, maxWidth: 200, outerPadding: 10, interTilePadding: 5)
expect(empty.size == .zero, "empty layout has zero size")
expect(empty.frames.isEmpty, "empty layout has no frames")

let single = TileLayout.calculate(tileWidths: [100], tileHeight: 50, maxWidth: 200, outerPadding: 10, interTilePadding: 5)
expectEqual(single.size.width, 120, "single tile width includes outer padding")
expectEqual(single.size.height, 70, "single tile height includes outer padding")
expect(single.frames == [CGRect(x: 10, y: 10, width: 100, height: 50)], "single tile is placed at padding origin")

let row = TileLayout.calculate(tileWidths: [80, 90], tileHeight: 40, maxWidth: 220, outerPadding: 10, interTilePadding: 5)
expectEqual(row.size.width, 195, "same-row layout width uses row width plus padding")
expect(row.frames[0] == CGRect(x: 10, y: 10, width: 80, height: 40), "first same-row tile is at left padding")
expect(row.frames[1] == CGRect(x: 95, y: 10, width: 90, height: 40), "second same-row tile follows spacing")

let wrapped = TileLayout.calculate(tileWidths: [120, 120, 80], tileHeight: 40, maxWidth: 270, outerPadding: 10, interTilePadding: 5)
expectEqual(wrapped.size.width, 265, "wrapped layout width is widest row plus padding")
expectEqual(wrapped.size.height, 105, "wrapped layout height includes both rows and spacing")
expect(wrapped.frames[0] == CGRect(x: 10, y: 55, width: 120, height: 40), "first wrapped tile is on top row")
expect(wrapped.frames[2] == CGRect(x: 92.5, y: 10, width: 80, height: 40), "short wrapped row is centered")

print("Tests passed")
