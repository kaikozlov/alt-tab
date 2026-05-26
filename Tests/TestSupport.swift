import CoreGraphics
import Foundation

nonisolated(unsafe) var testFailures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    guard condition() else {
        testFailures += 1
        let name = (file as NSString).lastPathComponent
        fputs("FAIL \(name):\(line): \(message)\n", stderr)
        return
    }
}

func expectEqual(_ lhs: CGFloat, _ rhs: CGFloat, _ message: String, file: String = #file, line: Int = #line) {
    expect(abs(lhs - rhs) < 0.001, message, file: file, line: line)
}

func runTests(_ name: String, _ block: () -> Void) {
    block()
}

func finishTests() -> Never {
    guard testFailures == 0 else {
        fputs("\(testFailures) test(s) failed\n", stderr)
        exit(1)
    }
    print("All tests passed")
    exit(0)
}
