import XCTest
@testable import MLXtra

final class PlainTextToolCallParserTests: XCTestCase {
    func testParsesSupportedToolCallWithQuotedAndBareArguments() throws {
        let parser = PlainTextToolCallParser(supportedNames: ["generate_music"])

        let call = try XCTUnwrap(parser.parse(
            response: #" generate_music(caption="lo-fi, piano", duration=12, instrumental=true, cfg=1.5, notes=null) "#
        ))

        XCTAssertEqual(call.name, "generate_music")
        XCTAssertEqual(call.arguments["caption"] as? String, "lo-fi, piano")
        XCTAssertEqual(call.arguments["duration"] as? Int, 12)
        XCTAssertEqual(call.arguments["instrumental"] as? Bool, true)
        XCTAssertEqual(call.arguments["cfg"] as? Double, 1.5)
        XCTAssertTrue(call.arguments["notes"] is NSNull)
    }

    func testParsesEscapedQuotedContent() throws {
        let arguments = try XCTUnwrap(PlainTextToolCallParser.parseArguments(#"text="line\n\"quoted\"" name='voice'"#))

        XCTAssertEqual(arguments["text"] as? String, "line\n\"quoted\"")
        XCTAssertEqual(arguments["name"] as? String, "voice")
    }

    func testRejectsMalformedArguments() {
        let parser = PlainTextToolCallParser(supportedNames: ["generate_image"])

        XCTAssertNil(parser.parse(response: #"generate_image(prompt="unfinished)"#))
        XCTAssertNil(parser.parse(response: "generate_image(prompt)"))
        XCTAssertNil(PlainTextToolCallParser.parseArguments(""))
    }

    func testIgnoresUnsupportedToolNames() {
        let parser = PlainTextToolCallParser(supportedNames: ["web_search"])

        XCTAssertNil(parser.parse(response: #"generate_image(prompt="lake")"#))
    }
}
