import AppKit
import SwiftUI

/// Observes middle clicks inside a tab without taking its normal button input.
struct MiddleClickArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> TargetView { TargetView() }

    func updateNSView(_ view: TargetView, context: Context) { view.action = action }

    static func dismantleNSView(_ view: TargetView, coordinator: ()) { view.removeMonitor() }

    final class TargetView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
                guard let self, let window = self.window, event.window == window, event.buttonNumber == 2,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                DispatchQueue.main.async { [weak self] in self?.action?() }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
