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
    func testUniqueGeometrySupportsOneOrTwoExposedControls() {
        XCTAssertEqual(resolve([window(2)], centers: Array(centers.prefix(1))), 2)
        XCTAssertEqual(resolve([window(2)], centers: Array(centers.prefix(2))), 2)
    }
    func testCoincidentPartialControlsStillRequireIndependentAXProof() {
        for partial in [Array(centers.prefix(1)), [centers[0], centers[2]]] {
            XCTAssertNil(resolve([window(2), window(1)], centers: partial))
            XCTAssertEqual(resolve([window(2), window(1)], verified: true, centers: partial), 2)
            XCTAssertNil(resolve([window(8, pid: 200), window(2), window(1)], verified: true, centers: partial))
        }
    }
    func testTwoExposedControlsCannotBeSplitAcrossCoveringWindows() {
        let partial = window(8, pid: 200, frame: CGRect(x: 0, y: 25, width: 30, height: 60))
        XCTAssertNil(resolve([partial, window(2), window(1)], verified: true, centers: [centers[0], centers[2]]))
    }
    func testDuplicateUnorderedExcessAndNonfiniteCentersDoNotProveIdentity() {
        for malformed in [[centers[0], centers[0]], [centers[2], centers[0]],
                          centers + [CGPoint(x: 80, y: 45)], [CGPoint(x: CGFloat.nan, y: 45)]] {
            XCTAssertNil(resolve([window(2), window(1)], verified: true, centers: malformed))
        }
    }
    func testNegativeRawWindowDimensionsAndInvalidWindowListsFailClosed() {
        XCTAssertNil(WindowIdentity.resolve(windows: [window(2)], pid: 100,
            frame: CGRect(x: 1440, y: 25, width: -1440, height: 850), controlCenters: [centers[0]], ignoredPID: 999))
        XCTAssertNil(resolve([window(2, frame: CGRect(x: 1440, y: 25, width: -1440, height: 850))], centers: [centers[0]]))
        XCTAssertNil(resolve([window(0)], centers: [centers[0]]))
    }
    func testNonmodalAuxiliaryWindowsNeedAnExposedCloseButton() {
        for subrole in ["AXDialog", "AXFloatingWindow"] {
            XCTAssertTrue(WindowIdentity.supportsWindow(role: "AXWindow", subrole: subrole, isModal: false, hasCloseButton: true))
            XCTAssertFalse(WindowIdentity.supportsWindow(role: "AXWindow", subrole: subrole, isModal: false, hasCloseButton: false))
            XCTAssertFalse(WindowIdentity.supportsWindow(role: "AXWindow", subrole: subrole, isModal: nil, hasCloseButton: true))
            XCTAssertFalse(WindowIdentity.supportsWindow(role: "AXWindow", subrole: subrole, isModal: true, hasCloseButton: true))
        }
    }
    func testModalSystemAndSheetWindowsAreNotReclassifiedByTheirCloseButton() {
        XCTAssertTrue(WindowIdentity.supportsWindow(role: "AXWindow", subrole: "AXStandardWindow", isModal: false, hasCloseButton: true))
        XCTAssertFalse(WindowIdentity.supportsWindow(role: "AXWindow", subrole: "AXStandardWindow", isModal: true, hasCloseButton: true))
        for subrole in ["AXSystemDialog", "AXSystemFloatingWindow", "AXUnknown", "AXSheet"] {
            XCTAssertFalse(WindowIdentity.supportsWindow(role: "AXWindow", subrole: subrole, isModal: false, hasCloseButton: true))
        }
        XCTAssertFalse(WindowIdentity.supportsWindow(role: "AXSheet", subrole: "AXDialog", isModal: false, hasCloseButton: true))
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
