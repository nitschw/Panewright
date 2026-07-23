import AppKit

/// The translucent accent-colored preview shown while dragging — the frame
/// the dragged window will occupy on release.
@MainActor
final class DropOverlayWindow {
    private let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        window.contentView = view
    }

    /// Takes a CGWindowList (top-left-origin) frame.
    func show(cgFrame: CGRect) {
        window.setFrame(Self.cocoaRect(fromCG: cgFrame), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    /// CG coordinates hang from the top of the primary screen; Cocoa's grow
    /// from its bottom.
    static func cocoaRect(fromCG rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height)
    }
}
