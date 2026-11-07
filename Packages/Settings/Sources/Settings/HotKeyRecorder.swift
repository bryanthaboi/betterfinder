import AppKit
import Integration
import SwiftUI

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var combo: HotKeyCombo
    var onChange: (HotKeyCombo) -> Void
    var onReject: ((String) -> Void)? = nil

    static func rejectionMessage(for flags: NSEvent.ModifierFlags) -> String {
        let mods = flags.intersection([.command, .option, .control, .shift])
        if mods == .shift { return "Shift alone isn’t enough. Add ⌘, ⌥ or ⌃ to the shortcut." }
        return "Shortcuts need ⌘, ⌥ or ⌃, for example ⌥⌘N."
    }

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onCapture = { newCombo in
            combo = newCombo
            onChange(newCombo)
        }
        field.onReject = { message in onReject?(message) }
        field.combo = combo
        return field
    }

    func updateNSView(_ nsView: RecorderField, context: Context) {
        nsView.combo = combo
    }

    final class RecorderField: NSButton {
        var onCapture: ((HotKeyCombo) -> Void)?
        var onReject: ((String) -> Void)?
        var combo: HotKeyCombo = .default { didSet { refreshTitle() } }
        private var recording = false { didSet { refreshTitle() } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(toggle)
            refreshTitle()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { true }

        override var intrinsicContentSize: NSSize {
            var s = super.intrinsicContentSize
            s.width = max(s.width, 140)
            return s
        }

        @objc private func toggle() {
            recording.toggle()
            if recording { window?.makeFirstResponder(self) }
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return super.resignFirstResponder()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            handle(event)
        }

        private func handle(_ event: NSEvent) {
            if event.keyCode == 53 {
                recording = false
                return
            }
            guard let captured = HotKeyCombo(event: event) else {
                let message = HotKeyRecorder.rejectionMessage(for: event.modifierFlags)
                onReject?(message)
                NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
                NSSound.beep()
                return
            }
            recording = false
            combo = captured
            onCapture?(captured)
        }

        private func refreshTitle() {
            title = recording ? "Type shortcut…" : combo.displayString
        }
    }
}
