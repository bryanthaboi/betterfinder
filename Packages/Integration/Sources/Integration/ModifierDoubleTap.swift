import AppKit
import CoreGraphics

@MainActor
public final class ModifierDoubleTap {
    public var onTrigger: (() -> Void)?
    public let modifier: NSEvent.ModifierFlags
    public var maxPressDuration: TimeInterval = 0.3
    public var maxGap: TimeInterval = 0.35
    public var secondsSinceKeyDown: @MainActor () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }
    public private(set) var isRunning = false

    private var monitors: [Any] = []
    private var pressedAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    public init(modifier: NSEvent.ModifierFlags = .option) {
        self.modifier = modifier
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handle(flags: flags, at: time) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handle(flags: flags, at: time) }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    public func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        isRunning = false
        pressedAt = nil
        lastTapAt = nil
    }

    public func handle(flags: NSEvent.ModifierFlags, at time: TimeInterval) {
        let held = flags.intersection([.command, .option, .control, .shift])
        if held == modifier {
            pressedAt = time
            return
        }
        guard held.isEmpty, let down = pressedAt else {
            pressedAt = nil
            lastTapAt = nil
            return
        }
        pressedAt = nil
        let length = time - down
        guard length <= maxPressDuration, secondsSinceKeyDown() >= length else {
            lastTapAt = nil
            return
        }
        if let last = lastTapAt, down - last <= maxGap {
            lastTapAt = nil
            onTrigger?()
        } else {
            lastTapAt = time
        }
    }
}
