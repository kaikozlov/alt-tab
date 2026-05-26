import Foundation

@MainActor
final class Throttler {
    private let delayInNanoseconds: UInt64
    private var lastTimeInNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var nextScheduled = false

    init(delayInMs: Int) {
        delayInNanoseconds = UInt64(delayInMs) * 1_000_000
    }

    func throttleOrProceed(_ block: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = DispatchTime.now().uptimeNanoseconds
        let (elapsed, overflow) = now.subtractingReportingOverflow(lastTimeInNanoseconds)
        if !overflow, elapsed >= delayInNanoseconds {
            lastTimeInNanoseconds = now
            block()
            return
        }
        guard !nextScheduled else { return }
        nextScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delayInNanoseconds) + 10_000_000)) { [self] in
            nextScheduled = false
            throttleOrProceed(block)
        }
    }
}
