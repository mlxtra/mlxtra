import XCTest
@testable import MLXHub

final class ToolTests: XCTestCase {

    // MARK: - Tool Cases

    func testToolAllCases() {
        let allCases = Tool.allCases
        XCTAssertEqual(allCases.count, 5)
        XCTAssertTrue(allCases.contains(.auto))
        XCTAssertTrue(allCases.contains(.image))
        XCTAssertTrue(allCases.contains(.tts))
        XCTAssertTrue(allCases.contains(.music))
        XCTAssertTrue(allCases.contains(.research))
    }

    func testToolRawValues() {
        XCTAssertEqual(Tool.auto.rawValue, "Auto")
        XCTAssertEqual(Tool.image.rawValue, "Create image")
        XCTAssertEqual(Tool.tts.rawValue, "Create speech")
        XCTAssertEqual(Tool.music.rawValue, "Create music")
        XCTAssertEqual(Tool.research.rawValue, "Deep research")
    }

    // MARK: - ID

    func testToolId() {
        XCTAssertEqual(Tool.auto.id, "Auto")
        XCTAssertEqual(Tool.image.id, "Create image")
        XCTAssertEqual(Tool.tts.id, "Create speech")
        XCTAssertEqual(Tool.music.id, "Create music")
        XCTAssertEqual(Tool.research.id, "Deep research")
    }

    // MARK: - Icon

    func testToolIcon() {
        XCTAssertEqual(Tool.auto.icon, "sparkle")
        XCTAssertEqual(Tool.image.icon, "photo")
        XCTAssertEqual(Tool.tts.icon, "waveform")
        XCTAssertEqual(Tool.music.icon, "music.note")
        XCTAssertEqual(Tool.research.icon, "magnifyingglass")
    }

    // MARK: - Subtitle

    func testToolSubtitle() {
        XCTAssertEqual(Tool.auto.subtitle, "Let the app decide")
        XCTAssertEqual(Tool.image.subtitle, "Generate or edit images")
        XCTAssertEqual(Tool.tts.subtitle, "Turn text into audio")
        XCTAssertEqual(Tool.music.subtitle, "Generate music locally")
        XCTAssertEqual(Tool.research.subtitle, "Use live web sources")
    }
}