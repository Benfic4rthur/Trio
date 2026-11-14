import Foundation
import CoreGraphics
import XCTest
@testable import TrioCore

final class LayoutTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 900, height: 600)

    private func originals(x: CGFloat = 112, centerY: CGFloat = 118) -> [CGRect] {
        (0..<3).map { CGRect(x: x + CGFloat($0) * 20, y: centerY - 6, width: 12, height: 12) }
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

    func testFiveTimesFitsWhenCornerHasRoom() throws {
        let result = try layout(controls: originals(centerY: 160))
        XCTAssertEqual(result.effectiveScale, 5)
        XCTAssertEqual(result.circles[0].width, 60)
        XCTAssertTrue(window.contains(result.frame))
        XCTAssertEqual(result.circles[1].minX - result.circles[0].maxX, 2)
    }

    func testOpaqueMaskContainsOriginalsEvenWhenNewGroupIsTighter() throws {
        let controls = originals()
        let result = try layout(controls: controls, scale: 1)
        for original in controls {
            XCTAssertTrue(result.frame.contains(original.insetBy(dx: -2, dy: -2)))
        }
        XCTAssertLessThan(result.circles[2].maxX - result.circles[0].minX,
                          controls[2].maxX - controls[0].minX)
    }

    func testObstacleToRightClampsWidth() throws {
        let controls = originals(centerY: 160)
        let obstacle = CGRect(x: 195, y: 120, width: 80, height: 80)
        let result = try layout(controls: controls, obstacles: [obstacle])
        XCTAssertGreaterThan(result.effectiveScale, 1)
        XCTAssertLessThan(result.effectiveScale, 5)
        XCTAssertLessThanOrEqual(result.frame.maxX, obstacle.minX)
    }

    func testObstacleAboveClampsHeight() throws {
        let obstacle = CGRect(x: 100, y: 125, width: 180, height: 10)
        let result = try layout(controls: originals(centerY: 160), obstacles: [obstacle])
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
        let controls = originals(centerY: 160)
        XCTAssertEqual(try layout(controls: controls, scale: 20).effectiveScale, 5)
        let small = try layout(controls: controls, scale: 0.2)
        XCTAssertEqual(small.effectiveScale, 1)
        XCTAssertEqual(small.circles[0].height, controls[0].height)
    }

    func testInsufficientRoomNeverShrinksBelowNativeSize() {
        XCTAssertThrowsError(try layout(controls: originals(centerY: 108)))
    }

    func testObstacleBelowAlsoLimitsVerticalGrowth() throws {
        let obstacle = CGRect(x: 100, y: 180, width: 400, height: 80)
        let result = try layout(controls: originals(centerY: 160), obstacles: [obstacle])
        XCTAssertLessThanOrEqual(result.frame.maxY, 180)
        XCTAssertGreaterThan(result.effectiveScale, 1)
        XCTAssertLessThan(result.effectiveScale, 5)
    }
}
