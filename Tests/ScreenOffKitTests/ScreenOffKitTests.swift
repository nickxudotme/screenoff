import XCTest
@testable import ScreenOffKit

final class ScreenOffKitTests: XCTestCase {
    func testParsesLegacyDisplayLine() throws {
        let item = try XCTUnwrap(DisplayParser.parseLegacyLine("#2 id=123456789 enabled 2560x1440+0+0 online Studio Display"))

        XCTAssertEqual(item.index, 2)
        XCTAssertEqual(item.id, 123456789)
        XCTAssertEqual(item.state, "enabled")
        XCTAssertEqual(item.geometry, "2560x1440+0+0")
        XCTAssertEqual(item.flags, ["online"])
        XCTAssertEqual(item.name, "Studio Display")
    }

    func testParsesLegacyDisplayLineWithMultipleFlags() throws {
        let item = try XCTUnwrap(DisplayParser.parseLegacyLine("#1 id=42 active 1728x1117+0+0 main, built-in, online Built-in Display"))

        XCTAssertTrue(item.isMain)
        XCTAssertTrue(item.isBuiltIn)
        XCTAssertEqual(item.flags, ["main", "built-in", "online"])
        XCTAssertEqual(item.displayTitle, "Built-in Display")
    }

    func testDecodesDisplayJSON() throws {
        let data = """
        [
          {
            "index": 1,
            "id": 42,
            "name": "Built-in Display",
            "state": "active",
            "geometry": "1728x1117+0+0",
            "flags": ["main", "built-in", "online"]
          }
        ]
        """.data(using: .utf8)!

        let items = try DisplayParser.parseJSON(data)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, 42)
        XCTAssertTrue(items[0].isMain)
    }
}
