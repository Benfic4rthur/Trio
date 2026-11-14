import AppKit
@preconcurrency import ApplicationServices

/// A short, bounded interpolation using only public AX setters. It does no
/// work while idle and respects the system's Reduce Motion preference.
@MainActor final class WindowAnimator {
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?

    func cancel() {
        timer?.invalidate(); timer = nil
        let callback = completion; completion = nil; callback?(false)
    }

    func animate(window: AXUIElement, from start: CGRect, to destination: CGRect,
                 canContinue: @escaping () -> Bool,
                 onFrame: @escaping (CGRect) -> Void = { _ in },
                 completion: @escaping (Bool) -> Void) {
        cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            let accepted = canContinue() && AX.setFrame(destination, on: window)
            if accepted, let actual = AX.rect(window) { onFrame(actual) }
            completion(accepted); return
        }
        self.completion = completion
        let began = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval = 0.22
        var steps = 0
        let timer = Timer(timeInterval: 1/60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard canContinue() else { self.finish(false); return }
                let fraction = min(1, (ProcessInfo.processInfo.systemUptime-began)/duration)
                // Ease in and out keeps movement and size in the same curve.
                let t = CGFloat(fraction*fraction*(3-2*fraction))
                let frame = CGRect(x: start.minX+(destination.minX-start.minX)*t,
                                   y: start.minY+(destination.minY-start.minY)*t,
                                   width: start.width+(destination.width-start.width)*t,
                                   height: start.height+(destination.height-start.height)*t)
                let operationStart = ProcessInfo.processInfo.systemUptime
                let accepted = AX.setFrame(frame, on: window)
                if accepted, let actual = AX.rect(window) { onFrame(actual) }
                steps += 1
                // Slow applications get one final request instead of a queue
                // of AX messages. No application can extend this animation.
                if fraction >= 1 || steps >= 16 || !accepted || ProcessInfo.processInfo.systemUptime-operationStart > 0.05 {
                    let finished = canContinue() && AX.setFrame(destination, on: window)
                    if finished, let actual = AX.rect(window) { onFrame(actual) }
                    self.finish(finished)
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func finish(_ success: Bool) {
        timer?.invalidate(); timer = nil
        let callback = completion; completion = nil; callback?(success)
    }
}
