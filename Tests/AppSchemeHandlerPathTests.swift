import XCTest
@testable import Droplis

final class AppSchemeHandlerPathTests: XCTestCase {
    func testSchemeConstantsStayStable() {
        XCTAssertEqual(AppSchemeHandler.scheme, "app")
        XCTAssertEqual(AppSchemeHandler.host, "local")
    }
}
