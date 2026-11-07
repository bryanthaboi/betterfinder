import AppKit
import FSCore
import Foundation
import UniformTypeIdentifiers
import WebKit

public enum PreviewContent: Sendable {
    case native(ModUINode)
    case html(String)
    case text(String)
}

public struct PreviewContext: Sendable {
    public var location: BrowserLocation
    public var selectionCount: Int
    public var maxHTMLBytes: Int
}

public protocol PreviewProvider: Sendable {
    func render(_ item: FileItem, context: PreviewContext) async throws -> PreviewContent
}

public struct PreviewSpec: BrowserContribution {
    public var id: String
    public var title: String
    public var typeIdentifiers: [String]
    public var extensions: [String]
    public var priority: Int
    public var timeout: TimeInterval
    public var provider: PreviewProvider

    public init(id: String, title: String, typeIdentifiers: [String] = [], extensions: [String] = [], priority: Int = 0, timeout: TimeInterval = 5, provider: PreviewProvider) {
        self.id = id
        self.title = title
        self.typeIdentifiers = typeIdentifiers
        self.extensions = extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        self.priority = priority
        self.timeout = timeout
        self.provider = provider
    }

    public func matches(_ item: FileItem) -> Bool {
        if item.isBrowsableFolder { return false }
        if extensions.contains(item.url.pathExtension.lowercased()) { return true }
        guard let type = item.contentType else { return false }
        return typeIdentifiers.contains { UTType($0).map { type.conforms(to: $0) } ?? false }
    }
}

@MainActor
public final class PreviewRegistry: BrowserRegistry<PreviewSpec> {
    public static let shared = PreviewRegistry()

    public init() { super.init(kind: .preview) }

    override public func validate(_ item: PreviewSpec, owner: String) -> String? {
        if let base = super.validate(item, owner: owner) { return base }
        if item.typeIdentifiers.isEmpty && item.extensions.isEmpty { return "A previewer needs at least one type or extension." }
        return nil
    }

    public func entry(matching item: FileItem) -> Entry? {
        visibleEntries.filter { $0.item.matches(item) }.max { a, b in
            if a.item.priority != b.item.priority { return a.item.priority < b.item.priority }
            return a.sequence > b.sequence
        }
    }
}

public enum SandboxedHTML {
    public static let maxBytes = 1 << 20

    public static let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    public static func wrap(_ html: String) -> String {
        let clipped = html.utf8.count > maxBytes ? String(decoding: html.utf8.prefix(maxBytes), as: UTF8.self) : html
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\"></head><body>\(clipped)</body></html>"
    }

    @MainActor
    public static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = false
        return config
    }
}

@MainActor
public final class SandboxedHTMLView: NSView, WKNavigationDelegate, WKUIDelegate {
    public let webView: WKWebView
    public private(set) var blockedNavigations = 0
    private var loaded = false

    public override init(frame frameRect: NSRect) {
        webView = WKWebView(frame: .zero, configuration: SandboxedHTML.makeConfiguration())
        super.init(frame: frameRect)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Preview")
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func load(html: String) {
        loaded = false
        webView.loadHTMLString(SandboxedHTML.wrap(html), baseURL: nil)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = false
        let url = navigationAction.request.url
        let isInitial = !loaded && (url == nil || url?.absoluteString == "about:blank") && navigationAction.navigationType == .other
        if isInitial {
            loaded = true
            decisionHandler(.allow, preferences)
        } else {
            blockedNavigations += 1
            decisionHandler(.cancel, preferences)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        blockedNavigations += 1
        return nil
    }
}

@MainActor
final class PreviewPanelController: NSObject, NSWindowDelegate {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    let panel: NSPanel
    private let registries: BrowserRegistries
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let body = NSView()
    private let renderer = ModUIRenderer()
    private let textView = NSTextView()
    private let textScroll = NSScrollView()
    private let htmlView = SandboxedHTMLView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var state: State = .idle
    private(set) var currentContent: PreviewContent?
    private(set) var currentItem: FileItem?
    var onClose: (() -> Void)?

    init(registries: BrowserRegistries) {
        self.registries = registries
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.setAccessibilityLabel("Preview")
        build()
    }

    var isVisible: Bool { panel.isVisible }

    private func build() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Loading preview")
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.setAccessibilityLabel("Preview text")
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [titleLabel, NSView(), spinner])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let content = NSView()
        for v in [header, body] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    func present(_ item: FileItem, location: BrowserLocation, selectionCount: Int) {
        guard let entry = registries.previews.entry(matching: item) else { close(); return }
        currentItem = item
        titleLabel.stringValue = item.name
        panel.title = entry.item.title
        if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        generation += 1
        let gen = generation
        task?.cancel()
        state = .loading
        spinner.startAnimation(nil)
        let provider = entry.item.provider
        let timeout = entry.item.timeout
        let context = PreviewContext(location: location, selectionCount: selectionCount, maxHTMLBytes: SandboxedHTML.maxBytes)
        let work = Task.detached(priority: .userInitiated) { () -> Result<PreviewContent, Error> in
            do {
                let content = try await withThrowingTaskGroup(of: PreviewContent.self) { group in
                    group.addTask { try await provider.render(item, context: context) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                        throw ColumnProviderTimeout()
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                return .success(content)
            } catch {
                return .failure(error)
            }
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let content): self.show(content)
            case .failure(let error): self.showFailure(error.localizedDescription)
            }
        }
    }

    func show(_ content: PreviewContent) {
        currentContent = content
        state = .ready
        clearBody()
        switch content {
        case .native(let node):
            let r = renderer.rootView
            r.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(r)
            pin(r, inset: 10)
            renderer.render(node)
        case .text(let text):
            textView.string = text
            pin(textScroll, inset: 0)
        case .html(let html):
            pin(htmlView, inset: 0)
            htmlView.load(html: html)
        }
    }

    private func showFailure(_ message: String) {
        state = .failed(message)
        currentContent = nil
        clearBody()
        messageLabel.stringValue = "Preview unavailable: \(message)"
        pin(messageLabel, inset: 20)
    }

    private func clearBody() {
        for v in body.subviews { v.removeFromSuperview() }
    }

    private func pin(_ v: NSView, inset: CGFloat) {
        v.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: body.topAnchor, constant: inset),
            v.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset),
            v.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset),
            v.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -inset),
        ])
    }

    func close() {
        task?.cancel()
        task = nil
        generation += 1
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
        state = .idle
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        onClose?()
    }
}
