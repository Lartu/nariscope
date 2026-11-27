import AppKit
import SwiftUI

/// Shares the last normal browser window size across windows and launches.
struct BrowserWindowSize: NSViewRepresentable {
    private static let key = "lastBrowserWindowContentSize"

    static var lastSize: CGSize {
        let stored = UserDefaults.standard.string(forKey: key).map(NSSizeFromString)
        guard let stored, stored.width.isFinite, stored.height.isFinite,
              stored.width > 0, stored.height > 0 else {
            return CGSize(width: 960, height: 750)
        }
        return stored
    }

    func makeNSView(context: Context) -> Tracker { Tracker() }
    func updateNSView(_ view: Tracker, context: Context) {}

    static func dismantleNSView(_ view: Tracker, coordinator: ()) {
        view.disconnect()
    }

    final class Tracker: NSView {
        private weak var observedWindow: NSWindow?
        private var ready = false
        private var changingFullScreen = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observedWindow !== window else { return }
            disconnect()
            guard let window else { return }

            observedWindow = window
            let size = BrowserWindowSize.lastSize
            let notifications = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification,
                         NSWindow.didEndLiveResizeNotification] {
                notifications.addObserver(self, selector: #selector(windowSizeChanged(_:)), name: name, object: window)
            }
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                notifications.addObserver(self, selector: #selector(fullScreenChanged(_:)), name: name, object: window)
            }

            // Let SwiftUI finish sizing the scene before setting its initial size.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.observedWindow === window else { return }
                if !window.styleMask.contains(.fullScreen), !self.changingFullScreen {
                    let available = (window.screen ?? NSScreen.main).map {
                        window.contentRect(forFrameRect: $0.visibleFrame).size
                    } ?? size
                    let target = CGSize(width: min(size.width, available.width),
                                        height: min(size.height, available.height))
                    if window.contentRect(forFrameRect: window.frame).size != target {
                        window.setContentSize(target)
                    }
                }
                self.ready = true
                self.rememberSize()
            }
        }

        func disconnect() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            ready = false
            changingFullScreen = false
        }

        @objc private func windowSizeChanged(_ notification: Notification) {
            rememberSize(liveResizeFinished: notification.name == NSWindow.didEndLiveResizeNotification)
        }

        private func rememberSize(liveResizeFinished: Bool = false) {
            guard let window = observedWindow, ready, window.isKeyWindow,
                  (liveResizeFinished || !window.inLiveResize), !changingFullScreen,
                  !window.styleMask.contains(.fullScreen) else { return }
            let size = window.contentRect(forFrameRect: window.frame).size
            if size != BrowserWindowSize.lastSize {
                UserDefaults.standard.set(NSStringFromSize(size), forKey: BrowserWindowSize.key)
            }
        }

        @objc private func fullScreenChanged(_ notification: Notification) {
            changingFullScreen = notification.name == NSWindow.willEnterFullScreenNotification
                || notification.name == NSWindow.willExitFullScreenNotification
            if !changingFullScreen { rememberSize() }
        }
    }
}
