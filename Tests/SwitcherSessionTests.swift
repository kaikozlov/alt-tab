func testSwitcherSession() {
    runTests("SwitcherSession") {
        let session = SwitcherSession()
        expect(session.beginSwitching(selectedIndex: 1), "starts switcher session")
        expect(!session.beginSwitching(selectedIndex: 0), "rejects overlapping switcher session")
        expect(session.isSwitching && session.selectedIndex == 1, "tracks selected index")
        session.cycleSelection(1, count: 3)
        expect(session.selectedIndex == 2, "cycles forward")
        session.cycleSelection(-1, count: 3)
        expect(session.selectedIndex == 1, "cycles backward")
        session.setSelectedIndex(99, count: 3)
        expect(session.selectedIndex == 2, "clamps high selection")
        session.setSelectedIndex(-5, count: 3)
        expect(session.selectedIndex == 0, "clamps low selection")
        session.setSelectedIndex(1, count: 0)
        expect(session.selectedIndex == 0, "zero count keeps index at zero")
        session.endSwitching()
        expect(!session.isSwitching, "ending switcher clears active state")
        expect(!session.shouldForceQuit(pid: 42), "first quit request is graceful")
        expect(session.shouldForceQuit(pid: 42), "second quit request on same pid is forceful")
        expect(!session.shouldForceQuit(pid: 43), "different pid resets quit escalation")
    }
}
