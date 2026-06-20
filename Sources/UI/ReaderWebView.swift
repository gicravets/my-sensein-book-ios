import SwiftUI
import WebKit

/// Wraps the paginated WKWebView. Tap-zones and swipe are attached as gesture
/// recognizers ON the web view with `cancelsTouchesInView = false`, so they coexist
/// with the web view's own long-press selection (a covering SwiftUI overlay would
/// swallow the long-press and break text selection / highlighting).
struct ReaderWebView: UIViewRepresentable {
    let controller: ReaderController
    var onZone: (CGFloat) -> Void          // tapped x as a 0...1 fraction of width
    var onMenu: () -> Void                 // swipe up → toggle menu

    func makeCoordinator() -> Coordinator { Coordinator(onZone: onZone, onMenu: onMenu) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        content.add(controller, name: "reader")

        let vp = """
        (function(){var d=document,XH='http://www.w3.org/1999/xhtml';
        function setvp(){var m=d.querySelector('meta[name=viewport]');
        if(!m){try{m=d.createElementNS(XH,'meta');m.setAttribute('name','viewport');(d.head||d.documentElement).appendChild(m);}catch(e){return;}}
        m.setAttribute('content','width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');}
        setvp();d.addEventListener('DOMContentLoaded',setvp);})();
        """
        content.addUserScript(WKUserScript(source: vp, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        config.userContentController = content
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = controller
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = controller.scrollMode
        webView.scrollView.bounces = false

        // Tap = 50/50 page flip. Horizontal page-slide is handled in JS (finger-follow).
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        webView.addGestureRecognizer(tap)

        // Swipe up → toggle the reader menu.
        let up = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipeUp))
        up.direction = .up
        up.delegate = context.coordinator
        up.cancelsTouchesInView = false
        webView.addGestureRecognizer(up)

        context.coordinator.webView = webView
        controller.webView = webView
        controller.loadCurrentChapter()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onZone: (CGFloat) -> Void
        let onMenu: () -> Void
        weak var webView: WKWebView?

        init(onZone: @escaping (CGFloat) -> Void, onMenu: @escaping () -> Void) {
            self.onZone = onZone
            self.onMenu = onMenu
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let wv = webView, wv.bounds.width > 0 else { return }
            onZone(g.location(in: wv).x / wv.bounds.width)
        }

        @objc func handleSwipeUp() { onMenu() }

        // Coexist with the web view's own recognizers (long-press selection, scroll).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
