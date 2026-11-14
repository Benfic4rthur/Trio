import Foundation
import CoreGraphics

/// Normal-level, on-screen windows in WindowServer front-to-back order.
public struct VisibleWindowIdentity: Sendable {
    public let id: UInt32
    public let pid: Int32
    public let frame: CGRect

    public init(id: UInt32, pid: Int32, frame: CGRect) {
        self.id = id; self.pid = pid; self.frame = frame
    }
}

public enum WindowIdentity {
    /// Equal-sized windows are common when automatic maximization is enabled.
    /// A collision can only be resolved when application-scoped AX hit tests
    /// have independently identified all three controls of the focused window.
    public static func resolve(windows: [VisibleWindowIdentity], pid: Int32, frame: CGRect,
                               controlCenters: [CGPoint], ignoredPID: Int32,
                               coincidentControlsVerified: Bool = false) -> UInt32? {
        guard valid(frame), controlCenters.count == 3,
              controlCenters.allSatisfy({ $0.x.isFinite && $0.y.isFinite && frame.contains($0) }) else { return nil }
        let matches = windows.filter { $0.pid == pid && close($0.frame, frame) }
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0].id }
        guard coincidentControlsVerified else { return nil }
        let topIDs = controlCenters.compactMap { point in
            windows.first { $0.pid != ignoredPID && $0.frame.contains(point) }?.id
        }
        guard topIDs.count == 3, let first = topIDs.first,
              topIDs.allSatisfy({ $0 == first }), matches.contains(where: { $0.id == first }) else { return nil }
        return first
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite &&
        rect.maxX.isFinite && rect.maxY.isFinite && rect.width > 0 && rect.height > 0
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX) <= 2 && abs(a.minY-b.minY) <= 2 &&
        abs(a.width-b.width) <= 2 && abs(a.height-b.height) <= 2
    }
}
