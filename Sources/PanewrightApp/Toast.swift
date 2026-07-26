import AppKit

/// A line of text that appears, says what just happened, and goes away.
///
/// Panewright moves windows on its own — evicting one to another workspace
/// when a layout can't fit. A window relocating with no explanation reads as a
/// bug, but a system notification is the wrong weight for it: those persist in
/// Notification Center, stack up, and demand dismissal for something that
/// stopped being relevant the moment you read it.
///
/// So this is deliberately ephemeral. It cannot be clicked, cannot be
/// dismissed, and leaves nothing behind. The durable record is the log.
@MainActor
final class Toast {
    private static var current: Toast?

    private let window: NSWindow
    private var dismissal: Task<Void, Never>?

    private init(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let padding = NSSize(width: 28, height: 16)
        let size = NSSize(
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2)

        let background = NSVisualEffectView(
            frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.frame.origin = NSPoint(
            x: padding.width, y: (size.height - label.frame.height) / 2)
        background.addSubview(label)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Above everything, including a fullscreen window — the whole point is
        // that it's readable wherever you happen to be looking.
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        window.contentView = background
    }

    /// Show a message for `duration`, replacing any message already showing.
    ///
    /// Replacing rather than queueing: two evictions in quick succession
    /// should leave the second one's text on screen, not make you wait through
    /// the first.
    static func show(_ text: String, duration: TimeInterval = 1.0) {
        current?.close()
        let toast = Toast(text: text)
        current = toast
        toast.present(for: duration)
    }

    private func present(for duration: TimeInterval) {
        guard let screen = NSScreen.main else { return }
        // Above the bar rather than centred over the windows: it's a status
        // message, and the bar is where status lives.
        let frame = window.frame
        window.setFrameOrigin(
            NSPoint(
                x: screen.frame.midX - frame.width / 2,
                y: screen.visibleFrame.minY + 64))
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }
        dismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.close()
            }
        }
    }

    private func close() {
        dismissal?.cancel()
        dismissal = nil
        window.orderOut(nil)
        if Toast.current === self { Toast.current = nil }
    }
}
