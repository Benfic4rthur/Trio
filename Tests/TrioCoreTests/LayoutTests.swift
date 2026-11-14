import Foundation
import CoreGraphics
import XCTest
@testable import TrioCore

final class LayoutTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 900, height: 600)

    private func originals(x: CGFloat = 112, centerY: CGFloat = 118, spacing: CGFloat = 20) -> [CGRect] {
        (0..<3).map { CGRect(x: x + CGFloat($0) * spacing, y: centerY - 6, width: 12, height: 12) }
    }

    private func layout(window: CGRect? = nil, controls: [CGRect]? = nil,
                        scale: Double = 5, obstacles: [CGRect] = []) throws -> ControlLayout {
        try TrioLayout.calculate(window: window ?? self.window, controls: controls ?? originals(),
                                 requestedScale: scale, obstacles: obstacles).get()
    }

    func testLargeRequestedSizeClampsToStandardTitleBarHeight() throws {
        let result = try layout()
        XCTAssertLessThan(result.effectiveScale, 5)
        XCTAssertGreaterThan(result.effectiveScale, 1)
        XCTAssertGreaterThanOrEqual(result.frame.minY, window.minY + 1)
        XCTAssertEqual(result.circles[0].midY, originals()[0].midY, accuracy: 0.0001)
    }

    func testFiveTimesRequestClampsAtGreenBoundaryWithFixedCenters() throws {
        let controls = originals(centerY: 160, spacing: 90)
        let result = try layout(controls: controls)
        XCTAssertGreaterThan(result.effectiveScale, 1)
        XCTAssertLessThan(result.effectiveScale, 5)
        XCTAssertLessThanOrEqual(result.frame.maxX, controls[2].maxX + 5)
        XCTAssertTrue(window.contains(result.frame))
        XCTAssertEqual(result.circles[2].midX, controls[2].midX)
    }

    func testMaskContainsOriginalShadowEnvelopeAndPreservesCenters() throws {
        let controls = originals()
        let result = try layout(controls: controls, scale: 1)
        for original in controls {
            XCTAssertTrue(result.frame.contains(original.insetBy(dx: -2, dy: -2)))
        }
        for (circle, original) in zip(result.circles, controls) {
            XCTAssertEqual(circle.midX, original.midX)
            XCTAssertEqual(circle.midY, original.midY)
        }
    }

    func testObstacleToRightClampsWidth() throws {
        let controls = originals(centerY: 160)
        let obstacle = CGRect(x: 168, y: 120, width: 80, height: 80)
        let result = try layout(controls: controls, obstacles: [obstacle])
        XCTAssertGreaterThan(result.effectiveScale, 1)
        XCTAssertLessThan(result.effectiveScale, try layout(controls: controls).effectiveScale)
        XCTAssertLessThanOrEqual(result.frame.maxX, obstacle.minX)
    }

    func testObstacleAboveClampsHeight() throws {
        let obstacle = CGRect(x: 100, y: 140, width: 400, height: 10)
        let result = try layout(controls: originals(centerY: 160, spacing: 90), obstacles: [obstacle])
        XCTAssertGreaterThan(result.effectiveScale, 1)
        XCTAssertLessThan(result.effectiveScale, 5)
        XCTAssertGreaterThanOrEqual(result.frame.minY, obstacle.maxY)
    }

    func testObstacleTouchingNativeMaskRefusesEntireOverlay() {
        let obstacle = CGRect(x: 130, y: 114, width: 2, height: 4)
        XCTAssertThrowsError(try layout(obstacles: [obstacle]))
    }

    func testInvalidOrNonfiniteGeometryRefusesLayout() {
        XCTAssertThrowsError(try layout(window: .zero))
        XCTAssertThrowsError(try layout(window: CGRect(x: CGFloat.nan, y: 0, width: 200, height: 200)))
        XCTAssertThrowsError(try layout(window: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200)))
        XCTAssertThrowsError(try layout(controls: [CGRect(x: 112, y: 112, width: -12, height: 12)]))
        XCTAssertThrowsError(try layout(scale: .nan))
        XCTAssertThrowsError(try layout(obstacles: [CGRect(x: 200, y: 100, width: 0, height: 20)]))
    }

    func testNegativeRawDimensionsAreNotSilentlyStandardized() {
        // CGRect.width/height expose standardized magnitudes on macOS. Validate
        // size.width/height as received rather than accepting malformed AX data.
        var malformedControls = originals()
        malformedControls[0] = CGRect(x: 124, y: 112, width: -12, height: 12)
        XCTAssertThrowsError(try layout(controls: malformedControls))
        malformedControls = originals()
        malformedControls[1] = CGRect(x: 132, y: 124, width: 12, height: -12)
        XCTAssertThrowsError(try layout(controls: malformedControls))
        XCTAssertThrowsError(try layout(window: CGRect(x: 1000, y: 100, width: -900, height: 600)))
        XCTAssertThrowsError(try layout(obstacles: [CGRect(x: 900, y: 500, width: -20, height: 20)]))
    }

    func testNegativeMonitorOriginPreservesGlobalAlignment() throws {
        let monitorWindow = CGRect(x: -1500, y: -700, width: 900, height: 600)
        let controls = originals(x: -1488, centerY: -682)
        let result = try layout(window: monitorWindow, controls: controls)
        XCTAssertTrue(monitorWindow.contains(result.frame))
        XCTAssertLessThan(result.frame.maxX, 0)
        XCTAssertLessThan(result.frame.maxY, 0)
        XCTAssertEqual(result.circles[0].midY, -682, accuracy: 0.0001)
    }

    func testWrongOrderOrDifferentRowsRefusesLayout() {
        let controls = originals()
        XCTAssertThrowsError(try layout(controls: [controls[1], controls[0], controls[2]]))
        var differentRow = controls
        differentRow[2].origin.y += 20
        XCTAssertThrowsError(try layout(controls: differentRow))
    }

    func testGeometryOutsideCornerRefusesLayout() {
        XCTAssertThrowsError(try layout(controls: originals(x: 400)))
        XCTAssertThrowsError(try layout(controls: originals(centerY: 400)))
    }

    func testRequestedScaleNeverExceedsFiveOrReducesNativeDiameter() throws {
        let controls = originals(centerY: 160, spacing: 90)
        XCTAssertLessThanOrEqual(try layout(controls: controls, scale: 20).effectiveScale, 5)
        XCTAssertEqual(try layout(controls: controls, scale: 20).effectiveScale,
                       try layout(controls: controls, scale: 5).effectiveScale)
        let small = try layout(controls: controls, scale: 0.2)
        XCTAssertEqual(small.effectiveScale, 1)
        XCTAssertEqual(small.circles[0].height, controls[0].height)
    }

    func testInsufficientRoomNeverShrinksBelowNativeSize() {
        XCTAssertThrowsError(try layout(controls: originals(centerY: 108)))
    }

    func testObstacleBelowAlsoLimitsVerticalGrowth() throws {
        let obstacle = CGRect(x: 100, y: 170, width: 400, height: 80)
        let result = try layout(controls: originals(centerY: 160, spacing: 90), obstacles: [obstacle])
        XCTAssertLessThanOrEqual(result.frame.maxY, 170)
        XCTAssertGreaterThan(result.effectiveScale, 1)
        XCTAssertLessThan(result.effectiveScale, 5)
    }

    func testThreeTimesPreservesCentersAndStopsFivePointsAfterOriginalGreen() throws {
        let controls = originals(centerY: 160)
        let result = try layout(controls: controls, scale: 3)
        XCTAssertGreaterThan(result.effectiveScale, 1)
        XCTAssertLessThan(result.effectiveScale, 3)
        XCTAssertGreaterThanOrEqual(result.frame.minX, window.minX + 1)
        XCTAssertLessThanOrEqual(result.frame.maxX, controls[2].maxX + 5)
        XCTAssertEqual(result.frame.maxX, controls[2].maxX + 5, accuracy: 0.0001)
        for (replacement, original) in zip(result.circles, controls) {
            XCTAssertEqual(replacement.midX, original.midX)
            XCTAssertEqual(replacement.midY, original.midY)
        }
    }

    func testCodexGeometryConcentricallyCoversNativeDisksWithinStrictBoundary() throws {
        let codexWindow = CGRect(x: 0, y: 49, width: 2624, height: 1568)
        let native = [15, 38, 61].map { CGRect(x: $0, y: 72, width: 16, height: 16) }
        let fitted = try layout(window: codexWindow, controls: native, scale: 3)
        XCTAssertEqual(fitted.effectiveScale, 1.5, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(fitted.frame.maxX, 82)
        for (replacement, original) in zip(fitted.circles, native) {
            let centerDistance = hypot(replacement.midX - original.midX, replacement.midY - original.midY)
            XCTAssertLessThanOrEqual(centerDistance + original.width / 2, replacement.width / 2)
        }
    }

    func testAvailableRegionMatchesUserReservationAndContainsFittedMask() throws {
        let controls = originals()
        let region = try XCTUnwrap(TrioLayout.availableRegion(window: window, controls: controls))
        XCTAssertEqual(region.minX, window.minX + 1)
        XCTAssertEqual(region.maxX, controls[2].maxX + 5)
        XCTAssertEqual(region.midY, controls[0].midY)
        XCTAssertEqual(region.minY, window.minY + 1)
        XCTAssertTrue(region.contains(try layout().frame))
        XCTAssertNil(TrioLayout.availableRegion(window: .zero, controls: controls))
    }
}
