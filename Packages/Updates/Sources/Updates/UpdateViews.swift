import AppKit
import SwiftUI

@MainActor
public final class UpdateWindowController: NSWindowController {
    public init(controller: UpdateController) {
        let hosting = NSHostingController(rootView: UpdateView(controller: controller))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Software Update"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct UpdateView: View {
    @ObservedObject var controller: UpdateController
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            footerBar
        }
        .padding(20)
        .frame(width: 520, height: 420, alignment: .topLeading)
        .onChange(of: UpdatePhase(controller.state, waiting: controller.isWaitingForInstallGate)) { _, phase in
            headingFocused = true
            controller.accessibilityEvents.headingFocusRequested(heading.title)
            if let text = phase.announcement { controller.accessibilityEvents.announce(text) }
        }
    }

    private var heading: (title: String, detail: String?) {
        switch controller.state {
        case .idle:
            return ("betterfinder \(controller.currentVersionString)", "Nothing to do right now.")
        case .checking:
            return ("Checking for updates…", nil)
        case .upToDate(let latest):
            return ("You're up to date", "betterfinder \(controller.currentVersionString) is the newest version (latest release: \(latest)).")
        case .noInfo:
            return ("No update information available", "betterfinder couldn't find a published release to compare against. Try again later.")
        case .failed(let text):
            return ("Update failed", text)
        case .available(let release):
            return ("betterfinder \(release.versionString) is available", "You have \(controller.currentVersionString).")
        case .downloading(let release, let fraction):
            return ("Downloading betterfinder \(release.versionString)…", "\(Int(fraction * 100))%")
        case .verifying(let release):
            if controller.isWaitingForInstallGate {
                return ("Waiting to install betterfinder \(release.versionString)…", "File operations are still running. The update installs when they finish.")
            }
            return ("Verifying betterfinder \(release.versionString)…", "Checking the code signature and notarization.")
        case .installing(let release):
            return ("Installing betterfinder \(release.versionString)…", "betterfinder will quit and reopen.")
        }
    }

    @ViewBuilder
    private var content: some View {
        message(heading.title, detail: heading.detail)
        switch controller.state {
        case .idle, .upToDate, .noInfo, .failed:
            EmptyView()
        case .checking:
            ProgressView().progressViewStyle(.linear).accessibilityLabel("Checking for updates")
        case .available(let release):
            available(release)
        case .downloading(let release, let fraction):
            ProgressView(value: fraction).progressViewStyle(.linear)
                .accessibilityLabel("Downloading betterfinder \(release.versionString)")
                .accessibilityValue("\(Int(fraction * 100)) percent")
        case .verifying(let release):
            if controller.isWaitingForInstallGate {
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Waiting for file operations to finish")
            } else {
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Verifying betterfinder \(release.versionString)")
            }
        case .installing(let release):
            ProgressView().progressViewStyle(.linear).accessibilityLabel("Installing betterfinder \(release.versionString)")
        }
        Spacer(minLength: 0)
    }

    @ViewBuilder
    private var footerBar: some View {
        switch controller.state {
        case .idle:
            footer { Button("Check Now") { controller.checkForUpdates(userInitiated: true) }; Button("Close") { controller.dismiss() }.keyboardShortcut(.defaultAction) }
        case .checking:
            footer { Button("Cancel") { controller.cancelWork(); controller.dismiss() } }
        case .upToDate, .noInfo:
            footer { Button("OK") { controller.dismiss() }.keyboardShortcut(.defaultAction) }
        case .failed:
            footer {
                Button("Try Again") { controller.checkForUpdates(userInitiated: true) }
                Button("Close") { controller.dismiss() }.keyboardShortcut(.defaultAction)
            }
        case .available(let release):
            footer {
                Button("Skip This Version") { controller.skipThisVersion() }
                Spacer()
                if let page = release.pageURL, controller.installBlockedReason != nil || release.zipAsset == nil {
                    Button("View Release") { NSWorkspace.shared.open(page) }
                }
                Button("Remind Me Later") { controller.remindMeLater() }
                Button("Install & Relaunch") { controller.installAndRelaunch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.installBlockedReason != nil || release.zipAsset == nil)
            }
        case .downloading:
            footer { Button("Cancel") { controller.cancelWork() } }
        case .verifying where controller.isWaitingForInstallGate:
            footer { Button("Cancel Update") { controller.cancelWork() } }
        case .verifying, .installing:
            EmptyView()
        }
    }

    @ViewBuilder
    private func available(_ release: UpdateRelease) -> some View {
        ScrollView {
            ReleaseNotesView(markdown: release.notes.isEmpty ? "No release notes." : release.notes)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        if let reason = controller.installBlockedReason {
            Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if release.zipAsset == nil {
            Text("This release has no downloadable archive.").font(.caption).foregroundStyle(.orange)
        }
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func footer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ReleaseNotesView: View {
    let markdown: String

    static let blockSpacing: CGFloat = 16
    static let listItemSpacing: CGFloat = 8

    static func groups(_ blocks: [MarkdownBlock]) -> [[MarkdownBlock]] {
        var result: [[MarkdownBlock]] = []
        for block in blocks {
            if isListItem(block), let last = result.last?.last, isListItem(last) {
                result[result.count - 1].append(block)
            } else {
                result.append([block])
            }
        }
        return result
    }

    private static func isListItem(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .bullet, .numbered: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            ForEach(Array(Self.groups(MarkdownBlocks.parse(markdown)).enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: Self.listItemSpacing) {
                    ForEach(Array(group.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownBlocks.inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .accessibilityAddTraits(.isHeader)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(MarkdownBlocks.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                Text(MarkdownBlocks.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .paragraph(let text):
            Text(MarkdownBlocks.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }
}

public struct SettingsSectionView: View {
    @ObservedObject private var controller = UpdateController.shared
    @AppStorage(UpdatesDefaultsKey.autoCheck) private var autoCheck = true
    @AppStorage(UpdatesDefaultsKey.crashReportsEnabled) private var crashReports = true

    public init() {}

    public var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $autoCheck)
            HStack {
                Text(lastCheckedText).foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { controller.checkForUpdates(userInitiated: true) }
                    .disabled(!controller.canCheckForUpdates)
            }
            if let skipped = controller.skippedVersion {
                HStack {
                    Text("Skipping version \(skipped.description)").font(.caption).foregroundStyle(.secondary)
                    Button("Reset") { controller.clearSkippedVersion() }.buttonStyle(.link).font(.caption)
                }
            }
            Toggle("Offer to send a crash report after a crash", isOn: $crashReports)
            Text("Nothing is ever sent automatically. A report only opens a prefilled GitHub issue for you to review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastCheckedText: String {
        guard let date = controller.lastChecked else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct UpdatePhase: Equatable {
    enum Kind: Equatable { case idle, checking, upToDate, noInfo, failed, available, downloading, verifying, waiting, installing }
    var kind: Kind
    var announcement: String?

    init(_ state: UpdateState, waiting: Bool = false) {
        switch state {
        case .idle: kind = .idle; announcement = nil
        case .checking: kind = .checking; announcement = nil
        case .upToDate: kind = .upToDate; announcement = "betterfinder is up to date"
        case .noInfo: kind = .noInfo; announcement = "No update information available"
        case .failed(let text): kind = .failed; announcement = "Update failed. \(text)"
        case .available(let r): kind = .available; announcement = "betterfinder \(r.versionString) is available"
        case .downloading: kind = .downloading; announcement = nil
        case .verifying: kind = waiting ? .waiting : .verifying; announcement = waiting ? "Waiting for file operations to finish before installing" : nil
        case .installing: kind = .installing; announcement = nil
        }
    }
}

@MainActor
struct UpdateAccessibilityEvents {
    var announce: @MainActor (String) -> Void = { UpdateAnnouncer.announce($0) }
    var headingFocusRequested: @MainActor (String) -> Void = { _ in }
}

@MainActor
enum UpdateAnnouncer {
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
