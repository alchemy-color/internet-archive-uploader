import SwiftUI
import WebKit

/// The Description field: plain text (HTML allowed) with an Edit / Preview
/// switch. Preview shows the text the way archive.org renders it.
struct DescriptionEditor: View {
    @Binding var text: String
    var placeholder = "What is this? Who made it, when, and why is it worth preserving?"
    var minHeight: CGFloat = 110
    var maxHeight: CGFloat = 260

    @State private var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $preview) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("HTML allowed")
                    .font(UIScale.font(10.5))
                    .foregroundStyle(.secondary)
                    .help("archive.org formats basic HTML: <b>, <i>, <p>, <ul>/<li>, <h3>, <a href>, <br>…")
            }
            Group {
                if preview {
                    DescriptionPreview(html: Self.renderable(text))
                } else {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(.system(.body, design: text.contains("<") ? .monospaced : .default))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                    }
                }
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        }
    }

    /// archive.org shows plain text with its line breaks, and HTML as HTML.
    static func renderable(_ text: String) -> String {
        let looksLikeHTML = text.range(of: #"<\s*(p|br|b|i|ul|ol|li|h\d|a|div|span|strong|em|code)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        if looksLikeHTML { return text }
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return escaped.replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// Read-only HTML view, styled to follow light/dark mode. Links open in the
/// browser; scripts are disabled.
private struct DescriptionPreview: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.45; margin: 8px 10px; color: CanvasText; background: transparent; }
          h1, h2, h3 { font-size: 1.1em; margin: 0.9em 0 0.3em; }
          p { margin: 0.4em 0 0.6em; }
          ul, ol { padding-left: 1.4em; margin: 0.3em 0 0.6em; }
          code { font: 12px ui-monospace, Menlo, monospace; background: rgba(127,127,127,0.15); padding: 0 3px; border-radius: 3px; }
          a { color: LinkText; }
        </style></head><body>\(html.isEmpty ? "<p style='opacity:.5'>Nothing to preview yet.</p>" : html)</body></html>
        """
        view.loadHTMLString(page, baseURL: URL(string: "https://archive.org/"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
