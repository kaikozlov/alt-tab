import Foundation

final class SwitcherSession {
    private(set) var isPreparing = false
    private(set) var isRefreshing = false
    private(set) var isSwitching = false
    private(set) var generation = 0
    private(set) var selectedIndex = 0
    private var lastQuitPid: pid_t = 0

    func beginSwitching(selectedIndex: Int) -> Bool {
        guard !isSwitching else { return false }
        isSwitching = true; isPreparing = true; generation += 1; self.selectedIndex = selectedIndex
        return true
    }

    func endSwitching() {
        isSwitching = false; isPreparing = false; isRefreshing = false; selectedIndex = 0; generation += 1
    }

    func beginPreparing() -> Bool {
        guard !isPreparing else { return false }
        isPreparing = true
        return true
    }

    func endPreparing() { isPreparing = false }

    func beginRefreshing() -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        return true
    }

    func endRefreshing() { isRefreshing = false }

    func setSelectedIndex(_ index: Int, count: Int) {
        selectedIndex = count > 0 ? min(max(index, 0), count - 1) : 0
    }

    func cycleSelection(_ step: Int, count: Int) {
        selectedIndex = count > 0 ? (selectedIndex + step + count) % count : 0
    }

    func shouldForceQuit(pid: pid_t) -> Bool {
        guard lastQuitPid != pid else { return true }
        lastQuitPid = pid
        return false
    }
}
