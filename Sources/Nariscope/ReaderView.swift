import AppKit
import GopherCore
import SwiftUI
import WebKit

enum LinkDestination: Int {
    case currentTab, newTab, newWindow
}

struct ReaderView: NSViewRepresentable {
    let pageContent: String
    let css: String
    let find: FindRequest?
    let found: (FindRequest, Bool) -> Void
    let follow: (URL, LinkDestination) -> Void

    private static let handler = "gopherLinks"
    private static let gestures = #"""
    (() => {
      const linkFor = event => {
        if (!event.isTrusted || !(event.target instanceof Element)) return null;
        const link = event.target.closest("a[href]");
        return link?.protocol === "gopher:" ? link : null;
      };
      const send = (event, link, kind) => {
        event.preventDefault();
        window.webkit.messageHandlers.gopherLinks.postMessage({
          kind, url: link.href, x: event.clientX, y: event.clientY
        });
      };
      document.addEventListener("contextmenu", event => {
        const link = linkFor(event);
        if (link) send(event, link, "menu");
      }, true);
      document.addEventListener("click", event => {
        const link = linkFor(event);
        if (link && event.metaKey && event.button === 0) send(event, link, "window");
      }, true);
      // mouseup covers macOS versions whose WebKit does not emit auxclick.
      let middleLink = null;
      document.addEventListener("mousedown", event => {
        if (event.button !== 1) return;
        middleLink = linkFor(event);
        if (middleLink) event.preventDefault();
      }, true);
      document.addEventListener("mouseup", event => {
        if (event.button !== 1) return;
        const link = linkFor(event);
        if (link && link === middleLink) send(event, link, "tab");
        middleLink = null;
      }, true);
      document.addEventListener("auxclick", event => {
        if (event.button === 1 && linkFor(event)) event.preventDefault();
      }, true);
    })();
    """#

    func makeCoordinator() -> Coordinator { Coordinator(follow: follow) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let controller = configuration.userContentController
        controller.add(context.coordinator, contentWorld: .defaultClient, name: Self.handler)
        controller.addUserScript(WKUserScript(source: Self.gestures, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.follow = follow
        coordinator.found = found
        coordinator.update(view, pageContent: pageContent, css: css, find: find)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: handler, contentWorld: .defaultClient)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var follow: (URL, LinkDestination) -> Void
        var found: ((FindRequest, Bool) -> Void)?
        private var pageContent: String?
        private var css: String?
        private var navigation: WKNavigation?
        private var find: FindRequest?
        private var searchID = UUID()

        init(follow: @escaping (URL, LinkDestination) -> Void) { self.follow = follow }

        func update(_ view: WKWebView, pageContent: String, css: String, find: FindRequest?) {
            let findChanged = self.find != find
            self.find = find
            if self.pageContent != pageContent || self.css != css {
                self.pageContent = pageContent
                self.css = css
                searchID = UUID()
                let html = """
                    <!doctype html><html lang="en"><meta charset="utf-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1">
                    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
                    <style>.loadingtext { line-height: 1.2; overflow-wrap: anywhere; }
                    \(Renderer.styleElementText(css))</style>
                    <body>\(pageContent)</body></html>
                    """
                navigation = view.loadHTMLString(html, baseURL: nil)
            } else if findChanged, navigation == nil {
                search(in: view)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            self.navigation = nil
            if find != nil { search(in: webView) }
        }

        private func search(in view: WKWebView) {
            let id = UUID()
            searchID = id
            guard let find else {
                view.evaluateJavaScript("window.getSelection()?.removeAllRanges()", in: nil, in: .defaultClient)
                return
            }
            let configuration = WKFindConfiguration()
            configuration.caseSensitive = false
            configuration.wraps = true
            configuration.backwards = find.backwards
            view.find(find.text, configuration: configuration) { [weak self] result in
                guard let self, self.searchID == id else { return }
                self.found?(find, result.matchFound)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                decisionHandler(.cancel)
                let destination: LinkDestination
                if action.buttonNumber == 2 { destination = .newTab }
                else if action.modifierFlags.contains(.command) { destination = .newWindow }
                else { destination = .currentTab }
                follow(url, destination)
            } else {
                decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == ReaderView.handler, message.frameInfo.isMainFrame,
                  let payload = message.body as? [String: Any],
                  let kind = payload["kind"] as? String, let value = payload["url"] as? String,
                  let url = URL(string: value), url.scheme?.lowercased() == "gopher" else { return }
            switch kind {
            case "window": follow(url, .newWindow)
            case "tab": follow(url, .newTab)
            case "menu":
                guard let view = message.webView, let x = payload["x"] as? Double,
                      let y = payload["y"] as? Double else { return }
                DispatchQueue.main.async { [weak self, weak view] in
                    if let view, view.window != nil { self?.showMenu(for: url, x: x, y: y, in: view) }
                }
            default: break
            }
        }

        private func showMenu(for url: URL, x: Double, y: Double, in view: WKWebView) {
            let menu = NSMenu()
            for (title, destination) in [
                ("Open Link", LinkDestination.currentTab),
                ("Open in New Tab", .newTab),
                ("Open in New Window", .newWindow)
            ] {
                let item = NSMenuItem(title: title, action: #selector(openMenuLink(_:)), keyEquivalent: "")
                item.target = self
                item.tag = destination.rawValue
                item.representedObject = url
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy Link", action: #selector(copyMenuLink(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = url
            menu.addItem(copy)
            let point = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
            menu.popUp(positioning: nil, at: point, in: view)
        }

        @objc private func openMenuLink(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL, let destination = LinkDestination(rawValue: sender.tag) {
                follow(url, destination)
            }
        }

        @objc private func copyMenuLink(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
}
