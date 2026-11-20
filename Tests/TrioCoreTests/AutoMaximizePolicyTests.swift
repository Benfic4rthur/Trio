import CoreGraphics
import XCTest
@testable import TrioCore

final class AutoMaximizePolicyTests: XCTestCase {
    private let currentWork = CGRect(x: 0, y: 49, width: 2624, height: 1568)
    private func frame(_ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: 40, y: 80, width: width, height: height)
    }

    func testSizeStudyOnCurrentDisplayPreservesSmallAndMediumWindows() {
        for size in [CGSize(width: 420, height: 320), CGSize(width: 680, height: 482),
                     CGSize(width: 900, height: 600), CGSize(width: 1100, height: 800),
                     CGSize(width: 1400, height: 700)] {
            XCTAssertEqual(AutoMaximizePolicy.decision(frame: frame(size.width, size.height), workArea: currentWork), .small)
        }
        for size in [CGSize(width: 1400, height: 900), CGSize(width: 1600, height: 1000), CGSize(width: 1800, height: 1200)] {
            XCTAssertEqual(AutoMaximizePolicy.decision(frame: frame(size.width, size.height), workArea: currentWork), .maximize)
        }
    }

    func testLargeWindowIsRelativeToTheMonitorRatherThanPixelDensity() {
        let work = CGRect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: frame(900, 600), workArea: work), .maximize)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: frame(800, 500), workArea: work), .small)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: frame(900, 600), workArea: currentWork), .small)
    }

    func testSmallDisplayUsesAnAttainablePointThreshold() {
        let work = CGRect(x: 0, y: 25, width: 1024, height: 550)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: CGRect(x: 20, y: 35, width: 900, height: 500), workArea: work), .maximize)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: CGRect(x: 20, y: 35, width: 620, height: 400), workArea: work), .small)
    }

    func testMetadataAndExceptionsOverrideEvenVeryLargeGeometry() {
        let large = frame(1800, 1200)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: large, workArea: currentWork, isExcluded: true), .excluded)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: large, workArea: currentWork, isStandard: false), .auxiliary)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: large, workArea: currentWork, isAuxiliary: true), .auxiliary)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: large, workArea: currentWork, isModal: true), .auxiliary)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: large, workArea: currentWork, isResizable: false), .unavailable)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: large, workArea: currentWork, isMinimized: true), .unavailable)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: large, workArea: currentWork, isFullscreen: true), .unavailable)
    }

    func testAlreadyMaximizedAndMostlyOffscreenWindowsAreNotChanged() {
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: currentWork, workArea: currentWork), .alreadyMaximized)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: frame(1800, 1200).offsetBy(dx: 2200, dy: 0), workArea: currentWork), .outsideWorkArea)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: .zero, workArea: currentWork), .unavailable)
        XCTAssertEqual(AutoMaximizePolicy.decision(frame: frame(.infinity, 800), workArea: currentWork), .unavailable)
    }

    func testStableWindowBecomesReadyOnlyOnceDespiteDuplicateEvents() {
        var state = AutoMaximizeStability(startedAt: 10)
        XCTAssertEqual(state.observe(frame: frame(1400, 900), at: 10.18), .wait(0.12))
        guard case .wait = state.observe(frame: frame(1400, 900), at: 10.30) else { return XCTFail("Must settle first") }
        XCTAssertEqual(state.observe(frame: frame(1400, 900), at: 10.36), .ready)
        XCTAssertEqual(state.observe(frame: frame(1400, 900), at: 10.9), .expired)
    }

    func testChangingInitialGeometryRestartsStabilization() {
        var state = AutoMaximizeStability(startedAt: 0)
        _ = state.observe(frame: frame(400, 300), at: 0.18)
        XCTAssertEqual(state.observe(frame: frame(1400, 900), at: 0.30), .wait(0.12))
        guard case .wait = state.observe(frame: frame(1400, 900), at: 0.42) else { return XCTFail("New geometry needs its own settling period") }
        XCTAssertEqual(state.observe(frame: frame(1400, 900), at: 0.48), .ready)
    }

    func testOtherAnimationAndMissingAXDataHaveABoundedLifetime() {
        var busy = AutoMaximizeStability(startedAt: 0)
        _ = busy.observe(frame: frame(1400, 900), at: 0.18)
        _ = busy.observe(frame: nil, at: 0.30, blocked: true)
        XCTAssertEqual(busy.observe(frame: frame(1400, 900), at: 0.42), .wait(0.12))
        XCTAssertEqual(busy.observe(frame: frame(1400, 900), at: 0.60), .ready)
        var missing = AutoMaximizeStability(startedAt: 0)
        for attempt in 0..<10 { guard case .wait = missing.observe(frame: nil, at: Double(attempt) * 0.12) else { return XCTFail("Bounded retry budget") } }
        XCTAssertEqual(missing.observe(frame: nil, at: 1.2), .expired)
        var deadline = AutoMaximizeStability(startedAt: 0)
        XCTAssertEqual(deadline.observe(frame: frame(1400, 900), at: 1.6), .expired)
    }

    func testSimultaneousWindowsDoNotShareOrResetEachOthersStability() {
        var first = AutoMaximizeStability(startedAt: 5)
        var second = AutoMaximizeStability(startedAt: 5)
        _ = first.observe(frame: frame(1400, 900), at: 5.18)
        _ = second.observe(frame: frame(400, 300), at: 5.20)
        _ = second.observe(frame: frame(1600, 1000), at: 5.32)
        XCTAssertEqual(first.observe(frame: frame(1400, 900), at: 5.36), .ready)
        guard case .wait = second.observe(frame: frame(1600, 1000), at: 5.40) else { return XCTFail("Each window keeps its own clock") }
        XCTAssertEqual(second.observe(frame: frame(1600, 1000), at: 5.50), .ready)
    }
}
