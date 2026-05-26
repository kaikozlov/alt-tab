import Foundation

final class SwitcherSession {
    private(set) var isSwitching = false
    private(set) var selectedIndex = 0
    private var lastQuitPid: pid_t = 0

    func beginSwitching(selectedIndex: Int) -> Bool {
        guard !isSwitching else { return false }
        isSwitching = true
        self.selectedIndex = selectedIndex
        return true
    }

    func endSwitching() {
        isSwitching = false
        selectedIndex = 0
    }

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
