import Foundation
import CoreGraphics

public struct ControlLayout: Equatable, Sendable {
    /// Global Accessibility coordinates: origin at the top left, in points.
    public let frame: CGRect
    public let circles: [CGRect]
    public let effectiveScale: Double

    public init(frame: CGRect, circles: [CGRect], effectiveScale: Double) {
        self.frame = frame
        self.circles = circles
        self.effectiveScale = effectiveScale
    }
}

public struct LayoutFailure: Error, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public enum TrioLayout {
    /// The returned opaque panel masks every original button, including the
    /// area left behind when the replacement buttons are brought closer.
    /// Obstacles are conservative bounds of nearby tools, never just centers.
    public static func calculate(
        window: CGRect,
        controls: [CGRect],
        requestedScale: Double,
        obstacles: [CGRect]
    ) -> Result<ControlLayout, LayoutFailure> {
        guard valid(window) else { return failure("A geometria da janela é inválida.") }
        guard requestedScale.isFinite else { return failure("O tamanho solicitado é inválido.") }
        guard controls.count == 3, controls.allSatisfy(valid) else {
            return failure("Não foram encontrados três controles com geometria válida.")
        }
        guard obstacles.allSatisfy(valid) else {
            return failure("A geometria de uma ferramenta próxima é inválida.")
        }

        let nativeDiameter = controls.map(\.height).max()!
        let nativeUnion = controls.dropFirst().reduce(controls[0]) { $0.union($1) }
        let centerY = nativeUnion.midY
        let rowTolerance = max(2, nativeDiameter * 0.2)
        guard controls.allSatisfy({ abs($0.midY - centerY) <= rowTolerance }),
              controls[0].maxX <= controls[1].minX,
              controls[1].maxX <= controls[2].minX else {
            return failure("Os controles não formam uma linha na ordem esperada.")
        }
        guard window.contains(nativeUnion),
              nativeUnion.minX - window.minX <= min(120, window.width * 0.25),
              centerY - window.minY <= min(120, window.height * 0.25) else {
            return failure("Os controles não estão no canto superior esquerdo da janela.")
        }

        let mask = nativeUnion.insetBy(dx: -2, dy: -2)
        let safeWindow = window.insetBy(dx: 1, dy: 1)
        let desiredScale = min(5, max(1, requestedScale))

        func candidate(_ scale: Double) -> ControlLayout? {
            let diameter = nativeDiameter * CGFloat(scale)
            let gap: CGFloat = 2
            let padding: CGFloat = 3
            let groupWidth = diameter * 3 + gap * 2
            // Keep the group centered on the native controls. Only shift right
            // if its padding would otherwise leave the target window.
            let left = max(nativeUnion.midX - groupWidth / 2, safeWindow.minX + padding)
            let top = centerY - diameter / 2
            let circles = (0..<3).map { index in
                CGRect(x: left + CGFloat(index) * (diameter + gap), y: top,
                       width: diameter, height: diameter)
            }
            let group = CGRect(x: left, y: top, width: groupWidth, height: diameter)
            let panel = mask.union(group.insetBy(dx: -padding, dy: -padding))
            guard valid(panel), safeWindow.contains(panel),
                  !obstacles.contains(where: { overlaps(panel, $0) }) else { return nil }
            return ControlLayout(frame: panel, circles: circles, effectiveScale: scale)
        }

        // Every candidate panel contains the preceding one. The fixed native
        // mask plus a centered, expanding group makes a binary search safe even
        // with obstacles above, below, or between the original buttons.
        guard var best = candidate(1) else {
            return failure("Não há espaço seguro para cobrir e ampliar os controles sem encobrir ferramentas.")
        }
        if let desired = candidate(desiredScale) { return .success(desired) }

        var lower = 1.0
        var upper = desiredScale
        for _ in 0..<36 {
            let middle = (lower + upper) / 2
            if let fitted = candidate(middle) {
                lower = middle
                best = fitted
            } else {
                upper = middle
            }
        }
        return .success(best)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite &&
        rect.width > 0 && rect.height > 0 &&
        rect.minX.isFinite && rect.minY.isFinite &&
        rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) > max(a.minX, b.minX) &&
        min(a.maxY, b.maxY) > max(a.minY, b.minY)
    }

    private static func failure(_ reason: String) -> Result<ControlLayout, LayoutFailure> {
        .failure(LayoutFailure(reason: reason))
    }
}
