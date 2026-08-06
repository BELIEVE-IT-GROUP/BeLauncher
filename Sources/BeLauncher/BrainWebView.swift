import SwiftUI
import WebKit
import BeLauncherCore

/// The graph, drawn by the same library the other Believe brains use.
///
/// This replaces a hand-written force layout painted into a SwiftUI Canvas. That version produced
/// a still picture: no dragging a node, no zoom, no infinite canvas, and a layout that had to be
/// recomputed from scratch to move at all. Rebuilding those from nothing is weeks of work to end
/// up with a worse copy of something already vendored in three of our repos.
///
/// So the engine is `force-graph` 1.51.4 — the same one `react-force-graph-2d` wraps, the same one
/// GetMaas, Maasy and BeMail draw with — running inside a WebView, with the node painter copied
/// from GetMaas rather than reinterpreted. The file ships inside the app: nothing is fetched, and
/// the page has no network access to fetch it from.
struct BrainWebView: NSViewRepresentable {

    let graph: BrainGraphData
    /// Which node the person acted on, and how.
    var onSelect: (String) -> Void = { _ in }
    var onCompare: (String) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "brain")
        // No remote content ever loads here, so there is nothing to reach the network for. Said
        // explicitly rather than assumed: this window shows what somebody works on all day.
        configuration.suppressesIncrementalRendering = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view

        guard let page = Bundle.main.url(forResource: "brain", withExtension: "html") else {
            // Running from `swift run` during development, where there is no bundle. The window
            // says so instead of showing an empty rectangle nobody can diagnose.
            view.loadHTMLString(
                "<body style='background:#0a0d14;color:#8a92a6;font:13px -apple-system;"
                + "display:flex;align-items:center;justify-content:center;height:100vh'>"
                + "Falta brain.html en el paquete.</body>", baseURL: nil)
            return view
        }
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push(graph)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: BrainWebView
        weak var webView: WKWebView?
        private var isReady = false
        private var pending: BrainGraphData?

        init(_ parent: BrainWebView) { self.parent = parent }

        /// Held until the page says it is ready.
        ///
        /// SwiftUI updates the view before the WebView finishes loading, so the first graph
        /// arrives at a page with no `setGraph` on it yet. Without this the window opens empty and
        /// only fills in when something else happens to trigger a redraw.
        func push(_ graph: BrainGraphData) {
            guard isReady, let webView else { pending = graph; return }
            guard let data = try? JSONEncoder().encode(graph) else { return }
            // Base64 rather than escaping the JSON into a JavaScript string literal. The escaping
            // version worked until a label contained a quote: JSON had already written it as \",
            // and escaping the backslash afterwards turned it into \\" — valid JavaScript,
            // broken JSON. `JSON.parse` threw inside the page, `setGraph` never ran, and the
            // window drew a blank canvas under a header that said 58 nodes and 457 relations.
            // Nothing to escape means nothing to get wrong.
            webView.evaluateJavaScript(
                "window.setGraph(decodeURIComponent(escape(atob('\(data.base64EncodedString())'))))")
        }

        func focus(_ id: String) {
            webView?.evaluateJavaScript("window.focusNode('\(id)')")
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let name = body["name"] as? String else { return }
            let id = body["id"] as? String ?? ""
            switch name {
            case "ready":
                isReady = true
                if let pending { push(pending); self.pending = nil }
            case "select": parent.onSelect(id)
            case "compare": parent.onCompare(id)
            case "open": parent.onOpen(id)
            default: break
            }
        }
    }
}

/// What the page is handed. Deliberately the same shape the other brains use, so the painter did
/// not have to be adapted on the way in.
struct BrainGraphData: Encodable, Equatable {

    struct Node: Encodable, Equatable {
        let id: String
        let label: String
        /// Matches the keys of the palette in the page.
        let type: String
        /// Drives the radius as `sqrt(weight)`, so what matters is bigger without swallowing the
        /// canvas.
        let weight: Double
    }

    struct Link: Encodable, Equatable {
        let source: String
        let target: String
        let kind: String
        let weight: Double
    }

    let nodes: [Node]
    let links: [Link]

    var isEmpty: Bool { nodes.isEmpty }
}
