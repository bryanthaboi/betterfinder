import AppKit
import Integration
import SwiftUI
import Theming

@MainActor
public final class OnboardingWindowController: NSWindowController {
    public static let shared = OnboardingWindowController()

    public var onFinish: (() -> Void)?

    public static var needed: Bool {
        !UserDefaults.standard.bool(forKey: SettingsKey.hasCompletedOnboarding)
    }

    @discardableResult
    public static func showIfNeeded(onFinish: (() -> Void)? = nil) -> Bool {
        guard needed else { return false }
        shared.onFinish = onFinish
        shared.show()
        return true
    }

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Welcome to betterfinder"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: OnboardingView(finish: { [weak self] in self?.complete() }))
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func show() {
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: SettingsKey.hasCompletedOnboarding)
        close()
        runFinish()
    }

    private func runFinish() {
        let finish = onFinish
        onFinish = nil
        finish?()
    }

    public override func close() {
        super.close()
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        runFinish()
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, coverage, makeDefault, permissions, theme, done
}

struct OnboardingView: View {
    var finish: () -> Void
    @State private var step: OnboardingStep
    @State private var skippedDefault = false
    @StateObject private var defaultModel: DefaultManagerModel
    @StateObject private var permissions: PermissionsModel
    @AccessibilityFocusState private var titleFocused: Bool
    private let themes: ThemeManager?
    private let headingFocusRequested: (String) -> Void

    init(
        finish: @escaping () -> Void,
        step: OnboardingStep = .welcome,
        defaultModel: DefaultManagerModel? = nil,
        permissions: PermissionsModel? = nil,
        themes: ThemeManager? = nil,
        headingFocusRequested: @escaping (String) -> Void = { _ in }
    ) {
        self.finish = finish
        _step = State(initialValue: step)
        _defaultModel = StateObject(wrappedValue: defaultModel ?? DefaultManagerModel())
        _permissions = StateObject(wrappedValue: permissions ?? PermissionsModel())
        self.themes = themes
        self.headingFocusRequested = headingFocusRequested
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    header
                    content
                }
                .padding(Spacing.onboardingMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onChange(of: step) { _, _ in
            titleFocused = true
            headingFocusRequested(title)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label("Fast, never-stale listings", systemImage: "bolt")
                Label("Folder sizes everywhere", systemImage: "chart.pie")
                Label("Tabs, dual pane, a real copy queue", systemImage: "rectangle.split.2x1")
                Label("Themes, from native to retro", systemImage: "paintpalette")
            }
            .font(.title3)
        case .coverage:
            CompatibilityMatrixView()
        case .makeDefault:
            VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                MakeDefaultControls(model: defaultModel)
                Text("You can undo this any time from Settings → Default with “Restore Finder as default”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .permissions:
            VStack(alignment: .leading, spacing: Spacing.s) {
                PermissionsList(model: permissions)
                Button("Open Full Disk Access settings") { FullDiskAccess.openSettings() }
            }
        case .theme:
            ThemePickerList(themes: themes ?? .shared).frame(height: 300)
        case .done:
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(Array(OnboardingSummary.lines(status: defaultModel.status, skipped: skippedDefault).enumerated()), id: \.offset) { _, line in
                    Label(line.text, systemImage: line.symbol)
                }
                Label("Change anything later in Settings (⌘,)", systemImage: "gearshape")
            }
            .font(.title3)
        }
    }

    private var footer: some View {
        ZStack {
            HStack {
                if step != .welcome && step != .done {
                    Button("Back") { move(-1) }
                }
                Spacer(minLength: ProgressDots.reservedWidth)
                if step == .done {
                    Button("Start Using betterfinder", action: finish).keyboardShortcut(.defaultAction)
                } else {
                    if step == .makeDefault || step == .permissions {
                        Button("Skip") {
                            if step == .makeDefault { skippedDefault = true }
                            move(1)
                        }
                    }
                    Button(step == .welcome ? "Get Started" : "Continue") {
                        if step == .makeDefault { skippedDefault = false }
                        move(1)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            ProgressDots(count: OnboardingStep.allCases.count, current: step.rawValue)
        }
        .padding(Spacing.panelPadding)
    }

    private func move(_ delta: Int) {
        if let next = OnboardingStep(rawValue: step.rawValue + delta) { step = next }
        defaultModel.refresh()
    }

    private var title: String {
        switch step {
        case .welcome: return "Welcome to betterfinder"
        case .coverage: return "What betterfinder can replace"
        case .makeDefault: return "Make it your default"
        case .permissions: return "Permissions"
        case .theme: return "Pick a theme"
        case .done: return "You're set"
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome: return "A native file manager that fixes what Finder gets wrong."
        case .coverage: return "Some entry points can be redirected. Some always belong to Finder."
        case .makeDefault: return "Reveal in Finder and opening folders from other apps will land here."
        case .permissions: return "macOS asks for access per location. Full Disk Access avoids the individual prompts."
        case .theme: return "You can change this later or edit your own."
        case .done: return ""
        }
    }
}

struct ProgressDots: View {
    let count: Int
    let current: Int

    static let reservedWidth: CGFloat = 140

    static func stepText(current: Int, count: Int) -> String { "Step \(current + 1) of \(count)" }

    var body: some View {
        VStack(spacing: Spacing.relatedText) {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    Group {
                        if i == current {
                            Capsule().fill(Color.accentColor).frame(width: 16, height: 7)
                        } else {
                            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                        }
                    }
                }
            }
            Text("\(current + 1) of \(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityRepresentation {
            ProgressView(value: Double(current + 1), total: Double(count))
                .accessibilityLabel("Setup progress")
                .accessibilityValue(Self.stepText(current: current, count: count))
        }
    }
}

enum OnboardingSummary {
    struct Line: Equatable {
        var text: String
        var symbol: String
    }

    static func lines(status: DefaultFileManager.Status, skipped: Bool) -> [Line] {
        if status.isFullyDefault {
            return [Line(text: "betterfinder is your default file manager", symbol: "checkmark.circle.fill")]
        }
        if skipped, !status.isFileViewer, !status.isFolderHandler {
            return [Line(text: "Your default file manager settings were left unchanged", symbol: "info.circle")]
        }
        if !status.isFileViewer, !status.isFolderHandler {
            return [Line(text: "betterfinder isn’t your default file manager. Turn it on in Settings → Default", symbol: "info.circle")]
        }
        return [
            Line(text: status.isFileViewer ? "Show in Finder and Reveal open betterfinder" : "Show in Finder and Reveal still use another app", symbol: status.isFileViewer ? "checkmark.circle.fill" : "exclamationmark.circle"),
            Line(text: status.isFolderHandler ? "Opening folders uses betterfinder" : "Opening folders still uses another app", symbol: status.isFolderHandler ? "checkmark.circle.fill" : "exclamationmark.circle"),
            Line(text: "Finish setup in Settings → Default", symbol: "gearshape.2"),
        ]
    }
}
