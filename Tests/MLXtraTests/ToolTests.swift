import XCTest
@testable import MLXtra

final class ToolTests: XCTestCase {


    func testToolAllCases() {
        let allCases = Tool.allCases
        XCTAssertEqual(allCases.count, 6)
        XCTAssertTrue(allCases.contains(.auto))
        XCTAssertTrue(allCases.contains(.chat))
        XCTAssertTrue(allCases.contains(.image))
        XCTAssertTrue(allCases.contains(.tts))
        XCTAssertTrue(allCases.contains(.music))
        XCTAssertTrue(allCases.contains(.research))
    }

    func testToolRawValues() {
        XCTAssertEqual(Tool.auto.rawValue, "Auto")
        XCTAssertEqual(Tool.chat.rawValue, "Chat")
        XCTAssertEqual(Tool.image.rawValue, "Image")
        XCTAssertEqual(Tool.tts.rawValue, "Speech")
        XCTAssertEqual(Tool.music.rawValue, "Music")
        XCTAssertEqual(Tool.research.rawValue, "Research")
    }


    func testToolId() {
        XCTAssertEqual(Tool.auto.id, "Auto")
        XCTAssertEqual(Tool.chat.id, "Chat")
        XCTAssertEqual(Tool.image.id, "Image")
        XCTAssertEqual(Tool.tts.id, "Speech")
        XCTAssertEqual(Tool.music.id, "Music")
        XCTAssertEqual(Tool.research.id, "Research")
    }


    func testToolIcon() {
        XCTAssertEqual(Tool.auto.icon, "sparkles")
        XCTAssertEqual(Tool.chat.icon, "bubble.left.and.bubble.right")
        XCTAssertEqual(Tool.image.icon, "photo")
        XCTAssertEqual(Tool.tts.icon, "waveform")
        XCTAssertEqual(Tool.music.icon, "music.note")
        XCTAssertEqual(Tool.research.icon, "magnifyingglass")
    }


    func testToolSubtitle() {
        XCTAssertEqual(Tool.auto.subtitle, "Let the app choose tools")
        XCTAssertEqual(Tool.chat.subtitle, "Plain local conversation")
        XCTAssertEqual(Tool.image.subtitle, "Create or edit images")
        XCTAssertEqual(Tool.tts.subtitle, "Turn text into speech")
        XCTAssertEqual(Tool.music.subtitle, "Create local music")
        XCTAssertEqual(Tool.research.subtitle, "Use live web sources")
    }
}
