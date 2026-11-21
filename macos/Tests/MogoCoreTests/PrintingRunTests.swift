@testable import MogoCore
import XCTest

/// CUPS 명령 실행: 시간 제한과 붙을 곳.
final class PrintingRunTests: XCTestCase {
    func testRunReturnsOutput() {
        let r = Printing.run("/bin/echo", ["모고"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.output, "모고\n")
        XCTAssertFalse(r.timedOut)
    }

    func testRunStopsHangingCommand() {
        // lp가 CUPS 응답을 끝없이 기다리던 경우처럼 끝나지 않는 명령은 시간이 지나면 멈춘다.
        let start = Date()
        let r = Printing.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunReadsLargeOutputWithoutDeadlock() {
        // 파이프 버퍼(64KB)보다 큰 출력도 끝까지 읽는다.
        let r = Printing.run("/bin/sh", ["-c", "yes a | head -c 300000"], timeout: 10)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.output.count, 300000)
    }

    func testCanConnectRefusedPort() {
        XCTAssertFalse(Printing.canConnect(port: 9))
    }
}
