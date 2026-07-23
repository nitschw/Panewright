import SwiftUI
import WebKit

/// Renders a Confluence page and keeps your place: headings become
/// collapsible, and both the collapsed set and the scroll offset are saved
/// per article, so reopening a page days later lands you where you left off.
struct ArticleWebView: NSViewRepresentable {
    let pageID: String
    let html: String
    let host: String
    let authorization: String?

    /// Attachments live behind the same auth as the API, so image URLs are
    /// rewritten to this scheme and fetched with credentials attached.
    static let imageScheme = "pwimg"

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.authorization = authorization
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "panewright")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: Self.imageScheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedPageID != pageID else { return }
        context.coordinator.loadedPageID = pageID
        context.coordinator.pageID = pageID
        context.coordinator.authorization = authorization
        Self.dumpForDiagnosis(html, pageID: pageID)
        let body = Self.rewritingImageSources(html, host: host)
        // Base URL in our own scheme, so relative attachment paths resolve
        // through the authenticated handler *and* count as same-origin —
        // a null origin (the default for loadHTMLString) gets them blocked.
        let base = host.isEmpty ? nil : URL(string: "\(Self.imageScheme)://\(host)/")
        webView.loadHTMLString(Self.document(body: body), baseURL: base)
    }

    /// Last-viewed page body, for diagnosing rendering problems (image
    /// markup varies wildly between Confluence editors and storage backends).
    static func dumpForDiagnosis(_ html: String, pageID: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Panewright-lastpage.html")
        try? html.write(to: url, atomically: true, encoding: .utf8)
        let images = html.components(separatedBy: "<img").dropFirst()
            .prefix(6)
            .map { "<img" + $0.prefix(400) }
            .joined(separator: "\n\n")
        DragLog.log("confluence page \(pageID): \(images.isEmpty ? "no <img> tags" : images)")
    }

    /// Absolute site URLs move onto our scheme; relative ones resolve via
    /// the base URL. `srcset` is stripped so the browser can't bypass the
    /// handler with an unauthenticated candidate.
    static func rewritingImageSources(_ html: String, host: String) -> String {
        guard !host.isEmpty else { return html }
        var result = html
        for attribute in ["src", "data-image-src", "data-src", "href"] {
            for quote in ["\"", "'"] {
                result = result.replacingOccurrences(
                    of: "\(attribute)=\(quote)https://\(host)/",
                    with: "\(attribute)=\(quote)\(imageScheme)://\(host)/")
            }
        }
        result = result.replacingOccurrences(
            of: "srcset=\"", with: "data-pw-srcset=\"")
        return result
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler,
        WKURLSchemeHandler
    {
        weak var webView: WKWebView?
        var pageID = ""
        var loadedPageID: String?
        var authorization: String?
        private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

        // MARK: Authenticated image loading

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let source = urlSchemeTask.request.url,
                var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
            else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            components.scheme = "https"
            guard let target = components.url else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            var request = URLRequest(url: target)
            if let authorization {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            // WKURLSchemeTask isn't Sendable; hop back to the main queue
            // through a box so the completion doesn't send it across
            // isolation domains.
            let box = SchemeTaskBox(task: urlSchemeTask)
            let key = ObjectIdentifier(urlSchemeTask)
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self, self.tasks[key] != nil else { return }
                    self.tasks[key] = nil
                    box.finish(data: data, response: response, error: error)
                }
            }
            tasks[key] = task
            task.resume()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            let key = ObjectIdentifier(urlSchemeTask)
            tasks[key]?.cancel()
            tasks[key] = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let state = ArticleState.load(pageID: pageID)
            let collapsed = state.collapsed.map(String.init).joined(separator: ",")
            webView.evaluateJavaScript(
                "panewrightRestore([\(collapsed)], \(state.scroll));", completionHandler: nil)
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            let collapsed = (body["collapsed"] as? [Any])?.compactMap { value -> Int? in
                if let number = value as? Int { return number }
                if let string = value as? String { return Int(string) }
                return nil
            }
            ArticleState(
                collapsed: collapsed ?? [],
                scroll: body["scroll"] as? Double ?? 0
            ).save(pageID: pageID)
        }
    }

    /// Carries a non-Sendable scheme task across the network callback.
    final class SchemeTaskBox: @unchecked Sendable {
        private let task: any WKURLSchemeTask

        init(task: any WKURLSchemeTask) {
            self.task = task
        }

        @MainActor
        func finish(data: Data?, response: URLResponse?, error: Error?) {
            guard let data, let requestURL = task.request.url else {
                task.didFailWithError(error ?? URLError(.badServerResponse))
                return
            }
            // The response must carry the URL the web view asked for — a
            // redirected https URL makes WebKit discard the payload.
            let synthesized = URLResponse(
                url: requestURL,
                mimeType: response?.mimeType ?? "application/octet-stream",
                expectedContentLength: data.count,
                textEncodingName: response?.textEncodingName)
            task.didReceive(synthesized)
            task.didReceive(data)
            task.didFinish()
        }
    }

    /// Collapse state + scroll offset for one article.
    struct ArticleState {
        var collapsed: [Int]
        var scroll: Double

        static func key(_ pageID: String) -> String { "confluence.state.\(pageID)" }

        static func load(pageID: String) -> ArticleState {
            let stored = UserDefaults.standard.dictionary(forKey: key(pageID)) ?? [:]
            return ArticleState(
                collapsed: stored["collapsed"] as? [Int] ?? [],
                scroll: stored["scroll"] as? Double ?? 0)
        }

        func save(pageID: String) {
            UserDefaults.standard.set(
                ["collapsed": collapsed, "scroll": scroll], forKey: Self.key(pageID))
        }
    }

    /// Confluence's rendered body, restyled to match the app and wired for
    /// collapse/restore.
    static func document(body: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body {
            font: 15px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            margin: 0; padding: 22px 26px 60px;
            color: #ececf1; background: transparent;
          }
          @media (prefers-color-scheme: light) { body { color: #16161c; } }
          h1, h2, h3 { letter-spacing: -.01em; margin: 26px 0 8px; }
          h1 { font-size: 24px; } h2 { font-size: 19px; } h3 { font-size: 16px; }
          h1, h2, h3 { cursor: pointer; position: relative; padding-left: 16px; }
          h1::before, h2::before, h3::before {
            content: "▾"; position: absolute; left: 0; opacity: .45; font-size: .8em;
          }
          .pw-collapsed::before { content: "▸"; }
          a { color: #e05a86; }
          code, pre {
            font: 12.5px ui-monospace, "SF Mono", monospace;
            background: rgba(127,127,140,.16); border-radius: 5px;
          }
          code { padding: 1px 5px; }
          pre { padding: 12px 14px; overflow-x: auto; }
          table { border-collapse: collapse; margin: 12px 0; font-size: 14px; }
          th, td { border: 1px solid rgba(127,127,140,.35); padding: 6px 10px; text-align: left; }
          th { background: rgba(127,127,140,.14); }
          img { max-width: 100%; }
          blockquote {
            margin: 12px 0; padding: 6px 14px;
            border-left: 3px solid #d6295f; opacity: .9;
          }
          .pw-section { overflow: hidden; }
        </style></head><body>
        <div id="pw-content">\(body)</div>
        <script>
        (function () {
          // Confluence lazy-loads: the real attachment often sits in
          // data-image-src while src holds a placeholder.
          Array.from(document.querySelectorAll('#pw-content img')).forEach(function (img) {
            const real = img.getAttribute('data-image-src') || img.getAttribute('data-src');
            if (real && (!img.getAttribute('src') || img.getAttribute('src').startsWith('data:'))) {
              img.setAttribute('src', real);
            }
            img.removeAttribute('srcset');
            img.setAttribute('loading', 'eager');
          });

          const headings = Array.from(document.querySelectorAll('#pw-content h1, #pw-content h2, #pw-content h3'));
          headings.forEach(function (heading, index) {
            heading.dataset.pwIndex = index;
            const section = document.createElement('div');
            section.className = 'pw-section';
            let node = heading.nextSibling;
            while (node && !(node.nodeName && /^H[123]$/.test(node.nodeName))) {
              const next = node.nextSibling;
              section.appendChild(node);
              node = next;
            }
            heading.parentNode.insertBefore(section, heading.nextSibling);
            heading.addEventListener('click', function () {
              const hidden = section.style.display === 'none';
              section.style.display = hidden ? '' : 'none';
              heading.classList.toggle('pw-collapsed', !hidden);
              save();
            });
          });

          function save() {
            const collapsed = headings
              .filter(function (h) { return h.classList.contains('pw-collapsed'); })
              .map(function (h) { return parseInt(h.dataset.pwIndex, 10); });
            window.webkit.messageHandlers.panewright.postMessage({
              collapsed: collapsed, scroll: window.scrollY
            });
          }

          let timer = null;
          window.addEventListener('scroll', function () {
            clearTimeout(timer);
            timer = setTimeout(save, 300);
          });

          window.panewrightRestore = function (collapsed, scroll) {
            collapsed.forEach(function (index) {
              const heading = headings[index];
              if (!heading) return;
              heading.classList.add('pw-collapsed');
              const section = heading.nextElementSibling;
              if (section && section.classList.contains('pw-section')) {
                section.style.display = 'none';
              }
            });
            window.scrollTo(0, scroll || 0);
          };
        })();
        </script></body></html>
        """
    }
}
