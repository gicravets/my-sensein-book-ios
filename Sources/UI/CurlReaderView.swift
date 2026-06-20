import SwiftUI
import WebKit

/// Native 3D page-curl reading surface (iOS bonus, paged mode only).
///
/// A hidden paged WKWebView lays out the chapter; each page is snapshotted into an
/// image and fed to a `UIPageViewController(.pageCurl)`, so Apple drives the
/// finger-following curl + snap-back/complete thresholds. Highlights are baked into
/// the snapshots; live text selection is unavailable in this mode (use Слайд/Прокрутка).
struct CurlReaderView: UIViewControllerRepresentable {
    let controller: ReaderController
    var onMenu: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, onMenu: onMenu) }
    func makeUIViewController(context: Context) -> UIViewController { context.coordinator.build() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: UIViewController, coordinator: Coordinator) {
        coordinator.controller.requestResnapshot = nil
        coordinator.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
    }

    final class Coordinator: NSObject, WKNavigationDelegate,
                              UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                              UIGestureRecognizerDelegate {
        let controller: ReaderController
        let onMenu: () -> Void

        private var container: UIViewController!
        var webView: WKWebView!
        private var pvc: UIPageViewController!
        private var spinner: UIActivityIndicatorView!
        private var images: [UIImage] = []
        private var currentIndex = 0

        init(controller: ReaderController, onMenu: @escaping () -> Void) {
            self.controller = controller
            self.onMenu = onMenu
        }

        // MARK: - Build

        func build() -> UIViewController {
            container = UIViewController()
            container.view.backgroundColor = UIColor(controller.theme.bgColor)

            // Hidden web view used only to render + snapshot pages.
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

            // Use the screen bounds (container isn't laid out yet) so the page lays out at
            // device width from the start — a zero/980px initial frame yields wrong pagination.
            webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
            webView.navigationDelegate = self
            webView.scrollView.isScrollEnabled = false
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            pvc = UIPageViewController(transitionStyle: .pageCurl,
                                      navigationOrientation: .horizontal,
                                      options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
            pvc.dataSource = self
            pvc.delegate = self
            pvc.isDoubleSided = false
            container.addChild(pvc)
            pvc.view.frame = container.view.bounds
            pvc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pvc.view.backgroundColor = UIColor(controller.theme.bgColor)
            container.view.addSubview(pvc.view)
            pvc.didMove(toParent: container)

            // Web view sits on top and stays VISIBLE while snapshotting — a fully
            // occluded WKWebView doesn't paint, which yields blank snapshots.
            container.view.addSubview(webView)

            spinner = UIActivityIndicatorView(style: .medium)
            spinner.center = container.view.center
            spinner.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin, .flexibleLeftMargin, .flexibleRightMargin]
            container.view.addSubview(spinner)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            container.view.addGestureRecognizer(tap)
            let up = UISwipeGestureRecognizer(target: self, action: #selector(menuSwipe))
            up.direction = .up
            up.delegate = self
            container.view.addGestureRecognizer(up)

            controller.webView = webView
            controller.requestResnapshot = { [weak self] in self?.snapshotChapter() }
            controller.loadCurrentChapter()
            return container
        }

        // MARK: - Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.runSetup()         // apply paged columns/theme to the hidden web view
            snapshotChapter()
        }

        // MARK: - Snapshotting

        private func snapshotChapter() {
            spinner.startAnimating()
            webView.isHidden = false
            container.view.bringSubviewToFront(webView)
            container.view.bringSubviewToFront(spinner)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                self.webView.evaluateJavaScript("window.__pageCount?window.__pageCount():1") { res, _ in
                    let n = max(1, (res as? Int) ?? 1)
                    self.captureAll(count: n) { imgs in
                        self.images = imgs.isEmpty ? [self.blankImage()] : imgs
                        // Land on the current fraction (preserves position across settings re-snapshots).
                        let n = self.images.count
                        let start = n > 1 ? Int((self.controller.fraction * Double(n - 1)).rounded()) : 0
                        self.currentIndex = min(max(0, start), n - 1)
                        self.pvc.setViewControllers([self.page(self.currentIndex)], direction: .forward, animated: false)
                        // Reveal the curl pages, hide the live web view.
                        self.webView.isHidden = true
                        self.container.view.bringSubviewToFront(self.pvc.view)
                        self.spinner.stopAnimating()
                        self.persist()
                    }
                }
            }
        }

        private func captureAll(count n: Int, completion: @escaping ([UIImage]) -> Void) {
            var imgs = [UIImage?](repeating: nil, count: n)
            let cfg = WKSnapshotConfiguration()
            cfg.rect = webView.bounds
            cfg.afterScreenUpdates = true
            func step(_ i: Int) {
                if i >= n { completion(imgs.compactMap { $0 }); return }
                webView.evaluateJavaScript("window.__snapTo(\(i))") { [weak self] _, _ in
                    guard let self else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        self.webView.takeSnapshot(with: cfg) { img, _ in imgs[i] = img; step(i + 1) }
                    }
                }
            }
            step(0)
        }

        private func blankImage() -> UIImage {
            UIGraphicsImageRenderer(bounds: webView.bounds).image { ctx in
                UIColor(controller.theme.bgColor).setFill()
                ctx.fill(webView.bounds)
            }
        }

        private func page(_ i: Int) -> ImagePageVC {
            let vc = ImagePageVC()
            vc.index = i
            vc.image = (i >= 0 && i < images.count) ? images[i] : nil
            vc.bg = UIColor(controller.theme.bgColor)
            return vc
        }

        // MARK: - Data source / delegate

        func pageViewController(_ p: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let v = vc as? ImagePageVC, v.index > 0 else { return nil }
            return page(v.index - 1)
        }
        func pageViewController(_ p: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let v = vc as? ImagePageVC, v.index < images.count - 1 else { return nil }
            return page(v.index + 1)
        }
        func pageViewController(_ p: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let v = pvc.viewControllers?.first as? ImagePageVC {
                currentIndex = v.index
                persist()
            }
        }

        // MARK: - Tap / menu

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            let x = g.location(in: container.view).x / max(1, container.view.bounds.width)
            x < 0.5 ? goPrev() : goNext()
        }
        @objc private func menuSwipe() { onMenu() }

        private func goNext() {
            if currentIndex < images.count - 1 {
                currentIndex += 1
                pvc.setViewControllers([page(currentIndex)], direction: .forward, animated: true)
                persist()
            } else {
                controller.loadNextChapter()   // → didFinish → snapshotChapter
            }
        }
        private func goPrev() {
            if currentIndex > 0 {
                currentIndex -= 1
                pvc.setViewControllers([page(currentIndex)], direction: .reverse, animated: true)
                persist()
            } else {
                controller.loadPrevChapter()
            }
        }

        private func persist() {
            let n = max(1, images.count)
            controller.reportCurlPosition(fraction: n > 1 ? Double(currentIndex) / Double(n - 1) : 0)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// A single curl page: just an image.
final class ImagePageVC: UIViewController {
    var index = 0
    var image: UIImage?
    var bg: UIColor = .white
    private let imageView = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleToFill
        imageView.image = image
        view.addSubview(imageView)
    }
}
