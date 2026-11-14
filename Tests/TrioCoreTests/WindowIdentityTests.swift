import CoreGraphics
import XCTest
@testable import TrioCore

final class WindowIdentityTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 25, width: 1440, height: 850)
    private let centers = [CGPoint(x: 20, y: 45), CGPoint(x: 40, y: 45), CGPoint(x: 60, y: 45)]
    private func window(_ id: UInt32, pid: Int32 = 100, frame: CGRect? = nil) -> VisibleWindowIdentity {
        VisibleWindowIdentity(id: id, pid: pid, frame: frame ?? self.frame)
    }
    private func resolve(_ windows: [VisibleWindowIdentity], verified: Bool = false,
                         centers: [CGPoint]? = nil) -> UInt32? {
        WindowIdentity.resolve(windows: windows, pid: 100, frame: frame,
                               controlCenters: centers ?? self.centers, ignoredPID: 999,
                               coincidentControlsVerified: verified)
    }
    func testUniqueGeometryRetainsExistingMatch() {
        XCTAssertEqual(resolve([window(2), window(1, frame: frame.offsetBy(dx: 80, dy: 30))]), 2)
    }
    func testCoincidentMaximizedWindowsRequireIndependentAXProof() {
        XCTAssertNil(resolve([window(2), window(1)]))
    }
    func testVerifiedCoincidentWindowsUseFrontToBackOrder() {
        XCTAssertEqual(resolve([window(2), window(1)], verified: true), 2)
        XCTAssertEqual(resolve([window(1), window(2)], verified: true), 1)
    }
    func testThreeCoincidentWindowsSelectOnlyTheFrontOne() {
        XCTAssertEqual(resolve([window(3), window(2), window(1)], verified: true), 3)
    }
    func testAnotherApplicationCoveringTheControlsPreventsAmbiguousSelection() {
        XCTAssertNil(resolve([window(8, pid: 200), window(2), window(1)], verified: true))
    }
    func testControlsSplitAcrossWindowsCannotEstablishOneIdentity() {
        let partial = window(8, pid: 200, frame: CGRect(x: 0, y: 25, width: 30, height: 60))
        XCTAssertNil(resolve([partial, window(2), window(1)], verified: true))
    }
    func testOwnOverlayDoesNotChangeTheApplicationsWindowOrder() {
        XCTAssertEqual(resolve([window(9, pid: 999), window(2), window(1)], verified: true), 2)
    }
    func testMissingAndInvalidControlCoordinatesFailClosed() {
        XCTAssertNil(resolve([window(2), window(1)], verified: true, centers: []))
        XCTAssertNil(resolve([window(2), window(1)], verified: true,
                             centers: [CGPoint(x: -1, y: 45), centers[1], centers[2]]))
        XCTAssertNil(resolve([window(9, pid: 200)], verified: true))
    }
}
