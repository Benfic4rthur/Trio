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
    /// The complete reservation allowed by the user. Horizontal expansion ends
    /// five points after the original green button; it never consumes the next
    /// toolbar item. Vertical growth stays symmetric around the native row.
    public static func availableRegion(window: CGRect, controls: [CGRect]) -> CGRect? {
        guard valid(window), controls.count == 3, controls.allSatisfy(valid) else { return nil }
        let nativeUnion = controls.dropFirst().reduce(controls[0]) { $0.union($1) }
        let centerY = nativeUnion.midY
        let diameter = controls.map(\.height).max()!
        let tolerance = max(2, diameter * 0.2)
        guard controls.allSatisfy({ abs($0.midY - centerY) <= tolerance }),
              controls[0].maxX <= controls[1].minX,
              controls[1].maxX <= controls[2].minX,
              window.contains(nativeUnion),
              nativeUnion.minX - window.minX <= min(120, window.width * 0.25),
              centerY - window.minY <= min(120, window.height * 0.25) else { return nil }
        let left = window.minX + 1
        let right = min(window.maxX - 1, controls[2].maxX + 5)
        let halfHeight = min(centerY - (window.minY + 1), window.maxY - 1 - centerY)
        let region = CGRect(x: left, y: centerY - halfHeight, width: right - left, height: halfHeight * 2)
        return valid(region) ? region : nil
    }

    /// Replacement circles stay concentric with the native traffic lights, so
    /// their opaque disks cover the originals without an opaque panel backdrop.
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

        guard let reservation = availableRegion(window: window, controls: controls) else {
            return failure("Não há uma região segura para os controles nesta janela.")
        }
        let mask = nativeUnion.insetBy(dx: -2, dy: -2)
        let desiredScale = min(5, max(1, requestedScale))

        func candidate(_ scale: Double) -> ControlLayout? {
            let diameter = nativeDiameter * CGFloat(scale)
            let circles = controls.map { original in
                CGRect(x: original.midX - diameter / 2, y: original.midY - diameter / 2,
                       width: diameter, height: diameter)
            }
            // Keep this geometric proof even though centers currently coincide:
            // later alignment changes must not reveal a native colored crescent.
            guard zip(circles, controls).allSatisfy({ replacement, original in
                hypot(replacement.midX - original.midX, replacement.midY - original.midY) +
                    max(original.width, original.height) / 2 <= replacement.width / 2 + 0.000001
            }) else { return nil }
            let envelope = circles.dropFirst().reduce(circles[0]) { $0.union($1) }
            let panel = mask.union(envelope.insetBy(dx: -1, dy: -1))
            guard valid(panel), reservation.contains(panel),
                  !obstacles.contains(where: { overlaps(panel, $0) }) else { return nil }
            return ControlLayout(frame: panel, circles: circles, effectiveScale: scale)
        }

        // Concentric circles form nested envelopes, allowing a bounded search.
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
        rect.size.width.isFinite && rect.size.height.isFinite &&
        rect.size.width > 0 && rect.size.height > 0 &&
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
