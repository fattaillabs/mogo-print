import Foundation
import MogoCore
import XCTest

final class UpdateCheckTests: XCTestCase {
    func testCompareVersions() {
        XCTAssertTrue(UpdateCheck.isNewer("0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.10.0", than: "0.9.9"))        // 숫자 마디로 비교
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.2", than: "0.2.0"))           // 빈 마디는 0
        XCTAssertFalse(UpdateCheck.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.3.0", than: "0.3.0-beta"))     // 정식판이 시험판보다 새것
        XCTAssertFalse(UpdateCheck.isNewer("0.3.0-beta", than: "0.3.0"))
        XCTAssertEqual(UpdateCheck.normalized(" v1.2.3 "), "1.2.3")
    }

    private func json(tag: String = "v0.3.0", draft: Bool = false, pre: Bool = false) -> Data {
        Data("""
        {"tag_name": "\(tag)", "name": "모고 프린트 0.3.0", "draft": \(draft), "prerelease": \(pre),
         "html_url": "https://github.com/fattaillabs/mogo-print/releases/tag/\(tag)",
         "body": "## 바뀐 점\\n- 자동 업데이트",
         "assets": [
           {"name": "MogoPrint.dmg", "size": 3258415, "browser_download_url": "https://github.com/fattaillabs/mogo-print/releases/download/\(tag)/MogoPrint.dmg"},
           {"name": "MogoPrint-windows-x64.zip", "size": 63360674, "browser_download_url": "https://github.com/fattaillabs/mogo-print/releases/download/\(tag)/MogoPrint-windows-x64.zip"}
         ]}
        """.utf8)
    }

    func testParseRelease() throws {
        let r = try XCTUnwrap(try UpdateCheck.parse(json()))
        XCTAssertEqual(r.version, "0.3.0")
        XCTAssertEqual(r.notes, "## 바뀐 점\n- 자동 업데이트")
        XCTAssertEqual(r.page.absoluteString, "https://github.com/fattaillabs/mogo-print/releases/tag/v0.3.0")
        XCTAssertEqual(r.assets[UpdateCheck.macAssetName]?.lastPathComponent, "MogoPrint.dmg")
        XCTAssertEqual(r.sizes[UpdateCheck.macAssetName], 3258415)
        XCTAssertNotNil(r.assets["MogoPrint-windows-x64.zip"])
    }

    func testDraftsAndPrereleasesAreNotUpdates() throws {
        XCTAssertNil(try UpdateCheck.parse(json(draft: true)))
        XCTAssertNil(try UpdateCheck.parse(json(pre: true)))
        XCTAssertThrowsError(try UpdateCheck.parse(Data("<html>rate limited</html>".utf8)))
    }

    /// 시험용 file:// 주소에서도 읽는다(앱의 MOGO_UPDATE_FEED).
    func testLatestFromFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mogo-feed-\(UUID().uuidString).json")
        try json(tag: "v9.9.9").write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try await UpdateCheck.latest(from: url)
        XCTAssertEqual(r?.version, "9.9.9")
    }

    /// 실제 GitHub 최신 릴리스. MOGO_NETWORK_TESTS=1일 때만.
    func testLiveLatestRelease() async throws {
        guard ProcessInfo.processInfo.environment["MOGO_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("MOGO_NETWORK_TESTS=1일 때만 GitHub에 접속한다")
        }
        let r = try await XCTUnwrapAsync(try await UpdateCheck.latest(from: UpdateCheck.latestURL))
        XCTAssertFalse(r.version.isEmpty)
        XCTAssertNotNil(r.assets[UpdateCheck.macAssetName], "릴리스에 MogoPrint.dmg가 없음")
    }

    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }
}
