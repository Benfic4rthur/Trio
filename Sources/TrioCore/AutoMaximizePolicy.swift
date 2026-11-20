import CoreGraphics
import Foundation

/// A conservative rule for automatic changes only. Manual arrangement is not
/// restricted by these size thresholds.
public enum AutoMaximizePolicy {
    public enum Decision: String, Equatable, Sendable {
        case maximize, excluded, auxiliary, unavailable, small, outsideWorkArea, alreadyMaximized
    }

    public static func decision(frame: CGRect, workArea: CGRect,
                                isStandard: Bool = true, isResizable: Bool = true,
                                isAuxiliary: Bool = false, isModal: Bool = false,
                                isMinimized: Bool = false, isFullscreen: Bool = false,
                                isExcluded: Bool = false) -> Decision {
        if isExcluded { return .excluded }
        if !isStandard || isAuxiliary || isModal { return .auxiliary }
        guard valid(frame), valid(workArea), isResizable, !isMinimized, !isFullscreen else { return .unavailable }
        if close(frame, workArea) { return .alreadyMaximized }
        let intersection = frame.intersection(workArea)
        guard !intersection.isNull,
              intersection.width * intersection.height >= frame.width * frame.height * 0.9,
              frame.width <= workArea.width + 3, frame.height <= workArea.height + 3 else { return .outsideWorkArea }
        let minimumWidth = max(min(900, workArea.width * 0.75), workArea.width * 0.42)
        let minimumHeight = max(min(600, workArea.height * 0.75), workArea.height * 0.42)
        let areaFraction = frame.width * frame.height / (workArea.width * workArea.height)
        guard frame.width >= minimumWidth, frame.height >= minimumHeight, areaFraction >= 0.30 else { return .small }
        return .maximize
    }

    fileprivate static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
        frame.maxX.isFinite && frame.maxY.isFinite && frame.width > 0 && frame.height > 0
    }

    fileprivate static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3 &&
        abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
    }
}

/// Bounded stabilization for creation/launch bursts. A blocked attempt never
/// makes progress towards stability and cannot keep the queue alive forever.
public struct AutoMaximizeStability: Sendable {
    public enum Result: Equatable, Sendable { case wait(TimeInterval), ready, expired }
    private let deadline: TimeInterval
    private var lastFrame: CGRect?
    private var stableSince: TimeInterval?
    private var attempts = 0
    private var finished = false

    public init(startedAt: TimeInterval) { deadline = startedAt + 1.6 }

    public mutating func observe(frame: CGRect?, at now: TimeInterval, blocked: Bool = false) -> Result {
        guard !finished else { return .expired }
        attempts += 1
        guard now.isFinite, now < deadline, attempts <= 10 else { finished = true; return .expired }
        guard !blocked, let frame, AutoMaximizePolicy.valid(frame) else {
            stableSince = nil; lastFrame = nil
            return .wait(min(0.12, deadline - now))
        }
        if let lastFrame, AutoMaximizePolicy.close(lastFrame, frame), let stableSince {
            let remaining = 0.18 - (now - stableSince)
            if remaining <= 0.000_001 { finished = true; return .ready }
            return .wait(min(0.12, max(0.02, remaining)))
        }
        lastFrame = frame; stableSince = now
        return .wait(0.12)
    }
}
