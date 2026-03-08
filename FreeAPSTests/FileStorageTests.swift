@testable import FreeAPS
import XCTest

class FileStorageTests: XCTestCase {
    let fileStorage = BaseFileStorage()

    struct DummyObject: JSON {
        let id: String
        let value: Decimal
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
}

final class PumpViewTests: XCTestCase {
    func testFallbackPumpLabel_OmniOnboarded_ShowsPod() {
        let label = PumpView.fallbackPumpLabel(
            pumpName: "Omnipod DASH",
            isOnboarded: true,
            hasExpirationDate: false,
            hasReservoir: false
        )
        XCTAssertEqual(label, "Pod")
    }

    func testFallbackPumpLabel_OmniNotOnboarded_ShowsNoPod() {
        let label = PumpView.fallbackPumpLabel(
            pumpName: "Omnipod DASH",
            isOnboarded: false,
            hasExpirationDate: false,
            hasReservoir: false
        )
        XCTAssertEqual(label, "No Pod")
    }

    func testFallbackPumpLabel_WithExpiration_ShowsNoFallback() {
        let label = PumpView.fallbackPumpLabel(
            pumpName: "Omnipod DASH",
            isOnboarded: true,
            hasExpirationDate: true,
            hasReservoir: true
        )
        XCTAssertNil(label)
    }
}
