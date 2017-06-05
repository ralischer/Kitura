import XCTest
@testable import K2Spike

class PathTests: XCTestCase {
    func testVerbs() {
        XCTAssertEqual(Verb(.GET)?.rawValue, "get")
        XCTAssertEqual(Verb(.PUT)?.rawValue, "put")
        XCTAssertEqual(Verb(.POST)?.rawValue, "post")
        XCTAssertEqual(Verb(.DELETE)?.rawValue, "delete")
        XCTAssertEqual(Verb(.OPTIONS)?.rawValue, "options")
        XCTAssertEqual(Verb(.HEAD)?.rawValue, "head")
        XCTAssertEqual(Verb(.PATCH)?.rawValue, "patch")
        XCTAssertNil(Verb(.UNKNOWN))
    }
}
